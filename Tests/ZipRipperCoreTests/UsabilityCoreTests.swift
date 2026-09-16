import XCTest
@testable import ZipRipperCore

final class UsabilityCoreTests: XCTestCase {
    func testCPUAndGeneratorNeverPreloadWordlist() throws {
        let config = RecoveryConfiguration(archivePath: "/tmp/a.zip")
        XCTAssertTrue(try JohnEngine.arguments(configuration: config, directory: URL(fileURLWithPath: "/tmp")).contains("--save-memory=3"))
        XCTAssertTrue(try JohnEngine.candidateArguments(configuration: config, directory: URL(fileURLWithPath: "/tmp")).contains("--save-memory=3"))
    }
    func testRejectsBinaryAndOversizedFinalLine() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        for bytes in [Data([0, 1, 10]), Data(repeating: 65, count: 1024 * 1024 + 1)] {
            try bytes.write(to: path)
            XCTAssertThrowsError(try WordlistReader(url: path).next())
        }
    }
    func testStreamingStagePreservesBytesAndCleansPartialOnFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"), target = root.appendingPathComponent("staged.txt")
        let bytes = Data((String(repeating: "päss word\r\n", count: 12000) + "final").utf8)
        try bytes.write(to: source)
        XCTAssertEqual(try WordlistReader.inspect(url: source).byteCount, Int64(bytes.count))
        var copied: Int64 = 0
        XCTAssertThrowsError(try WordlistReader.stage(source: source, destination: target, isCancelled: { copied >= 65536 }, progress: { copied = $0; _ = $1 })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.txt"])
        try WordlistReader.stage(source: source, destination: target)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertThrowsError(try WordlistReader.stage(source: source, destination: target))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
    func testInspectionRejectsCompressedAndDirectoryAndLateInvalidUTF8() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try WordlistReader.inspect(url: root))
        let source = root.appendingPathComponent("source.txt"), target = root.appendingPathComponent("staged.txt")
        try Data([0x1f, 0x8b, 8, 0]).write(to: source)
        XCTAssertThrowsError(try WordlistReader.inspect(url: source)) { XCTAssertTrue($0.localizedDescription.contains("compressed")) }
        var bytes = Data(String(repeating: "valid\n", count: 20000).utf8); bytes.append(255)
        try bytes.write(to: source)
        XCTAssertNoThrow(try WordlistReader.inspect(url: source))
        XCTAssertThrowsError(try WordlistReader.stage(source: source, destination: target)) { XCTAssertTrue($0.localizedDescription.contains("UTF-8")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testBenchmarkRateAndSampleCoverage() throws {
        XCTAssertEqual(RecoveryBenchmark.measuredRate("0g/s 2.35Mp/s 2Mc/s 2MC/s sample"), 2_350_000)
        XCTAssertEqual(RecoveryBenchmark.measuredRate("0g/s 10p/s 10c/s\n0g/s 15.5Kp/s 1c/s"), 15_500)
        XCTAssertNil(RecoveryBenchmark.measuredRate("No measurement available"))
        let vectors = try RecoveryBenchmark.vectors()
        XCTAssertEqual(vectors.count, 10)
        XCTAssertEqual(Set(vectors.map(\.id)).count, 10)
        let gpu = try MetalArchiveFilter()
        for vector in vectors {
            XCTAssertEqual(MetalArchiveFilter.supports(hashLine: vector.hashLine), vector.metal, vector.id)
            if vector.metal {
                XCTAssertEqual(try gpu.filter(candidates: ["incorrect-demo", vector.password], hashLine: vector.hashLine), [vector.password], vector.id)
            }
        }
    }
    func testBenchmarkCanCancelBeforeItStarts() async throws {
        let bench = RecoveryBenchmark(runtime: URL(fileURLWithPath: "/not-needed"))
        bench.cancel()
        do { _ = try await bench.run(update: { _ in XCTFail("Cancelled run must not publish measurements") }); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testWordlistMatchesJohnBOMAndFinalCRHandling() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("\u{FEFF}first\r\n\u{FEFF}second\r".utf8).write(to: path)
        let reader = try WordlistReader(url: path)
        XCTAssertEqual(try reader.next(), "first")
        XCTAssertEqual(try reader.next(), "second")
        XCTAssertNil(try reader.next())
    }

    func testStatusCandidateRemainsTransientAndWaitsForWholeLine() {
        let box = CandidateTestBox()
        let sink = JohnLogSink(emit: { box.logs += $0 }, candidate: { box.candidate = $0 })
        sink.accept("0g 0:00:01 0g/s 1p/s 1c/s 1C/s secret")
        XCTAssertNil(box.candidate)
        sink.accept(" with spaces..last\n")
        XCTAssertEqual(box.candidate, "Samples: secret with spaces..last")
        XCTAssertFalse(box.logs.contains("secret"))
        XCTAssertTrue(box.logs.contains("[candidates hidden]"))
    }

    func testFixedMaskShowsOneCandidateWithoutSplittingLiteralDots() throws {
        let box = CandidateTestBox()
        let pattern = try PasswordPattern(mask: "?uinary?uears666???a?l?l?l?l")
        XCTAssertEqual(pattern.length, 20)
        let sink = JohnLogSink(emit: { box.logs += $0 }, candidate: { box.candidate = $0 }, candidateLength: pattern.length)
        sink.accept("1 0g 0:00:00:18 0g/s 23.9p/s 23.9c/s 23.9C/s LinaryNears666?Gbbbi..DinaryNears666?Gbbbi\n")
        XCTAssertEqual(box.candidate, "Sample: LinaryNears666?Gbbbi")
        XCTAssertFalse(box.logs.contains("Gbbbi"))
        let dotted = JohnLogSink(emit: { _ in }, candidate: { box.candidate = $0 }, candidateLength: 4)
        dotted.accept("0g 0:00:00:01 0g/s 1p/s 1c/s 1C/s a..b..c..d\n")
        XCTAssertEqual(box.candidate, "Sample: a..b")
        dotted.accept("0g 0:00:00:01 0g/s 1p/s 1c/s 1C/s a..b\n")
        XCTAssertEqual(box.candidate, "Sample: a..b")
    }

}

private final class CandidateTestBox: @unchecked Sendable {
    var logs = ""
    var candidate: String?
}
