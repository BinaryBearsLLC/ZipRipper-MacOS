import Foundation
import Metal
import CommonCrypto
import Darwin

/// GPU-derived keys are only a prefilter. John remains the final verifier.
/// Unsupported records and candidates pass through byte-for-byte, in order.
public final class MetalArchiveFilter {
    private let zip: MetalZIPFilter
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [String: MTLComputePipelineState]
    public var deviceName: String { device.name }
    public static let recommendedBatchSize = 1024
    private let batchSize: Int
    private let dispatchesPerCommand: Int
    public convenience init(batchSize: Int = MetalArchiveFilter.recommendedBatchSize) throws {
        try self.init(batchSize: batchSize, dispatchesPerCommand: 4)
    }
    init(batchSize: Int, dispatchesPerCommand: Int) throws {
        self.dispatchesPerCommand = max(1, min(4, dispatchesPerCommand))
        self.batchSize = max(1, min(4096, batchSize))
        zip = try MetalZIPFilter()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw MetalZIPFilter.FilterError.unavailable }
        self.device = device; self.queue = queue; self.pipelines = try MetalPipelines.load(device: device)

    }
    public static func supports(hashLine: String) -> Bool { MetalZIPFilter.supports(hashLine: hashLine) || ArchiveGPUHash(hashLine) != nil }
    /// Small host batches and split KDF rounds bound GPU command duration.
    public func filter(candidates: [String], hashLine: String, isCancelled: () -> Bool = { false }) throws -> [String] {
        if MetalZIPFilter.supports(hashLine: hashLine) {
            if isCancelled() { throw CancellationError() }
            return try zip.filter(candidates: candidates, hashLine: hashLine)
        }
        guard let hash = ArchiveGPUHash(hashLine) else { return candidates }
        var result = [String]()
        for start in stride(from: 0, to: candidates.count, by: batchSize) {
            if isCancelled() { throw CancellationError() }
            let batch = Array(candidates[start..<min(candidates.count, start + batchSize)])
            var bytes = [UInt8](), lengths = [UInt32](), indices = [Int]()
            bytes.reserveCapacity(batch.count * 256); lengths.reserveCapacity(batch.count); indices.reserveCapacity(batch.count)
            var keep = [Bool](repeating: true, count: batch.count)
            for (i, password) in batch.enumerated() {
                guard let encoded = hash.encode(password) else { continue }
                bytes += encoded + [UInt8](repeating: 0, count: 256 - encoded.count)
                lengths.append(UInt32(encoded.count)); indices.append(i)
            }
            if !indices.isEmpty {
                let keys = try derive(bytes: bytes, lengths: lengths, hash: hash, isCancelled: isCancelled)
                for (i, original) in indices.enumerated() {
                    if isCancelled() { throw CancellationError() }
                    keep[original] = hash.accepts(key: keys[i])
                }
            }
            for (i, password) in batch.enumerated() where keep[i] { result.append(password) }
        }
        return result
    }
    private func buffer<T>(_ values: [T]) throws -> MTLBuffer {
        guard let b = values.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { throw MetalZIPFilter.FilterError.allocation }; return b
    }
    private func derive(bytes: [UInt8], lengths: [UInt32], hash: ArchiveGPUHash, isCancelled: () -> Bool) throws -> [[UInt8]] {
        let input = try buffer(bytes), lens = try buffer(lengths), salt = try buffer(hash.salt.isEmpty ? [UInt8(0)] : hash.salt)
        guard let state = device.makeBuffer(length: lengths.count * 40 * 4, options: .storageModeShared), let pipeline = pipelines[hash.kernel] else { throw MetalZIPFilter.FilterError.allocation }
        // Several ordered encoders share one command buffer. Keep each kernel
        // bounded while avoiding a host wait after every 4,096 KDF rounds.
        for groupStart in stride(from: 0, to: hash.rounds, by: 4096 * dispatchesPerCommand) {
            if isCancelled() { throw CancellationError() }
            guard let command = queue.makeCommandBuffer() else { throw MetalZIPFilter.FilterError.allocation }
            for start in stride(from: groupStart, to: min(hash.rounds, groupStart + 4096 * dispatchesPerCommand), by: 4096) {
                if isCancelled() { throw CancellationError() }
                let params: [UInt32] = [UInt32(lengths.count), UInt32(hash.salt.count), UInt32(start), UInt32(min(start + 4096, hash.rounds)), UInt32(hash.rounds)]
                guard let encoder = command.makeComputeCommandEncoder() else { throw MetalZIPFilter.FilterError.allocation }
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(input, offset: 0, index: 0)
                encoder.setBuffer(lens, offset: 0, index: 1)
                encoder.setBuffer(salt, offset: 0, index: 2)
                params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 3) }
                encoder.setBuffer(state, offset: 0, index: 4)
                encoder.dispatchThreads(MTLSize(width: lengths.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
                encoder.endEncoding()
            }
            command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { throw MetalZIPFilter.FilterError.command(command.error?.localizedDescription ?? "GPU command failed") }
        }
        let words = state.contents().bindMemory(to: UInt32.self, capacity: lengths.count * 40)
        return lengths.indices.map { i in (0..<32).map { j in UInt8(truncatingIfNeeded: words[i * 40 + j / 4] >> (24 - (j % 4) * 8)) } }
    }
}

struct ArchiveGPUHash {
    enum Kind { case seven, rar5, pdf5, zipCrypto, pdfLegacy, rar3 }
    let kind: Kind
    let salt: [UInt8]
    let rounds: Int
    var check = [UInt8]()
    var iv = [UInt8]()
    var encrypted = [UInt8]()
    var packedSize = 0
    var crc: UInt32 = 0
    var type = 0
    var unpackedSize = 0
    var properties = [UInt8]()
    var kernel: String { switch kind { case .seven: return "sevenZIPKey"; case .rar5: return "rar5Key"; case .pdf5: return "pdfR5Key"; case .zipCrypto: return "zipCryptoHeader"; case .pdfLegacy: return "pdfLegacyKey"; case .rar3: return "rar3Key" } }
    init?(_ line: String) {
        guard line.utf8.count <= 16 * 1024 * 1024, !line.contains("\n"), !line.contains("\r") else { return nil }
        func fields(_ marker: String, _ separator: Character) -> [Substring]? {
            guard let range = line.range(of: marker), line.range(of: marker, range: range.upperBound..<line.endIndex) == nil else { return nil }
            // Labels may contain hash-like punctuation: only accept a record at
            // the beginning or after John's ':' field delimiter.
            guard range.lowerBound == line.startIndex || line[line.index(before: range.lowerBound)] == ":" else { return nil }
            return line[range.upperBound...].split(separator: ":", omittingEmptySubsequences: false)[0].split(separator: separator, omittingEmptySubsequences: false)
        }
        if let f = fields("$pkzip$", "*") ?? fields("$pkzip2$", "*") {
            let modern = line.contains("$pkzip2$")
            guard f.count >= 9, f[0] == "1", ["1", "2"].contains(f[1]),
                  ["1", "2"].contains(f[2]), UInt64(f[3], radix: 16) != nil else { return nil }
            let extra = f[2] == "2" ? 5 : 0
            let base = 4 + extra
            guard f.count == base + (modern ? 6 : 5), ["0", "8"].contains(f[base]),
                  let dataSize = Int(f[base + 1], radix: 16), (12...8 * 1024 * 1024).contains(dataSize),
                  let first = Self.hex(f[base + 2]), first.count == 2,
                  let second = Self.hex(f[base + (modern ? 3 : 2)]), second.count == 2,
                  let data = Self.hex(f[base + (modern ? 4 : 3)]), data.count == dataSize,
                  f.last == (modern ? "$/pkzip2$" : "$/pkzip$") else { return nil }
            if extra > 0 { guard f[4..<9].allSatisfy({ UInt64($0, radix: 16) != nil }) else { return nil } }
            kind = .zipCrypto; rounds = 1
            salt = Array(data.prefix(12)) + first + second + [UInt8(f[1])!]
        } else if let f = fields("$rar5$", "$") {
            guard f.count == 6, f[0] == "16", let salt = Self.hex(f[1]), salt.count == 16,
                  let power = Int(f[2]), (0...24).contains(power), let iv = Self.hex(f[3]), iv.count == 16,
                  f[4] == "8", let check = Self.hex(f[5]), check.count == 8 else { return nil }
            kind = .rar5; self.salt = salt; rounds = (1 << power) + 32; self.check = check
        } else if let f = fields("$RAR3$*", "*") {
            guard f.count >= 3, ["0", "1"].contains(f[0]), let salt = Self.hex(f[1]), salt.count == 8 else { return nil }
            if f[0] == "0" {
                guard f.count == 3, let data = Self.hex(f[2]), data.count == 16 else { return nil }
                encrypted = data; type = 0
            } else {
                guard f.count == 8, let crcBytes = Self.hex(f[2]), crcBytes.count == 4,
                      let packed = Int(f[3]), (16...8 * 1024 * 1024).contains(packed), packed % 16 == 0,
                      let unpacked = Int(f[4]), (1...8 * 1024 * 1024).contains(unpacked), f[5] == "1",
                      let data = Self.hex(f[6]), data.count == packed,
                      let method = Int(f[7], radix: 16), (0x30...0x35).contains(method) else { return nil }
                if method == 0x30 { guard unpacked <= packed else { return nil } }
                type = method; encrypted = data; unpackedSize = unpacked
                crc = (0..<4).reduce(UInt32(0)) { $0 | UInt32(crcBytes[$1]) << ($1 * 8) }
            }
            kind = .rar3; self.salt = salt; rounds = 0x40000
        } else if let f = fields("$7z$", "$") {
            // John currently ignores actual salt bytes in get_salt; never apply
            // a different salted KDF and risk dropping a CPU-supported candidate.
            guard f.count >= 10, let type = Int(f[0]), [0, 2, 128].contains(type),
                  let power = Int(f[1]), (1...24).contains(power), f[2] == "0", f[3].isEmpty,
                  let ivSize = Int(f[4]), (0...16).contains(ivSize), let encodedIV = Self.hex(f[5]), encodedIV.count >= ivSize, encodedIV.count <= 16,
                  encodedIV.dropFirst(ivSize).allSatisfy({ $0 == 0 }),
                  let signedCRC = Int64(f[6]), signedCRC >= Int64(Int32.min), signedCRC <= Int64(UInt32.max),
                  let size = Int(f[7]), size > 0, size <= 8 * 1024 * 1024, size % 16 == 0,
                  let packed = Int(f[8]), packed > 0, packed <= size, size - packed < 16,
                  let data = Self.hex(f[9]), data.count == size else { return nil }
            if type == 0 || type == 128 { guard f.count == 10 else { return nil } }
            else {
                guard f.count == 12, let unpacked = Int(f[10]), (1...8 * 1024 * 1024).contains(unpacked),
                      let props = Self.hex(f[11]), LZMADecoder.supports(type: type, properties: props) else { return nil }
                unpackedSize = unpacked; properties = props
            }
            if type == 128 { guard size >= 32, size > packed else { return nil } }
            kind = .seven; salt = []; rounds = 1 << power; self.type = type
            iv = Array(encodedIV.prefix(ivSize)) + [UInt8](repeating: 0, count: 16 - ivSize)
            encrypted = data; packedSize = packed; crc = UInt32(truncatingIfNeeded: signedCRC)
        } else if let f = fields("$pdf$", "*") {
            guard f.count == 11 || f.count == 15, let version = Int(f[0]), (1...5).contains(version),
                  let revision = Int(f[1]), (2...5).contains(revision), let bits = Int(f[2]),
                  let permission = Int64(f[3]), permission >= Int64(Int32.min), permission <= Int64(UInt32.max), ["0", "1"].contains(f[4]),
                  let idSize = Int(f[5]), (0...128).contains(idSize), let id = Self.hex(f[6]), id.count == idSize,
                  let uSize = Int(f[7]), (32...127).contains(uSize), let u = Self.hex(f[8]), u.count == uSize,
                  let oSize = Int(f[9]), (32...127).contains(oSize), let o = Self.hex(f[10]), o.count == oSize else { return nil }
            if f.count == 15 { guard f[11] == "32", Self.hex(f[12])?.count == 32, f[13] == "32", Self.hex(f[14])?.count == 32 else { return nil } }
            rounds = 1
            if revision == 5 {
                guard version == 5, bits == 256, uSize >= 48, oSize >= 48 else { return nil }
                kind = .pdf5; salt = Array(u[32..<40]); check = Array(u.prefix(32))
            } else {
                guard (40...128).contains(bits), bits % 8 == 0, uSize == 32, oSize == 32 else { return nil }
                kind = .pdfLegacy
                let permissions = UInt32(truncatingIfNeeded: permission)
                salt = [UInt8(revision), UInt8(bits / 8), UInt8(f[4])!, UInt8(idSize)] + (0..<4).map { UInt8(truncatingIfNeeded: permissions >> ($0 * 8)) } + o + id
                check = Array(u.prefix(revision == 2 ? 32 : 16))
            }
        } else { return nil }
    }
    func encode(_ password: String) -> [UInt8]? {
        let utf8 = Array(password.utf8.prefix(129))
        guard !utf8.contains(0) else { return nil }
        switch kind {
        case .seven, .rar3:
            // Match both scalar and SIMD John's 28 UTF-16-unit limit. Longer
            // candidates remain CPU-visible; there is no silent truncation.
            let units = Array(password.utf16.prefix(29))
            guard units.count <= (kind == .rar3 ? 26 : 28), utf8.count <= 84 else { return nil }
            return units.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
        case .rar5: guard utf8.count <= 32 else { return nil }; return utf8
        case .pdf5, .pdfLegacy: guard utf8.count <= 125 else { return nil }; return utf8
        case .zipCrypto: guard utf8.count <= 63 else { return nil }; return utf8
        }
    }
    func accepts(key: [UInt8]) -> Bool {
        switch kind {
        case .rar5:
            var folded = [UInt8](repeating: 0, count: 8)
            for i in 0..<32 { folded[i % 8] ^= key[i] }
            return folded == check
        case .pdf5, .pdfLegacy: return Array(key.prefix(check.count)) == check
        case .zipCrypto: return key[3] == 1
        case .rar3:
            let count = type == 0x30 ? encrypted.count : 16
            guard let output = Self.decrypt(Array(encrypted.prefix(count)), key: Array(key.prefix(16)), iv: Array(key.suffix(16))) else { return true }
            if type == 0 { return Array(output.prefix(7)) == [0xc4, 0x3d, 0x7b, 0x00, 0x40, 0x07, 0x00] }
            if type == 0x30 { return Self.crc32(Array(output.prefix(unpackedSize))) == crc }
            // Necessary RAR3 PPM/LZ block conditions used by John's verifier.
            // The full Huffman/decompression/CRC check remains John's job.
            if output[0] & 0x80 != 0 { return output[0] & 0x20 != 0 && output[1] & 0x80 == 0 }
            return output[0] & 0x40 == 0
        case .seven:
            guard let output = Self.decrypt(encrypted, key: key, iv: iv) else { return true }
            if type == 128 { return output.suffix(encrypted.count - packedSize).allSatisfy { $0 == 0 } }
            // General 7z padding is not guaranteed to be zero (John #2532).
            // Validate decrypted content with CRC instead of a padding shortcut.
            let packed = Array(output.prefix(packedSize))
            if type == 0 { return Self.crc32(packed) == crc }
            switch LZMADecoder.decode(packed, type: type, properties: properties, size: unpackedSize) {
            case .decoded(let plain): return Self.crc32(plain) == crc
            case .invalid: return false
            case .unavailable: return true
            }
        }
    }
    private static func decrypt(_ encrypted: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: encrypted.count), moved = 0
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in encrypted.withUnsafeBytes { input in output.withUnsafeMutableBytes { out in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0), k.baseAddress, key.count, v.baseAddress, input.baseAddress, input.count, out.baseAddress, out.count, &moved)
        } } } }
        return status == kCCSuccess && moved == encrypted.count ? output : nil
    }
    static func hex(_ text: Substring) -> [UInt8]? {
        let bytes = Array(text.utf8)
        guard bytes.count % 2 == 0, bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        func nibble(_ b: UInt8) -> UInt8 { b <= 57 ? b - 48 : (b | 32) - 87 }
        return stride(from: 0, to: bytes.count, by: 2).map { nibble(bytes[$0]) << 4 | nibble(bytes[$0 + 1]) }
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
        return crc ^ UInt32.max
    }
}

/// The OS liblzma ABI is loaded optionally; absence preserves CPU fallback.
/// No dependency source changes or external processes are involved.
private enum LZMADecoder {
    private struct Filter { var id: UInt64; var options: UnsafeMutableRawPointer? }
    typealias Properties = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?, UInt32) -> Int32
    typealias Decode = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?, UnsafeMutablePointer<Int>?, Int, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int>?, Int) -> Int32
    typealias Free = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void
    private static let library = dlopen("/usr/lib/liblzma.dylib", RTLD_LAZY | RTLD_LOCAL)
    private static func symbol<T>(_ name: String, _: T.Type) -> T? { guard let library, let p = dlsym(library, name) else { return nil }; return unsafeBitCast(p, to: T.self) }
    static func supports(type: Int, properties: [UInt8]) -> Bool {
        guard symbol("lzma_properties_decode", Properties.self) != nil, symbol("lzma_raw_buffer_decode", Decode.self) != nil, symbol("lzma_filters_free", Free.self) != nil else { return false }
        return type == 2 && properties.count == 1 && properties[0] <= 28
    }
    enum Result { case decoded([UInt8]), invalid, unavailable }
    static func decode(_ input: [UInt8], type: Int, properties: [UInt8], size: Int) -> Result {
        guard let configure = symbol("lzma_properties_decode", Properties.self), let decode = symbol("lzma_raw_buffer_decode", Decode.self), let release = symbol("lzma_filters_free", Free.self) else { return .unavailable }
        var filters = [Filter(id: 0x21, options: nil), Filter(id: UInt64.max, options: nil)]
        defer { filters.withUnsafeMutableBytes { release($0.baseAddress, nil) } }
        let setup = filters.withUnsafeMutableBytes { f in properties.withUnsafeBytes { p in configure(f.baseAddress, nil, p.baseAddress, UInt32(p.count)) } }
        guard setup == 0 else { return .unavailable }
        var output = [UInt8](repeating: 0, count: size), inPosition = 0, outPosition = 0
        let result = filters.withUnsafeBytes { f in input.withUnsafeBytes { i in output.withUnsafeMutableBytes { o in decode(f.baseAddress, nil, i.baseAddress, &inPosition, i.count, o.baseAddress, &outPosition, o.count) } } }
        // Solid 7z hashes can request a CRC over only the decoded prefix.
        // A too-small output buffer is therefore ambiguous, never a reason to
        // reject a password. John performs its complete/prefix decompression.
        if result == 0 && outPosition == size { return .decoded(output) }
        if result == 9 { return .invalid } // LZMA_DATA_ERROR only.
        return .unavailable
    }
}
