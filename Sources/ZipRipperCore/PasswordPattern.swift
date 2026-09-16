import Foundation

/// A small, lossless subset of John's mask grammar for the visual composer.
/// Advanced masks stay in Recovery; they are never silently rewritten.
public struct PasswordPattern: Equatable {
    public enum Kind: String, CaseIterable {
        case text, digit, lowercase, uppercase, symbol, any
        public var token: String {
            switch self { case .text: return ""; case .digit: return "?d"; case .lowercase: return "?l"; case .uppercase: return "?u"; case .symbol: return "?s"; case .any: return "?a" }
        }
        public var title: String {
            switch self { case .text: return "Known text"; case .digit: return "Digits"; case .lowercase: return "Lowercase"; case .uppercase: return "Uppercase"; case .symbol: return "Symbols"; case .any: return "Any character" }
        }
        public var example: String {
            switch self { case .text: return ""; case .digit: return "0"; case .lowercase: return "a"; case .uppercase: return "A"; case .symbol: return "!"; case .any: return "x" }
        }
    }
    public struct Part: Identifiable, Equatable {
        public let id = UUID()
        public var kind: Kind
        public var text: String
        public var count: Int
        public init(kind: Kind, text: String = "", count: Int = 1) { self.kind = kind; self.text = text; self.count = count }
    }
    public var parts: [Part]
    public init(parts: [Part] = []) { self.parts = parts }
    public static func isPrintable(_ text: String) -> Bool { text.utf8.allSatisfy { (32...126).contains($0) } }
    public var isValid: Bool {
        !parts.isEmpty && parts.allSatisfy { $0.kind == .text ? (!$0.text.isEmpty && Self.isPrintable($0.text)) : (1...32).contains($0.count) }
            && length <= 319
    }
    public var length: Int { parts.reduce(0) { $0 + ($1.kind == .text ? $1.text.utf8.count : max(0, $1.count)) } }
    public var mask: String {
        parts.map { part in
            if part.kind != .text { return String(repeating: part.kind.token, count: max(0, min(32, part.count))) }
            return part.text.map { char in
                switch char { case "?": return "??"; case "[", "]", "\\": return "\\" + String(char); default: return String(char) }
            }.joined()
        }.joined()
    }
    public var example: String {
        parts.map { $0.kind == .text ? $0.text : String(repeating: $0.kind.example, count: max(0, min(32, $0.count))) }.joined()
    }
    /// A single illustrative sample, never an enumeration of the search space.
    public func example(at step: Int) -> String {
        var position = 0
        return parts.map { part in
            if part.kind == .text { return part.text }
            let alphabet: [UInt8]
            switch part.kind {
            case .text: return part.text
            case .digit: alphabet = Array("0123456789".utf8)
            case .lowercase: alphabet = Array("abcdefghijklmnopqrstuvwxyz".utf8)
            case .uppercase: alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
            case .symbol: alphabet = Array("!@#$%&*+-_=?:;.,".utf8)
            case .any: alphabet = Array("aB3!xY7@kM2#".utf8)
            }
            return String(bytes: (0..<max(0, min(32, part.count))).map { _ in
                defer { position += 1 }
                return alphabet[((max(0, step) % alphabet.count) + position % alphabet.count) % alphabet.count]
            }, encoding: .utf8)!
        }.joined()
    }
    public init(mask: String) throws {
        guard Self.isPrintable(mask) else { throw RecoveryError.message("Use a UTF-8 wordlist for accents or emoji.") }
        let chars = Array(mask); var i = 0; parts = []
        func appendText(_ text: String) {
            if parts.last?.kind == .text { parts[parts.count - 1].text += text }
            else { parts.append(Part(kind: .text, text: text)) }
        }
        while i < chars.count {
            switch chars[i] {
            case "\\":
                i += 1
                guard i < chars.count, "?[]\\".contains(chars[i]) else { throw Self.advancedError }
                appendText(String(chars[i]))
            case "[", "]": throw Self.advancedError
            case "?":
                i += 1; guard i < chars.count else { throw Self.advancedError }
                if chars[i] == "?" { appendText("?") }
                else {
                    guard let kind = Kind.allCases.first(where: { $0.token == "?" + String(chars[i]) }) else { throw Self.advancedError }
                    if parts.last?.kind == kind, parts.last!.count < 32 { parts[parts.count - 1].count += 1 }
                    else { parts.append(Part(kind: kind)) }
                }
            default: appendText(String(chars[i]))
            }
            i += 1
        }
    }
    private static var advancedError: RecoveryError { .message("This pattern uses advanced syntax. Keep editing it in Recovery, or start a new pattern here.") }
}
