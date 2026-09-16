import XCTest
@testable import ZipRipperCore

final class CalibrationIntegrationTests: XCTestCase {
    private func root() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["ZIPRIPPER_INTEGRATION_ROOT"] else { throw XCTSkip("Local runtime required") }
        return URL(fileURLWithPath: path)
    }
    func testAutomaticSelectsMeasuredBackendAndResumesSameSearch() async throws {
        let root = try root(), fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        let store = try JobStore(root: temp)
        let words = temp.appendingPathComponent("input.txt")
        // Read the fixture's exact password; no assumption about fixture naming.
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("test-files/manifest.json"))) as! [[String: Any]]
        let row = try XCTUnwrap(rows.first { ($0["format"] as? String) == "7z" })
        let password = row["password"] as! String
        try Data((String(repeating: "wrong\n", count: 1200) + password + "\n").utf8).write(to: words)
        var config = RecoveryConfiguration(archivePath: root.appendingPathComponent("test-files/" + (row["file"] as! String)).path)
        config.strategy = .wordlist; config.wordlistPath = words.path; config.useRules = false; config.workers = 1
        let first = JohnEngine(runtime: root.appendingPathComponent(".local/runtime"), store: store)
        let paused = try await first.run(job: store.create(configuration: config), update: { job in
            if job.phase == .running { first.pause() }
        }, log: { _ in })
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertNotNil(paused.resolvedBackend)
        XCTAssertNotNil(paused.measuredRate)
        XCTAssertEqual(paused.candidateCount, 1201)
        let second = JohnEngine(runtime: root.appendingPathComponent(".local/runtime"), store: store)
        let done = try await second.run(job: paused, update: { _ in }, log: { message in
            XCTAssertFalse(message.contains("File calibration:"), "Resume must retain the resolved engine")
        })
        XCTAssertEqual(done.resolvedBackend, paused.resolvedBackend)
        XCTAssertEqual(done.phase, .recovered)
        XCTAssertEqual(second.passwords(for: done), [password])
    }
    func testTinyAutomaticSearchAvoidsCalibrationOverhead() async throws {
        let root = try root(), fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        let store = try JobStore(root: temp)
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("test-files/manifest.json"))) as! [[String: Any]]
        let row = try XCTUnwrap(rows.first { ($0["file"] as? String)?.hasSuffix(".zip") == true })
        let password = row["password"] as! String
        let words = temp.appendingPathComponent("words.txt")
        try Data((password + "\n").utf8).write(to: words)
        var config = RecoveryConfiguration(archivePath: root.appendingPathComponent("test-files/" + (row["file"] as! String)).path)
        config.strategy = .wordlist; config.wordlistPath = words.path; config.useRules = false; config.workers = 1
        let engine = JohnEngine(runtime: root.appendingPathComponent(".local/runtime"), store: store)
        let done = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { XCTAssertFalse($0.contains("File calibration:")) })
        XCTAssertEqual(done.resolvedBackend, .cpu)
        XCTAssertEqual(done.phase, .recovered)
        XCTAssertEqual(engine.passwords(for: done), [password])
    }
    func testCancelFileCalibrationRemovesTemporaryWork() async throws {
        let root = try root()
        let vector = try XCTUnwrap(RecoveryBenchmark.vectors().first { $0.format == "7z" })
        let probe = RecoveryBenchmark(runtime: root.appendingPathComponent(".local/runtime"))
        let gpu = try MetalArchiveFilter()
        let task = Task { try await probe.calibrate(lines: [vector.hashLine], candidates: ["wrong"], gpu: gpu) }
        try await Task.sleep(nanoseconds: 100_000_000)
        probe.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testGroupedDispatchMatchesBaselineAndMeasures7z() throws {
        _ = try root()
        let vector = try XCTUnwrap(RecoveryBenchmark.vectors().first { $0.format == "7z" })
        var words = (0..<1024).map { "zrbench" + String(format: "%010d", $0) }
        words[700] = vector.password
        for dispatches in [1, 4, 4, 1] {
            let gpu = try MetalArchiveFilter(batchSize: 1024, dispatchesPerCommand: dispatches)
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(try gpu.filter(candidates: words, hashLine: vector.hashLine), [vector.password])
            print("DISPATCHES \(dispatches): \(1024 / (ProcessInfo.processInfo.systemUptime - start)) p/s")
        }
    }
    func testCachedPipelineInitializationAndSurvivors() throws {
        _ = try root()
        let vector = try XCTUnwrap(RecoveryBenchmark.vectors().first { $0.format == "7z" })
        let start = ProcessInfo.processInfo.systemUptime
        let first = try MetalArchiveFilter()
        let cold = ProcessInfo.processInfo.systemUptime - start
        let warmStart = ProcessInfo.processInfo.systemUptime
        let second = try MetalArchiveFilter()
        let warm = ProcessInfo.processInfo.systemUptime - warmStart
        XCTAssertEqual(try first.filter(candidates: ["wrong", vector.password], hashLine: vector.hashLine), [vector.password])
        XCTAssertEqual(try second.filter(candidates: ["wrong", vector.password], hashLine: vector.hashLine), [vector.password])
        print("PIPELINE initialization first=\(cold)s cached=\(warm)s")
    }
}
