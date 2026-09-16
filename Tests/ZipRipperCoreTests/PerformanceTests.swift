import XCTest
@testable import ZipRipperCore

final class PerformanceTests: XCTestCase {
    func testCountAndThrottleDoNotEnumerateSearch() {
        var config = RecoveryConfiguration(archivePath: "a.7z")
        config.strategy = .mask; config.mask = "Summer?d?d??"
        XCTAssertEqual(SearchEstimate.candidateCount(config, wordCount: nil), 100)
        config.mask = "?uinary?uears666???a?l?l?l?l"
        XCTAssertEqual(SearchEstimate.candidateCount(config, wordCount: nil), 29_346_998_720)
        XCTAssertEqual(SearchEstimate.text(seconds: 29_346_998_720 / 239), "~4 years")
        config.mask = "[ab]?d"
        XCTAssertNil(SearchEstimate.candidateCount(config, wordCount: nil))
        config.strategy = .exhaustive; config.minimumLength = 1; config.maximumLength = 20
        XCTAssertEqual(SearchEstimate.candidateCount(config, wordCount: nil)!, 111111111111111111110.0, accuracy: 100000)
        config.strategy = .wordlist
        XCTAssertNil(SearchEstimate.candidateCount(config, wordCount: 2000))
        config.useRules = false
        XCTAssertEqual(SearchEstimate.candidateCount(config, wordCount: 2000), 2000)
        var estimate = SearchEstimate()
        XCTAssertTrue(estimate.shouldUpdate(at: 0))
        for n in 1...99 { XCTAssertFalse(estimate.shouldUpdate(at: Double(n) / 10)) }
        XCTAssertTrue(estimate.shouldUpdate(at: 10))
        XCTAssertEqual(SearchEstimate.remaining(total: 2000, completed: 500, rate: 100), 15)
        XCTAssertNil(SearchEstimate.remaining(total: 2000, completed: 0, rate: 0))
    }
    func testCPUProgressUsesEachWorkerOnce() {
        let log = "1 0g 0:00:00:01 20.0% 0g/s 10p/s\n2 0g 0:00:00:01 40.0% 0g/s 12p/s\n1 0g 0:00:00:02 60.0% 0g/s 10p/s"
        XCTAssertEqual(RecoveryBenchmark.progressFraction(log, workers: 2), 0.5)
        XCTAssertNil(RecoveryBenchmark.progressFraction(log, workers: 3))
    }
    func testProfilePersistenceAndInvalidation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let profile = PerformanceProfile(identity: "one", results: [BenchmarkResult(id: "7z", name: "7z", backend: "CPU", passwordsPerSecond: 123, detail: "Measured")])
        try profile.save(to: url)
        XCTAssertEqual(PerformanceProfile.load(from: url, identity: "one")?.results.first?.passwordsPerSecond, 123)
        XCTAssertNil(PerformanceProfile.load(from: url, identity: "two"))
    }
    func testStagingCountsDuringExistingPass() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input")
        try Data("one\r\n\n#!comment: ignored\n\u{feff}#!comment: ignored too\nlast".utf8).write(to: source)
        let inspected = try WordlistReader.stage(source: source, destination: root.appendingPathComponent("output"))
        XCTAssertEqual(inspected.candidateCount, 3)
    }
}
