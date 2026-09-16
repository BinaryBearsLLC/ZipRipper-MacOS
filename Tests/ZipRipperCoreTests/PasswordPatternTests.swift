import XCTest
@testable import ZipRipperCore

final class PasswordPatternTests: XCTestCase {
    func testComposeAndReopenRememberedPassword() throws {
        let pattern = PasswordPattern(parts: [.init(kind: .text, text: "Summer"), .init(kind: .digit, count: 4), .init(kind: .symbol)])
        XCTAssertEqual(pattern.mask, "Summer?d?d?d?d?s")
        XCTAssertEqual(pattern.example, "Summer0000!")
        XCTAssertTrue(pattern.isValid)
        let reopened = try PasswordPattern(mask: pattern.mask)
        XCTAssertEqual(reopened.parts.count, 3)
        XCTAssertEqual(reopened.parts[1].count, 4)
        XCTAssertEqual(reopened.mask, pattern.mask)
    }
    func testLiteralMaskPunctuationStaysLiteral() throws {
        let literal = #"?l[ab]\end$`"#
        let pattern = PasswordPattern(parts: [.init(kind: .text, text: literal)])
        XCTAssertEqual(try PasswordPattern(mask: pattern.mask).example, literal)
        XCTAssertEqual(pattern.mask, #"??l\[ab\]\\end$`"#)
    }
    func testUnsupportedMaskIsNeverSilentlyChanged() {
        for mask in ["[a-z]?d", "?h", #"\x41"#, "?", "café", "a\nb"] {
            XCTAssertThrowsError(try PasswordPattern(mask: mask), mask)
        }
        XCTAssertFalse(PasswordPattern().isValid)
        XCTAssertFalse(PasswordPattern(parts: [.init(kind: .text, text: "é")]).isValid)
        XCTAssertFalse(PasswordPattern(parts: [.init(kind: .digit, count: 33)]).isValid)
        XCTAssertFalse(PasswordPattern(parts: [.init(kind: .text, text: String(repeating: "a", count: 320))]).isValid)
    }
    func testGeneratedPatternUsesActualJohnGrammar() async throws {
        guard let path = ProcessInfo.processInfo.environment["ZIPRIPPER_RUNTIME"] else { throw XCTSkip("Set ZIPRIPPER_RUNTIME for actual John generation") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let literal = #"?l[ab]\"#
        let pattern = PasswordPattern(parts: [.init(kind: .text, text: literal), .init(kind: .digit)])
        let output = try await ProcessRunner().run(executable: URL(fileURLWithPath: path).appendingPathComponent("bin/john"), arguments: ["--stdout", "--mask=" + pattern.mask], directory: dir)
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        XCTAssertEqual(Set(output.stdout.split(separator: "\n").map(String.init)), Set((0...9).map { literal + String($0) }))
        for (kind, count) in [(PasswordPattern.Kind.digit, 10), (.lowercase, 26), (.uppercase, 26), (.symbol, 33), (.any, 95)] {
            let mask = PasswordPattern(parts: [.init(kind: kind)]).mask
            let generated = try await ProcessRunner().run(executable: URL(fileURLWithPath: path).appendingPathComponent("bin/john"), arguments: ["--stdout", "--mask=" + mask], directory: dir)
            XCTAssertEqual(generated.exitCode, 0, generated.stderr)
            XCTAssertEqual(Set(generated.stdout.split(separator: "\n")).count, count, kind.rawValue)
        }
    }
}
