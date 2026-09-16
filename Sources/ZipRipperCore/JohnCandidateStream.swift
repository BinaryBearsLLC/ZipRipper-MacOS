import Foundation

/// Pull-based John --stdout stream. The pipe applies backpressure while Metal
/// and full verification run; no unbounded candidate file or queue is created.
/// Resume replays the same deterministic generator and skips only committed
/// candidates, never John's buffered/read-ahead stdout checkpoint.
enum CandidateStreamError: Error { case nonUTF8 }

final class JohnCandidateStream: @unchecked Sendable {
    private let process: Process
    private let output: Pipe
    private let errors: Pipe
    private let drained = DispatchGroup()
    private let exited = DispatchGroup()
    private let lock = NSLock()
    private var diagnostic = Data()
    private var data = Data()
    private var ended = false
    private var stopped = false
    private var closed = false
    init(executable: URL, arguments: [String], directory: URL) throws {
        process = Process(); output = Pipe(); errors = Pipe()
        try ExactProcessArguments.configure(process, executable: executable, arguments: arguments); process.currentDirectoryURL = directory
        process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
        let completion = exited
        completion.enter()
        process.terminationHandler = { _ in completion.leave() }
        do { try process.run() } catch { process.terminationHandler = nil; completion.leave(); throw error }
        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { drained.leave() }
            while true {
                let chunk = errors.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                lock.lock()
                if diagnostic.count < 65536 { diagnostic.append(chunk.prefix(65536 - diagnostic.count)) }
                lock.unlock()
            }
        }
    }
    func interrupt() {
        lock.lock(); stopped = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }
    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true; lock.unlock()
        interrupt()
        // SIGPIPE also releases a generator blocked writing its stdout buffer.
        try? output.fileHandleForReading.close()
        exited.wait(); drained.wait()
        try? errors.fileHandleForReading.close()
    }
    deinit { close() }
    func next() throws -> String? {
        while true {
            lock.lock(); let cancelled = stopped; lock.unlock()
            if cancelled { throw CancellationError() }
            if let index = data.firstIndex(of: 10) {
                let line = data.prefix(upTo: index)
                guard let candidate = String(data: line, encoding: .utf8) else { throw CandidateStreamError.nonUTF8 }
                data.removeSubrange(...index)
                return candidate
            }
            if ended {
                if !data.isEmpty {
                    defer { data.removeAll() }
                    guard let candidate = String(data: data, encoding: .utf8) else { throw CandidateStreamError.nonUTF8 }
                    return candidate
                }
                exited.wait(); drained.wait()
                guard process.terminationStatus == 0 else {
                    throw RecoveryError.message("Candidate generation failed: \(JohnResult.redactedDiagnostics(String(decoding: diagnostic, as: UTF8.self)).suffix(1600))")
                }
                return nil
            }
            guard data.count < 1024 * 1024 else { throw RecoveryError.message("A generated candidate exceeds the safe line limit.") }
            let chunk = try output.fileHandleForReading.read(upToCount: 65536) ?? Data()
            if chunk.isEmpty { ended = true } else { data.append(chunk) }
        }
    }
}
