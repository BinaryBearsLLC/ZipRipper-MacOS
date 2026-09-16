import Foundation

public struct CommandResult {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

private final class CapturedOutput: @unchecked Sendable {
    let lock = NSLock()
    var data = Data()
    var overflow = false
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + chunk.count <= 64 * 1024 * 1024 { data.append(chunk) } else { overflow = true }
    }
}

/// One command at a time. Arguments preserve exact UTF-8 bytes. Both pipes are drained on
/// separate workers, including when the child writes more than a pipe buffer.
public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var shouldInterrupt = false
    public init() {}
    public func reset() { lock.lock(); shouldInterrupt = false; lock.unlock() }
    public func interrupt() {
        lock.lock(); shouldInterrupt = true; let active = process; lock.unlock()
        // John forwards SIGTERM to its fork workers and checkpoints gracefully.
        // SIGINT to the parent alone assumes a terminal process-group signal.
        if let active, active.isRunning { active.terminate() }
    }
    public func requestStatus() {
        lock.lock(); let active = process; lock.unlock()
        if let active, active.isRunning { kill(active.processIdentifier, SIGUSR1) }
    }
    public func run(executable: URL, arguments: [String], directory: URL? = nil, environment: [String: String]? = nil, streamStandardOutput: Bool = false, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) { [self] in
            try execute(executable: executable, arguments: arguments, directory: directory, environment: environment, streamStandardOutput: streamStandardOutput, onOutput: onOutput)
        }.value
    }
    private func execute(executable: URL, arguments: [String], directory: URL?, environment: [String: String]?, streamStandardOutput: Bool, onOutput: (@Sendable (String) -> Void)?) throws -> CommandResult {
            let p = Process(); try ExactProcessArguments.configure(p, executable: executable, arguments: arguments); p.currentDirectoryURL = directory
            if let environment { p.environment = environment }
            let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
            p.standardInput = FileHandle.nullDevice
            let output = CapturedOutput(), errors = CapturedOutput(), group = DispatchGroup()
            lock.lock()
            if shouldInterrupt { lock.unlock(); throw CancellationError() }
            guard process == nil else { lock.unlock(); throw RecoveryError.message("A recovery command is already running.") }
            process = p
            do { try p.run() } catch { process = nil; lock.unlock(); throw error }
            lock.unlock()
            defer { lock.lock(); process = nil; lock.unlock() }
            for (pipe, capture, isError) in [(out, output, false), (err, errors, true)] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    while true {
                        let chunk = pipe.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        capture.append(chunk)
                        if isError || streamStandardOutput, let text = String(data: chunk, encoding: .utf8) { onOutput?(text) }
                    }
                }
            }
            p.waitUntilExit(); group.wait()
            try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()
            guard !output.overflow, !errors.overflow else { throw RecoveryError.message("The recovery engine produced more output than this version can safely handle.") }
            return CommandResult(exitCode: p.terminationStatus, stdout: String(decoding: output.data, as: UTF8.self), stderr: String(decoding: errors.data, as: UTF8.self))
    }
}
