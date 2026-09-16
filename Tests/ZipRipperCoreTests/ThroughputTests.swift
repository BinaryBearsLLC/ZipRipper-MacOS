import XCTest
@testable import ZipRipperCore

final class ThroughputTests: XCTestCase {
    func testMulticoreRateUsesLatestPerWorkerWithoutDuplicates() {
        let lines = "1 0g 0:00:00:01 0g/s 10p/s 10c/s\n2 0g 0:00:00:01 0g/s 12p/s 12c/s\n1 0g 0:00:00:02 0g/s 15p/s 15c/s\n1 0g 0:00:00:02 0g/s 15p/s 15c/s"
        XCTAssertEqual(RecoveryBenchmark.aggregateRate(lines, workers: 2), 27)
        XCTAssertNil(RecoveryBenchmark.aggregateRate(lines, workers: 3))
    }
    func testMetalBatchSizesPreserveSurvivorsAndMeasure7z() throws {
        guard ProcessInfo.processInfo.environment["ZIPRIPPER_INTEGRATION_ROOT"] != nil else { throw XCTSkip("Local Metal timing probe") }
        let vector = try XCTUnwrap(RecoveryBenchmark.vectors().first { $0.format == "7z" })
        var words = (0..<1025).map { "zrbench" + String(format: "%010d", $0) }
        words[512] = vector.password
        for size in [128, 1024] {
            let filter = try MetalArchiveFilter(batchSize: size)
            let start = Date()
            XCTAssertEqual(try filter.filter(candidates: words, hashLine: vector.hashLine), [vector.password])
            print("7Z BATCH \(size): \(Double(words.count) / Date().timeIntervalSince(start)) p/s")
        }
    }
}
