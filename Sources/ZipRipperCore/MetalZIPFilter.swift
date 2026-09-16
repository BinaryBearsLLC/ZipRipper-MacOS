import Foundation
import Metal

/// A two-byte WinZip AES password-verifier prefilter. A survivor is NOT proof
/// of a recovered password: the complete archive must still be verified by John.
/// Unsupported hashes, passwords over 64 UTF-8 bytes, and NUL-bearing strings
/// pass through unchanged. No Unicode normalization or truncation is performed.
public final class MetalZIPFilter {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    public var deviceName: String { device.name }

    public enum FilterError: LocalizedError {
        case unavailable, missingShader, allocation, command(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "No compatible Metal device or command queue is available. Use CPU recovery."
            case .missingShader: return "The WinZip AES Metal shader is missing from the application resources."
            case .allocation: return "Metal could not allocate the password-filter buffers. Use CPU recovery."
            case .command(let message): return "Metal password filtering failed: \(message)"
            }
        }
    }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw FilterError.unavailable
        }
        self.device = device
        self.queue = queue
        self.pipeline = try MetalPipelines.load(device: device)["winZipAESVerifier"]!

    }

    /// Supports one inline WinZip AES `$zip2$` hash with mode 1, 2, or 3.
    /// External ZFILE records, ZipCrypto, and other formats use CPU recovery.
    public static func supports(hashLine: String) -> Bool { ParsedHash(hashLine) != nil }

    public func filter(candidates: [String], hashLine: String) throws -> [String] {
        guard !candidates.isEmpty, let hash = ParsedHash(hashLine) else { return candidates }
        // Bounded dispatches cap allocation and execution time independently of list size.
        let batchSize = 4096
        var result: [String] = []
        for start in stride(from: 0, to: candidates.count, by: batchSize) {
            let end = min(start + batchSize, candidates.count)
            var bytes: [UInt8] = []
            var lengths: [UInt32] = []
            var gpuIndices: [Int] = []
            var kept = [Bool](repeating: true, count: end - start)
            bytes.reserveCapacity((end - start) * 64)
            for index in start..<end {
                let password = candidates[index]
                // The prefix avoids allocating a large UTF-8 copy for long candidates.
                let encoded = Array(password.utf8.prefix(65))
                guard encoded.count <= 64, !encoded.contains(0) else { continue }
                gpuIndices.append(index - start)
                lengths.append(UInt32(encoded.count))
                bytes.append(contentsOf: encoded)
                bytes.append(contentsOf: repeatElement(UInt8(0), count: 64 - encoded.count))
            }
            if !gpuIndices.isEmpty {
                let offset = hash.keyBytes * 2
                let params: [UInt32] = [UInt32(gpuIndices.count), UInt32(hash.salt.count),
                                        UInt32(offset / 20 + 1), UInt32(offset % 20), hash.verifier]
                let buffers = try [makeBuffer(bytes), makeBuffer(lengths), makeBuffer(hash.salt), makeBuffer(params)]
                guard let output = device.makeBuffer(length: gpuIndices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared),
                      let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                    throw FilterError.allocation
                }
                encoder.setComputePipelineState(pipeline)
                for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
                encoder.setBuffer(output, offset: 0, index: 4)
                let width = min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup)
                encoder.dispatchThreads(MTLSize(width: gpuIndices.count, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                guard command.status == .completed else {
                    throw FilterError.command(command.error?.localizedDescription ?? "The GPU command did not complete.")
                }
                let flags = output.contents().bindMemory(to: UInt32.self, capacity: gpuIndices.count)
                for (index, original) in gpuIndices.enumerated() { kept[original] = flags[index] != 0 }
            }
            for index in start..<end where kept[index - start] { result.append(candidates[index]) }
        }
        return result
    }

    private func makeBuffer<T>(_ values: [T]) throws -> MTLBuffer {
        let buffer = values.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
        guard let buffer else { throw FilterError.allocation }
        return buffer
    }

    private struct ParsedHash {
        let salt: [UInt8]
        let keyBytes: Int
        let verifier: UInt32

        init?(_ line: String) {
            // Limit parser work for giant inline hashes; these remain CPU-supported.
            guard line.utf8.count <= 16 * 1024 * 1024,
                  !line.contains("\n"), !line.contains("\r"),
                  let start = line.range(of: "$zip2$*"),
                  let end = line.range(of: "*$/zip2$", range: start.upperBound..<line.endIndex),
                  line.range(of: "$zip2$*", range: start.upperBound..<line.endIndex) == nil else { return nil }
            let fields = line[start.upperBound..<end.lowerBound].split(separator: "*", omittingEmptySubsequences: false)
            guard fields.count == 8, fields[0] == "0", fields[2] == "0",
                  let mode = Int(fields[1]), (1...3).contains(mode),
                  let salt = Self.hex(fields[3]), salt.count == 4 + 4 * mode,
                  let verifier = Self.hex(fields[4]), verifier.count == 2,
                  !fields[5].isEmpty, fields[5].allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let dataLength = Int(fields[5], radix: 16), dataLength >= 0,
                  dataLength <= 8 * 1024 * 1024,
                  fields[6].utf8.count == dataLength * 2,
                  fields[6].utf8.allSatisfy(Self.isHex),
                  let auth = Self.hex(fields[7]), auth.count == 10 else { return nil }
            self.salt = salt
            self.keyBytes = 8 + 8 * mode
            self.verifier = UInt32(verifier[0]) << 8 | UInt32(verifier[1])
        }
        private static func isHex(_ value: UInt8) -> Bool {
            (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value)
        }
        private static func hex(_ value: Substring) -> [UInt8]? {
            let bytes = Array(value.utf8)
            guard bytes.count % 2 == 0, bytes.allSatisfy(isHex) else { return nil }
            func nibble(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : (byte | 32) - 87 }
            return stride(from: 0, to: bytes.count, by: 2).map { nibble(bytes[$0]) << 4 | nibble(bytes[$0 + 1]) }
        }
    }
}
