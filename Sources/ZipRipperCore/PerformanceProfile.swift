import Foundation
import CryptoKit
import Metal

public struct PerformanceProfile: Codable {
    public let identity: String
    public let date: Date
    public let results: [BenchmarkResult]
    public init(identity: String, results: [BenchmarkResult]) {
        self.identity = identity; self.results = results; date = Date()
    }
    public static func identity(runtime: URL, appVersion: String) -> String {
        let hardware = "\(ProcessInfo.processInfo.processorCount)|\(ProcessInfo.processInfo.physicalMemory)|\(MTLCreateSystemDefaultDevice()?.name ?? "CPU")|\(ProcessInfo.processInfo.operatingSystemVersionString)"
        var data = Data(("pipeline-v2|" + appVersion + "|" + hardware).utf8)
        for file in ["dependency-manifest.json", "build-info.json"] {
            data.append((try? Data(contentsOf: runtime.appendingPathComponent(file))) ?? Data())
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// A reference only; live/file-specific measurements supersede this value.
    public func referenceRate(lines: [String], backend: ComputeBackend, workers: Int) -> Double? {
        guard let vectors = try? RecoveryBenchmark.vectors() else { return nil }
        func signature(_ line: String) -> String? {
            if let hash = ArchiveGPUHash(line) { return "\(hash.kind)|\(hash.rounds)|\(hash.type)" }
            if let start = line.range(of: "$pdf$") { return "pdf|" + line[start.upperBound...].split(separator: "*").prefix(3).joined(separator: "*") }
            if let start = line.range(of: "$zip2$*") { return "zip|" + line[start.upperBound...].split(separator: "*").prefix(2).joined(separator: "*") }
            return nil
        }
        let label = backend == .metal ? "Metal GPU" : (workers == 1 ? "CPU · 1 worker" : "CPU · multicore")
        var seconds = 0.0
        for line in lines {
            guard let key = signature(line), let vector = vectors.first(where: { signature($0.hashLine) == key }),
                  let result = results.first(where: { $0.id == vector.id + "-" + label }), let measured = result.passwordsPerSecond, measured > 0 else { return nil }
            let rate = backend == .cpu && workers > 1 ? measured * Double(workers) / Double(ProcessInfo.processInfo.activeProcessorCount) : measured
            seconds += 1 / rate
        }
        return seconds > 0 ? 1 / seconds : nil
    }
    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func load(from url: URL, identity: String) -> PerformanceProfile? {
        guard let data = try? Data(contentsOf: url), let profile = try? JSONDecoder().decode(Self.self, from: data), profile.identity == identity else { return nil }
        return profile
    }
}

/// No timers or candidate enumeration: callers sample at most once per 10 seconds.
public struct SearchEstimate {
    private var lastUpdate = -Double.infinity
    public init() {}
    public mutating func shouldUpdate(at time: Double) -> Bool {
        guard time - lastUpdate >= 10 else { return false }
        lastUpdate = time; return true
    }
    public static func candidateCount(_ config: RecoveryConfiguration, wordCount: UInt64?) -> Double? {
        switch config.strategy {
        case .recommended, .wordlist:
            // Rules reject, duplicate and expand according to each input word.
            guard !config.useRules, let wordCount else { return nil }
            return Double(wordCount)
        case .exhaustive:
            guard config.minimumLength > 0, config.maximumLength >= config.minimumLength, config.maximumLength <= 20 else { return nil }
            let alphabet: Double = ["Digits": 10, "Lowercase": 26, "Alphanumeric": 62, "ASCII": 95][config.characterSet] ?? 0
            guard alphabet > 0 else { return nil }
            return (config.minimumLength...config.maximumLength).reduce(0) { $0 + pow(alphabet, Double($1)) }
        case .mask:
            // Only the documented, simple mask grammar has an inexpensive exact count.
            let chars = Array(config.mask); var i = 0, count = 1.0
            guard !chars.isEmpty else { return nil }
            while i < chars.count {
                if chars[i] == "[" || chars[i] == "]" || chars[i] == "\\" { return nil }
                if chars[i] == "?" {
                    i += 1; guard i < chars.count else { return nil }
                    guard let width: Double = ["d": 10, "l": 26, "u": 26, "s": 33, "a": 95, "?": 1][chars[i]] else { return nil }
                    count *= width
                }
                i += 1
            }
            return count.isFinite ? count : nil
        }
    }
    public static func remaining(total: Double?, completed: Double, rate: Double?) -> Double? {
        guard let total, let rate, total.isFinite, completed.isFinite, rate.isFinite, rate > 0 else { return nil }
        return max(0, total - completed) / rate
    }
    public static func text(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Unavailable" }
        if seconds < 60 { return "< 1 min" }
        if seconds < 3600 { return "~\(Int(ceil(seconds / 60))) min" }
        if seconds < 86400 { return "~\(Int(ceil(seconds / 3600))) h" }
        if seconds < 86400 * 365 { return "~\(Int(ceil(seconds / 86400))) days" }
        let years = seconds / (86400 * 365)
        return years < 1e6 ? "~\(Int(ceil(years)).formatted()) years" : "> 1 million years"
    }
}
