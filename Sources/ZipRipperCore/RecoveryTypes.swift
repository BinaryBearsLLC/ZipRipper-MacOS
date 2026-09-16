import Foundation

public enum RecoveryStrategy: String, Codable, CaseIterable, Identifiable {
    case recommended, wordlist, mask, exhaustive
    public var id: String { rawValue }
    public var title: String {
        switch self { case .recommended: return "Common passwords"; case .wordlist: return "My wordlist"; case .mask: return "I remember part of it"; case .exhaustive: return "Try every combination" }
    }
}
public enum ComputeBackend: String, Codable, CaseIterable, Identifiable {
    case automatic, cpu, metal
    public var id: String { rawValue }
    public var title: String { switch self { case .automatic: return "Automatic"; case .cpu: return "CPU"; case .metal: return "Metal GPU" } }
}
public enum JobPhase: String, Codable {
    case preparing, running, paused, recovered, partial, exhausted, failed, stopped
    public var title: String { rawValue.capitalized }
    public var resumable: Bool { self == .paused || self == .running || self == .preparing || self == .stopped }
}
public struct RecoveryConfiguration: Codable, Equatable {
    public var archivePath: String
    public var strategy: RecoveryStrategy = .recommended
    public var backend: ComputeBackend = .automatic
    public var wordlistPath: String = ""
    public var mask: String = ""
    public var minimumLength: Int = 1
    public var maximumLength: Int = 6
    public var characterSet: String = "Digits"
    public var workers: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)
    public var useRules: Bool = true
    public init(archivePath: String) { self.archivePath = archivePath }
    public var exhaustiveLengthLimit: Int { characterSet == "Digits" ? 20 : 13 }
    public func validate() throws {
        guard ["zip", "rar", "7z", "pdf"].contains(URL(fileURLWithPath: archivePath).pathExtension.lowercased()) else { throw RecoveryError.message("Choose a ZIP, RAR, 7z or PDF file.") }
        guard workers >= 1 && workers <= ProcessInfo.processInfo.activeProcessorCount else { throw RecoveryError.message("Choose a valid CPU worker count.") }
        if strategy == .wordlist && wordlistPath.isEmpty { throw RecoveryError.message("Choose a UTF-8 wordlist first.") }
        if strategy == .mask {
            guard !mask.isEmpty && !mask.contains("\n") && !mask.contains("\0") else { throw RecoveryError.message("Enter a password pattern, for example Summer?d?d?d?d.") }
        }
        if strategy == .exhaustive {
            guard (1...exhaustiveLengthLimit).contains(minimumLength), (minimumLength...exhaustiveLengthLimit).contains(maximumLength) else { throw RecoveryError.message("The included \(characterSet) search supports lengths 1–\(exhaustiveLengthLimit). Use a custom pattern for longer passwords.") }
            guard ["Digits", "Lowercase", "Alphanumeric", "ASCII"].contains(characterSet) else { throw RecoveryError.message("Choose a supported character set.") }
        }
    }
}
public struct RecoveryJob: Codable, Identifiable {
    public var id: UUID
    public var configuration: RecoveryConfiguration
    public var createdAt: Date
    public var updatedAt: Date
    public var phase: JobPhase
    public var status: String
    public var archiveDigest: String?
    public var processedCandidates: UInt64
    public var elapsedSeconds: Double
    public var engine: String
    public var candidateCount: Double?
    public var measuredRate: Double?
    public var resolvedBackend: ComputeBackend?
    public var name: String { URL(fileURLWithPath: configuration.archivePath).lastPathComponent }
    public init(configuration: RecoveryConfiguration) {
        id = UUID(); self.configuration = configuration; createdAt = Date(); updatedAt = Date()
        phase = .preparing; status = "Preparing recovery"; processedCandidates = 0; elapsedSeconds = 0; engine = "CPU"
    }
}
public enum RecoveryError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public enum JohnResult {
    public static func redactedDiagnostics(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            guard line.contains("g/s") else { return line }
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            guard let end = tokens.firstIndex(where: { $0.hasSuffix("C/s") && !$0.dropLast(3).isEmpty && $0.dropLast(3).allSatisfy({ "0123456789.,eE+-kKMGT".contains($0) }) }) else { return "Recovery progress updated" }
            return tokens[...end].joined(separator: " ") + " [candidates hidden]"
        }.joined(separator: "\n")
    }
    // Every job owns a pot file containing only that job's hashes. John uses the
    // first colon as its hash/password boundary; password colons are literal.
    public static func passwords(fromPot pot: String) -> [String] {
        var seen = Set<Data>()
        return pot.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let password = String(line[line.index(after: colon)...])
            return seen.insert(Data(password.utf8)).inserted ? password : nil
        }
    }
    public static func crackedCount(fromShow text: String) -> Int {
        for line in text.split(separator: "\n").reversed() {
            if line.contains("password hash") && line.contains("cracked"), let count = Int(line.prefix(while: { $0.isNumber })) { return count }
        }
        return 0
    }
    public static func remainingCount(fromShow text: String) -> Int? {
        for line in text.split(separator: "\n").reversed() where line.contains("password hash") && line.contains("cracked,") {
            guard let comma = line.lastIndex(of: ",") else { continue }
            return Int(line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber }))
        }
        return nil
    }
}
