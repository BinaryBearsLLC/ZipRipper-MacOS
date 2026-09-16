import Foundation

public struct BenchmarkResult: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let backend: String
    public let passwordsPerSecond: Double?
    public let detail: String
}

struct BenchmarkVector: Decodable {
    let id: String
    let name: String
    let format: String
    let hashLine: String
    let password: String
    let metal: Bool
}

/// One-shot, sequential local benchmark. CPU numbers are John's measured p/s
/// for a complete verifier with one worker and with multiple workers. GPU numbers measure the
/// complete Metal filtering + survivor verification pipeline on synthetic samples.
public final class RecoveryBenchmark: @unchecked Sendable {
    private let runtime: URL
    private let runner = ProcessRunner()
    private let lock = NSLock()
    private var cancelled = false
    private var running = false
    private let workers: Int
    public init(runtime: URL, workers: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.runtime = runtime; self.workers = max(1, min(workers, ProcessInfo.processInfo.activeProcessorCount))
    }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock(); runner.interrupt() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func checkCancellation() throws { if isCancelled { throw CancellationError() } }
    private func begin() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { throw RecoveryError.message("A benchmark is already running.") }
        guard !cancelled else { throw CancellationError() }
        running = true
    }
    private func finish() { lock.lock(); running = false; lock.unlock() }
    static func vectors() throws -> [BenchmarkVector] {
        guard let url = CoreResources.bundle.url(forResource: "benchmark-vectors", withExtension: "json") else { throw RecoveryError.message("Benchmark samples are missing.") }
        return try JSONDecoder().decode([BenchmarkVector].self, from: Data(contentsOf: url))
    }
    private static let rateExpression = try! NSRegularExpression(pattern: #"(?:^|\s)([0-9]+(?:\.[0-9]+)?)([kKMGT]?)p/s(?:\s|$)"#)
    static func measuredRate(_ text: String) -> Double? {
        let regex = rateExpression
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let numberRange = Range(match.range(at: 1), in: text), let number = Double(text[numberRange]),
              let suffixRange = Range(match.range(at: 2), in: text) else { return nil }
        let multipliers: [String: Double] = ["": 1, "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12]
        let multiplier = multipliers[String(text[suffixRange])] ?? 1
        let rate = number * multiplier
        return rate.isFinite && rate > 0 ? rate : nil
    }
    /// Latest status per fork worker; repeated final lines must not double-count.
    public static func aggregateRate(_ text: String, workers: Int) -> Double? {
        if workers <= 1 { return measuredRate(text) }
        var latest: [Int: Double] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let first = line.split(whereSeparator: { $0.isWhitespace }).first,
                  let worker = Int(first), (1...workers).contains(worker),
                  let rate = measuredRate(line) else { continue }
            latest[worker] = rate
        }
        return latest.count == workers ? latest.values.reduce(0, +) : nil
    }
    private static let percentExpression = try! NSRegularExpression(pattern: #"(?:^|\s)([0-9]+(?:\.[0-9]+)?)%"#)
    public static func progressFraction(_ text: String, workers: Int) -> Double? {
        var latest: [Int: Double] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let match = percentExpression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line), let percent = Double(line[range]) else { continue }
            let worker = workers <= 1 ? 1 : Int(line.split(whereSeparator: { $0.isWhitespace }).first ?? "") ?? 0
            if (1...max(1, workers)).contains(worker) { latest[worker] = min(1, max(0, percent / 100)) }
        }
        return latest.count == max(1, workers) ? latest.values.reduce(0, +) / Double(max(1, workers)) : nil
    }
    /// Measures this file's encryption parameters. Temporary hashes/pots never
    /// enter the recovery checkpoint; cancellation leaves the search untouched.
    public func calibrate(lines: [String], candidates: [String], gpu: MetalArchiveFilter) async throws -> (cpu: Double, metal: Double) {
        try begin(); defer { finish() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZipRipper-calibration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var cpuSeconds = 0.0
        let length = min(32, max(1, candidates.map { $0.utf8.count }.sorted().dropFirst(candidates.count / 2).first ?? 17))
        for (format, hashes) in try JohnEngine.hashGroups(lines.joined(separator: "\n")) {
            try checkCancellation()
            let hash = directory.appendingPathComponent("hash.txt")
            try Data((hashes.joined(separator: "\n") + "\n").utf8).write(to: hash)
            var args = [hash.path, "--format=\(format)", "--mask=\(String(repeating: "?a", count: max(8, length)))", "--input-encoding=UTF-8", "--save-memory=3", "--max-run-time=2", "--progress-every=1", "--pot=\(directory.appendingPathComponent("cpu.pot").path)", "--session=\(directory.appendingPathComponent("cpu").path)"]
            if workers > 1 { args.append("--fork=\(workers)") }
            var environment = ProcessInfo.processInfo.environment; environment["OMP_NUM_THREADS"] = "1"
            let result = try await runner.run(executable: runtime.appendingPathComponent("bin/john"), arguments: args, directory: directory, environment: environment)
            try checkCancellation()
            guard (result.exitCode == 0 || (result.exitCode == 2 && result.stderr.contains("max run-time reached"))), let rate = Self.aggregateRate(result.stderr + "\n" + result.stdout, workers: workers) else { throw RecoveryError.message("CPU calibration unavailable") }
            cpuSeconds += 1 / rate
        }
        let metal = try await measureGPU(lines: lines, candidates: candidates, gpu: gpu, directory: directory)
        return (1 / cpuSeconds, metal)
    }
    private func measureGPU(lines: [String], candidates: [String], gpu: MetalArchiveFilter, directory: URL, knownPassword: String? = nil) async throws -> Double {
        let groups = try JohnEngine.hashGroups(lines.joined(separator: "\n"))
        for (format, hashes) in groups {
            try Data((hashes.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("gpu-\(format).txt"))
        }
        let start = ProcessInfo.processInfo.systemUptime
        var processed = 0
        repeat {
            try checkCancellation()
            var batch = candidates
            // Exercise a known survivor once, then measure ordinary batches.
            // Forcing a match in every batch would mostly time process startup.
            let verifyingKnown = knownPassword != nil && processed == 0
            if verifyingKnown, let knownPassword, !batch.isEmpty { batch[batch.count / 2] = knownPassword }
            var survivors = Set<String>()
            for line in lines { survivors.formUnion(try gpu.filter(candidates: batch, hashLine: line, isCancelled: { self.isCancelled })) }
            if !survivors.isEmpty {
                let words = directory.appendingPathComponent("survivors.txt"), pot = directory.appendingPathComponent("gpu.pot")
                try? FileManager.default.removeItem(at: pot)
                try Data((batch.filter { survivors.contains($0) }.joined(separator: "\n") + "\n").utf8).write(to: words)
                for (format, _) in groups {
                    let result = try await runner.run(executable: runtime.appendingPathComponent("bin/john"), arguments: [directory.appendingPathComponent("gpu-\(format).txt").path, "--format=\(format)", "--input-encoding=UTF-8", "--wordlist=\(words.path)", "--pot=\(pot.path)", "--session=\(directory.appendingPathComponent("verify").path)"], directory: directory)
                    try checkCancellation()
                    guard result.exitCode == 0 else { throw RecoveryError.message("GPU survivor verification failed") }
                }
                if verifyingKnown, let knownPassword {
                    let found = JohnResult.passwords(fromPot: (try? String(contentsOf: pot, encoding: .utf8)) ?? "")
                    guard found.contains(knownPassword) else { throw RecoveryError.message("Benchmark password was not verified") }
                }
            }
            processed += batch.count
        } while knownPassword != nil && ProcessInfo.processInfo.systemUptime - start < 1
        try checkCancellation()
        return Double(processed) / max(0.001, ProcessInfo.processInfo.systemUptime - start)
    }
    public func run(update: @escaping @Sendable (BenchmarkResult) -> Void) async throws -> [BenchmarkResult] {
        try begin(); defer { finish() }
        return try await withTaskCancellationHandler(operation: {
            try await execute(update: update)
        }, onCancel: { self.cancel() })
    }
    private func execute(update: @escaping @Sendable (BenchmarkResult) -> Void) async throws -> [BenchmarkResult] {
        let vectors = try Self.vectors()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZipRipper-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var results = [BenchmarkResult]()
        // Work remains off the main actor even when the caller is a SwiftUI task.
        let gpu = try? MetalArchiveFilter()
        for vector in vectors {
            for backend in ["CPU · 1 worker", "CPU · multicore", "Metal GPU"] {
                try checkCancellation()
                let id = vector.id + "-" + backend
                func row(_ rate: Double?, _ detail: String) -> BenchmarkResult { BenchmarkResult(id: id, name: vector.name, backend: backend, passwordsPerSecond: rate, detail: detail) }
                if backend == "Metal GPU" && (!vector.metal || gpu == nil || !MetalArchiveFilter.supports(hashLine: vector.hashLine)) {
                    let result = row(nil, vector.metal ? "Metal filter unavailable for this sample/device" : "CPU only · PDF revision 6 has no Metal filter")
                    results.append(result); update(result); continue
                }
                update(row(nil, "Measuring…"))
                let result: BenchmarkResult
                do {
                    if backend.hasPrefix("CPU") {
                        let count = backend == "CPU · 1 worker" ? 1 : workers
                        let hash = directory.appendingPathComponent("hash.txt")
                        try Data((vector.hashLine + "\n").utf8).write(to: hash)
                        var args = [hash.path, "--format=\(vector.format)", "--mask=zrbench?d?d?d?d?d?d?d?d?d?d", "--input-encoding=UTF-8", "--save-memory=3", "--max-run-time=2", "--progress-every=1", "--pot=\(directory.appendingPathComponent("pot").path)", "--session=\(directory.appendingPathComponent("session").path)"]
                        if count > 1 { args.append("--fork=\(count)") }
                        var environment = ProcessInfo.processInfo.environment; environment["OMP_NUM_THREADS"] = "1"
                        let output = try await runner.run(executable: runtime.appendingPathComponent("bin/john"), arguments: args, directory: directory, environment: environment)
                        try checkCancellation()
                        guard (output.exitCode == 0 || (output.exitCode == 2 && output.stderr.contains("max run-time reached"))), let rate = Self.aggregateRate(output.stderr + "\n" + output.stdout, workers: count) else {
                            throw RecoveryError.message("No throughput measurement returned by the CPU verifier")
                        }
                        result = row(rate, "John full verifier · \(count) CPU workers · aggregate p/s")
                    } else {
                        let device = gpu!
                        let warm = try device.filter(candidates: ["benchmark-wrong", vector.password], hashLine: vector.hashLine, isCancelled: { self.isCancelled })
                        guard warm.contains(vector.password), warm.count < 2 else { throw RecoveryError.message("Metal sample validation failed") }
                        let size = MetalZIPFilter.supports(hashLine: vector.hashLine) ? 4096 : MetalArchiveFilter.recommendedBatchSize
                        let candidates = (0..<size).map { "zrbench" + String(format: "%010d", $0) }
                        let rate = try await measureGPU(lines: [vector.hashLine], candidates: candidates, gpu: device, directory: directory, knownPassword: vector.password)
                        result = row(rate, "Metal + John verification · \(device.deviceName)")
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { result = row(nil, error.localizedDescription) }
                results.append(result); update(result)
            }
        }
        return results
    }
}
