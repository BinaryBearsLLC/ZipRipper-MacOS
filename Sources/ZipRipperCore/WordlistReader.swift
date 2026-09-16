import Foundation
import Darwin

public struct WordlistInspection: Sendable {
    public let byteCount: Int64
    public var candidateCount: UInt64? = nil
    public var summary: String { "\(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)) · UTF-8 text · checked fully when the session starts" }
}

/// Reads and stages arbitrarily large lists with a 64 KiB read buffer and a
/// maximum 1 MiB line. No file-size-dependent allocation or line index is used.
public final class WordlistReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var finished = false
    private static let maximumLine = 1024 * 1024
    private static let commentPrefix = Array("#!comment:".utf8)
    public init(url: URL) throws { handle = try Self.openRegular(url) }
    deinit { try? handle.close() }

    private static func openRegular(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RecoveryError.message("Cannot read this wordlist. Check its location and file permissions.") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd); throw RecoveryError.message("Choose a regular text file for the wordlist, not a folder, pipe or device.")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    private static func validateLine(_ line: Data) throws {
        guard line.count <= maximumLine else { throw RecoveryError.message("The wordlist contains a line larger than 1 MiB. Choose a file with one password per line.") }
        guard !line.contains(where: { $0 == 0 || ($0 < 32 && ![9, 13].contains($0)) }) else { throw RecoveryError.message("This wordlist contains binary or control bytes. Extract compressed downloads and choose a UTF-8 text file.") }
        guard String(data: line, encoding: .utf8) != nil else { throw RecoveryError.message("This wordlist contains invalid UTF-8 text. Convert it to UTF-8 and try again.") }
    }
    private static func checkHeader(_ data: Data, url: URL) throws {
        let signatures: [[UInt8]] = [[0x1f, 0x8b], [0x50, 0x4b, 3, 4], [0x42, 0x5a, 0x68], [0xfd, 0x37, 0x7a, 0x58, 0x5a], [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c], [0x52, 0x61, 0x72, 0x21], [0x28, 0xb5, 0x2f, 0xfd]]
        guard !["gz", "zip", "bz2", "xz", "7z", "rar", "zst", "tar"].contains(url.pathExtension.lowercased()), !signatures.contains(where: { data.starts(with: $0) }) else {
            throw RecoveryError.message("This wordlist is compressed. Extract it first, then choose the UTF-8 text file inside.")
        }
        guard !data.starts(with: [0xff, 0xfe]), !data.starts(with: [0xfe, 0xff]) else { throw RecoveryError.message("This wordlist uses UTF-16. Convert it to UTF-8 first.") }
        guard !data.isEmpty else { throw RecoveryError.message("This wordlist is empty. Choose a file containing one password per line.") }
    }
    public static func inspect(url: URL) throws -> WordlistInspection {
        let handle = try openRegular(url); defer { try? handle.close() }
        var info = stat(); guard fstat(handle.fileDescriptor, &info) == 0 else { throw RecoveryError.message("Cannot inspect this wordlist.") }
        let header = try handle.read(upToCount: 65536) ?? Data()
        try checkHeader(header, url: url)
        // Validate complete lines. The final sampled line may end inside UTF-8.
        if let newline = header.lastIndex(of: 10) {
            for line in header.prefix(through: newline).split(separator: 10, omittingEmptySubsequences: false) { try validateLine(Data(line)) }
        } else if Int64(header.count) == info.st_size { try validateLine(header) }
        else {
            guard !header.contains(0) else { throw RecoveryError.message("This wordlist contains binary bytes. Choose UTF-8 text.") }
            // Trim only a potentially incomplete final scalar, never invalid interior bytes.
            guard (0...3).contains(where: { String(data: header.dropLast($0), encoding: .utf8) != nil }) else { throw RecoveryError.message("This wordlist contains invalid UTF-8 text.") }
        }
        return WordlistInspection(byteCount: info.st_size)
    }

    /// Validates while copying to a private temporary file, then atomically
    /// publishes without overwriting an existing destination. Cancellation and
    /// errors remove only this operation's partial copy.
    @discardableResult public static func stage(source: URL, destination: URL, isCancelled: () -> Bool = { false }, progress: (Int64, Int64) -> Void = { _, _ in }) throws -> WordlistInspection {
        let input = try openRegular(source); defer { try? input.close() }
        var before = stat(); guard fstat(input.fileDescriptor, &before) == 0 else { throw RecoveryError.message("Cannot inspect this wordlist.") }
        let total = before.st_size
        let parent = destination.deletingLastPathComponent()
        func check() throws { if isCancelled() { throw CancellationError() } }
        func checkSpace(_ remaining: Int64) throws {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: parent.path)
            if let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < remaining + 16 * 1024 * 1024 {
                throw RecoveryError.message("Not enough free disk space to save this wordlist in the session. It needs \(ByteCountFormatter.string(fromByteCount: remaining, countStyle: .file)) plus working space.")
            }
        }
        try check(); try checkSpace(total)
        let partial = parent.appendingPathComponent("wordlist-\(UUID().uuidString).partial")
        let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RecoveryError.message("Cannot create the session wordlist copy.") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close(); try? FileManager.default.removeItem(at: partial) }
        var pending = Data(), copied: Int64 = 0, nextSpaceCheck: Int64 = 64 * 1024 * 1024
        var candidates: UInt64 = 0
        func countLine(_ line: Data) {
            // John's wordlist comment convention; keep empty candidates.
            let text = line.starts(with: [0xef, 0xbb, 0xbf]) ? line.dropFirst(3) : line[...]
            if !text.starts(with: commentPrefix) { candidates += 1 }
        }
        progress(0, total)
        while true {
            // Foundation FileHandle reads return autoreleased NSData. Drain on
            // every chunk even when called outside a Cocoa event-loop pool.
            let hasChunk = try autoreleasepool { () throws -> Bool in
                try check()
                let chunk = try input.read(upToCount: 65536) ?? Data()
                if copied == 0 { try checkHeader(chunk, url: source) }
                if chunk.isEmpty { return false }
                var start = chunk.startIndex
                for index in chunk.indices where chunk[index] == 10 {
                    pending.append(chunk[start..<index]); try validateLine(pending); countLine(pending); pending.removeAll(keepingCapacity: true)
                    start = chunk.index(after: index)
                }
                pending.append(chunk[start...])
                guard pending.count <= maximumLine else { throw RecoveryError.message("The wordlist contains a line larger than 1 MiB.") }
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                if copied >= nextSpaceCheck { try checkSpace(max(0, total - copied)); nextSpaceCheck = copied + 64 * 1024 * 1024 }
                progress(copied, total)
                return true
            }
            if !hasChunk { break }
        }
        try validateLine(pending); if !pending.isEmpty { countLine(pending) }; try check()
        var after = stat()
        guard fstat(input.fileDescriptor, &after) == 0, copied == total, after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw RecoveryError.message("The wordlist changed while being copied. Try again after it has finished downloading or editing.")
        }
        try output.synchronize(); try output.close(); try check()
        guard link(partial.path, destination.path) == 0 else { throw RecoveryError.message("Cannot publish the session wordlist copy. The existing destination was preserved.") }
        return WordlistInspection(byteCount: copied, candidateCount: candidates)
    }
    private static func decodedLine(_ data: Data) throws -> String {
        try validateLine(data)
        var line = data
        // Match John's check_bom() for each word under --input-encoding=UTF-8.
        if line.starts(with: [0xef, 0xbb, 0xbf]) { line.removeFirst(3) }
        if line.last == 13 { line.removeLast() }
        return String(decoding: line, as: UTF8.self)
    }
    public func next() throws -> String? {
        try autoreleasepool {
            while let line = try readNext() { if !line.hasPrefix("#!comment:") { return line } }
            return nil
        }
    }
    private func readNext() throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let text = try Self.decodedLine(Data(buffer.prefix(upTo: newline)))
                buffer.removeSubrange(...newline)
                return text
            }
            if finished {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return try Self.decodedLine(buffer)
            }
            guard buffer.count <= Self.maximumLine else { throw RecoveryError.message("The wordlist contains a line larger than 1 MiB.") }
            let chunk = try handle.read(upToCount: 65536) ?? Data()
            if chunk.isEmpty { finished = true } else { buffer.append(chunk) }
        }
    }
}
