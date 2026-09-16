import XCTest
@testable import ZipRipperCore

final class RecoveryTests: XCTestCase {
    func testExhaustiveSearchRejectsLengthsBeyondIncludedCharacterSet() throws {
        var c = RecoveryConfiguration(archivePath: "/tmp/a.zip")
        c.strategy = .exhaustive; c.characterSet = "Digits"; c.maximumLength = 21
        XCTAssertThrowsError(try c.validate())
        c.characterSet = "ASCII"; c.maximumLength = 14
        XCTAssertThrowsError(try c.validate())
    }
    func testJohnStatusDoesNotRevealCandidates() {
        XCTAssertEqual(JohnResult.redactedDiagnostics("1g 0:00:00:01 DONE 1g/s 2p/s 2c/s 2C/s ZipRipper42!\n"), "1g 0:00:00:01 DONE 1g/s 2p/s 2c/s 2C/s [candidates hidden]\n")
        XCTAssertFalse(JohnResult.redactedDiagnostics("1g 0:00:01 1g/s 2p/s 2c/s 2C/s Secret/s").contains("Secret"))
        XCTAssertEqual(JohnResult.redactedDiagnostics("1g 0:00:01 1g/s 2p/s 2c/s 2C/s 1.00C/s"), "1g 0:00:01 1g/s 2p/s 2c/s 2C/s [candidates hidden]")
    }
    func testStrategyRejectsEmptyMaskAndUnboundedSearch() throws {
        var c = RecoveryConfiguration(archivePath: "/tmp/a.zip")
        c.strategy = .mask; c.mask = ""
        XCTAssertThrowsError(try c.validate())
        c.mask = "Summer?d?d"; XCTAssertNoThrow(try c.validate())
        c.strategy = .exhaustive; c.minimumLength = 9; c.maximumLength = 3
        XCTAssertThrowsError(try c.validate())
        c.minimumLength = 1; c.maximumLength = 6; XCTAssertNoThrow(try c.validate())
    }
    func testPasswordParsingPreservesColonInPassword() {
        let output = "archive.zip:hello:world:entry.txt:archive.zip\n\n1 password hash cracked, 0 left\n"
        XCTAssertEqual(JohnResult.passwords(fromPot: "$hash$:hello:world\n"), ["hello:world"])
        XCTAssertEqual(JohnResult.crackedCount(fromShow: output), 1)
        XCTAssertEqual(JohnResult.crackedCount(fromShow: "0 password hashes cracked, 1 left"), 0)
        let passwords = JohnResult.passwords(fromPot: "$one$:é\n$two$:e\u{301}\n")
        XCTAssertEqual(passwords.count, 2)
        XCTAssertNotEqual(Data(passwords[0].utf8), Data(passwords[1].utf8))
    }
    func testStoreKeepsSameNamedJobsSeparateAndPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(root: root)
        let first = try store.create(configuration: .init(archivePath: "/one/report.zip"))
        let second = try store.create(configuration: .init(archivePath: "/two/report.zip"))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try store.load().count, 2)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.directory(for: first.id).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        var paused = first; paused.phase = .paused; paused.processedCandidates = 4096
        try store.save(paused)
        XCTAssertEqual(try store.load().first(where: { $0.id == first.id })?.processedCandidates, 4096)
    }
    func testProcessDoesNotInterpretShellMetacharacters() async throws {
        let runner = ProcessRunner()
        let literal = "hello; $(touch /tmp/zipripper-must-not-exist) `id`"
        let r = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", literal])
        XCTAssertEqual(r.stdout, literal)
        XCTAssertEqual(r.exitCode, 0)
    }
    func testProcessDrainsBothPipesWithoutDeadlock() async throws {
        let runner = ProcessRunner()
        let r = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "i=0; while [ $i -lt 5000 ]; do echo stdout-line; echo stderr-line >&2; i=$((i+1)); done"])
        XCTAssertEqual(r.stdout.components(separatedBy: "stdout-line").count - 1, 5000)
        XCTAssertEqual(r.stderr.components(separatedBy: "stderr-line").count - 1, 5000)
    }
}
