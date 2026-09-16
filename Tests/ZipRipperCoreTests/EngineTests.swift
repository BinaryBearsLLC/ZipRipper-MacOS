import XCTest
@testable import ZipRipperCore
final class EngineTests: XCTestCase {
    func testHashLikeFilenameDoesNotChooseAlgorithm() throws {
        let groups = try JohnEngine.hashGroups("$pkzip$.zip/member:$zip2$*0*3*0*abcdef*data*$/zip2$")
        XCTAssertEqual(groups.first?.0, "ZIP")
        XCTAssertThrowsError(try JohnEngine.hashGroups("malformed:$unknown$"))
    }
    func testArgumentsKeepPathsAndMaskLiteral() throws {
        var config = RecoveryConfiguration(archivePath: "/a/it's an archive.zip")
        config.strategy = .mask; config.mask = "Ab?d?d"; config.workers = 2
        let args = try JohnEngine.arguments(configuration: config, directory: URL(fileURLWithPath: "/tmp/a b"))
        XCTAssertTrue(args.contains("--mask=Ab?d?d"))
        XCTAssertTrue(args.contains("/tmp/a b/hash.txt"))
        XCTAssertTrue(args.contains("--pot=/tmp/a b/passwords.pot"))
        XCTAssertTrue(args.contains("--fork=2"))
    }
    func testLineReaderHandlesCRLFUnicodeAndFinalLine() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("one\r\n\npäss word\nlast".utf8).write(to: path)
        let reader = try WordlistReader(url: path)
        XCTAssertEqual(try reader.next(), "one")
        XCTAssertEqual(try reader.next(), "")
        XCTAssertEqual(try reader.next(), "päss word")
        XCTAssertEqual(try reader.next(), "last")
        XCTAssertNil(try reader.next())
    }
    func testWordlistRejectsInvalidUTF8() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data([255, 10]).write(to: path)
        let reader = try WordlistReader(url: path)
        XCTAssertThrowsError(try reader.next())
    }
    func testProcessArgumentsPreserveExactUTF8AndShellMetacharacters() async throws {
        let value = "päss🔑 e\u{301} `echo unsafe` $(echo unsafe) ' \" \n\n"
        let result = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", value])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(Array(result.stdout.utf8), Array(value.utf8))
    }

}
