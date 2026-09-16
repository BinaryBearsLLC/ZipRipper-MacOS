import XCTest
@testable import ZipRipperCore

final class UsabilityIntegrationTests: XCTestCase {
    private func root() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["ZIPRIPPER_INTEGRATION_ROOT"] else { throw XCTSkip("Set ZIPRIPPER_INTEGRATION_ROOT to the repository for local demo/benchmark tests") }
        return URL(fileURLWithPath: path)
    }
    func testRealBenchmarkAndCancellation() async throws {
        let root = try root()
        let benchmark = RecoveryBenchmark(runtime: root.appendingPathComponent(".local/runtime"))
        let results = try await benchmark.run(update: { row in
            if let rate = row.passwordsPerSecond { print("BENCHMARK \(row.name) · \(row.backend): \(rate) p/s · \(row.detail)") }
        })
        XCTAssertEqual(results.count, 30)
        XCTAssertEqual(results.filter { $0.passwordsPerSecond != nil }.count, 29, results.map { "\($0.id): \($0.detail)" }.joined(separator: "\n"))
        let cancel = RecoveryBenchmark(runtime: root.appendingPathComponent(".local/runtime"))
        let started = Date()
        do {
            _ = try await cancel.run(update: { row in
                if row.detail == "Measuring…" { cancel.cancel() }
            })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
    func testAllDemoPasswordsCPUAndMetal() async throws {
        let root = try root(), fm = FileManager.default
        let runtime = root.appendingPathComponent(".local/runtime"), fixtures = root.appendingPathComponent("test-files")
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("manifest.json"))) as! [[String: Any]]
        let words = try String(contentsOf: fixtures.appendingPathComponent("wordlist-2000.txt"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(words.count, 2000)
        XCTAssertEqual(Set(rows.map { $0["password"] as! String }).count, rows.count)
        for row in rows {
            let filename = row["file"] as! String, password = row["password"] as! String
            XCTAssertEqual(String(words[(row["wordlistLine"] as! Int) - 1]), password)
            for backend in [ComputeBackend.cpu, .metal] {
                let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? fm.removeItem(at: work) }
                let store = try JobStore(root: work)
                var config = RecoveryConfiguration(archivePath: fixtures.appendingPathComponent(filename).path)
                config.strategy = .wordlist; config.wordlistPath = fixtures.appendingPathComponent("wordlist-2000.txt").path
                config.backend = backend; config.useRules = false; config.workers = 1
                let engine = JohnEngine(runtime: runtime, store: store)
                let box = TransientSampleBox()
                let job = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { message in
                    XCTAssertFalse(message.contains(password), "Password leaked into public log for \(filename)")
                }, currentCandidate: { box.set($0) })
                XCTAssertEqual(job.phase, .recovered, filename)
                XCTAssertEqual(engine.passwords(for: job), [password], filename)
                if backend == .metal {
                    XCTAssertEqual(job.engine.hasPrefix("Metal"), filename != "pdf-r6.pdf", filename)
                    XCTAssertTrue(box.hadSample, filename)
                }
                XCTAssertNil(box.current, "Transient candidate must clear on exit")
                let metadata = try String(contentsOf: store.directory(for: job.id).appendingPathComponent("job.json"), encoding: .utf8)
                XCTAssertFalse(metadata.contains(password))
                print("DEMO verified \(filename) · \(job.engine)")
            }
        }
    }
    func testOneGiBWordlistStagingAndCancellation() throws {
        guard ProcessInfo.processInfo.environment["ZIPRIPPER_WORDLIST_STRESS"] == "1" else { throw XCTSkip("Opt-in 1 GiB local disk stress") }
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("gigabyte.txt"), target = root.appendingPathComponent("staged.txt")
        fm.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        let chunk = Data(String(repeating: "word123\n", count: 65536).utf8)
        for _ in 0..<2048 { try handle.write(contentsOf: chunk) }
        try handle.close()
        XCTAssertEqual(try WordlistReader.inspect(url: source).byteCount, 1_073_741_824)
        var copied: Int64 = 0
        let cancelledStart = Date()
        XCTAssertThrowsError(try WordlistReader.stage(source: source, destination: target, isCancelled: { copied >= 8 * 1024 * 1024 }, progress: { copied = $0; _ = $1 })) { XCTAssertTrue($0 is CancellationError) }
        print("WORDLIST cancelled after \(copied) bytes in \(Date().timeIntervalSince(cancelledStart)) seconds")
        XCTAssertFalse(fm.fileExists(atPath: target.path))
        let started = Date()
        let result = try WordlistReader.stage(source: source, destination: target)
        XCTAssertEqual(result.byteCount, 1_073_741_824)
        XCTAssertEqual(try JobStore.digest(of: source), try JobStore.digest(of: target))
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("WORDLIST process peak RSS: \(usage.ru_maxrss) bytes")
        XCTAssertLessThan(usage.ru_maxrss, 256 * 1024 * 1024, "Streaming work must not retain file-sized autoreleased NSData buffers")
        print("WORDLIST validated/staged 1 GiB in \(Date().timeIntervalSince(started)) seconds")
    }
}
private final class TransientSampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var current: String?
    private(set) var hadSample = false
    func set(_ value: String?) { lock.lock(); defer { lock.unlock() }; current = value; hadSample = hadSample || value != nil }
}
