import XCTest
@testable import ZipRipperCore

final class ZIPEntryTests: XCTestCase {
    private func le(_ value: UInt64, _ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    // Minimal directory-only fixtures exercise parsing independently of ZIP tools.
    private func archive(_ entries: [(Data, UInt16)], zip64: Bool = false, disk: UInt16 = 0) -> Data {
        var central = Data()
        for (name, flags) in entries {
            var header = Data(repeating: 0, count: 46)
            header.replaceSubrange(0..<4, with: le(0x02014b50, 4))
            header.replaceSubrange(8..<10, with: le(UInt64(flags), 2))
            header.replaceSubrange(28..<30, with: le(UInt64(name.count), 2))
            central.append(header); central.append(name)
        }
        var result = central
        if zip64 {
            result.append(le(0x06064b50, 4)); result.append(le(44, 8))
            result.append(le(45, 2)); result.append(le(45, 2))
            result.append(le(0, 4)); result.append(le(0, 4))
            result.append(le(UInt64(entries.count), 8)); result.append(le(UInt64(entries.count), 8))
            result.append(le(UInt64(central.count), 8)); result.append(le(0, 8))
            result.append(le(0x07064b50, 4)); result.append(le(0, 4))
            result.append(le(UInt64(central.count), 8)); result.append(le(1, 4))
        }
        result.append(le(0x06054b50, 4)); result.append(le(UInt64(disk), 2)); result.append(le(0, 2))
        result.append(le(zip64 ? 65535 : UInt64(entries.count), 2))
        result.append(le(zip64 ? 65535 : UInt64(entries.count), 2))
        result.append(le(zip64 ? 0xffffffff : UInt64(central.count), 4))
        result.append(le(zip64 ? 0xffffffff : 0, 4)); result.append(le(0, 2))
        return result
    }
    private func read(_ data: Data) throws -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return try ZIPEntryReader.encryptedEntryNames(at: url)
    }
    func testSelectsEncryptedNamesAndPreservesUTF8() throws {
        let data = archive([(Data("plain.txt".utf8), 0), (Data("first.txt".utf8), 1), (Data("cartella/🔑.txt".utf8), 0x801)])
        XCTAssertEqual(try read(data), ["first.txt", "cartella/🔑.txt"])
        XCTAssertEqual(try read(archive([])), [])
    }
    func testReadsSingleVolumeZIP64Directory() throws {
        XCTAssertEqual(try read(archive([(Data("large.txt".utf8), 1)], zip64: true)), ["large.txt"])
    }
    func testSeeksZIP64DirectoryBeyondFourGiB() throws {
        let name = Data("large.txt".utf8)
        var data = archive([(name, 1)], zip64: true)
        let centralSize = 46 + name.count
        let base: UInt64 = 0x1_0000_0100
        data.replaceSubrange((centralSize + 48)..<(centralSize + 56), with: le(base, 8))
        data.replaceSubrange((centralSize + 64)..<(centralSize + 72), with: le(base + UInt64(centralSize), 8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: base) // Sparse temporary file, no 4 GiB allocation.
        try handle.write(contentsOf: data)
        try handle.close()
        XCTAssertEqual(try ZIPEntryReader.encryptedEntryNames(at: url), ["large.txt"])
    }
    func testZIP64BoundsAndMultipartLocator() throws {
        let name = Data("large.txt".utf8)
        let centralSize = 46 + name.count
        let valid = archive([(name, 1)], zip64: true)
        var multipart = valid
        multipart.replaceSubrange((centralSize + 72)..<(centralSize + 76), with: le(2, 4))
        XCTAssertThrowsError(try read(multipart))
        var overflow = valid
        overflow.replaceSubrange((centralSize + 64)..<(centralSize + 72), with: le(UInt64.max, 8))
        XCTAssertThrowsError(try read(overflow))
        var count = valid
        count.replaceSubrange((centralSize + 24)..<(centralSize + 40), with: le(100_001, 8) + le(100_001, 8))
        XCTAssertThrowsError(try read(count))
    }
    func testRejectsMultipartAndMalformedArchives() throws {
        let valid = archive([(Data("secret.txt".utf8), 1)])
        XCTAssertThrowsError(try read(Data()))
        XCTAssertThrowsError(try read(valid.dropLast()))
        XCTAssertThrowsError(try read(archive([(Data("secret.txt".utf8), 1)], disk: 1)))
        var badSize = valid
        badSize.replaceSubrange((badSize.count - 10)..<(badSize.count - 6), with: le(0x7fffffff, 4))
        XCTAssertThrowsError(try read(badSize))
        var badSignature = valid; badSignature[0] = 0
        XCTAssertThrowsError(try read(badSignature))
    }
    func testRejectsUndecodableAndAmbiguousNames() throws {
        XCTAssertThrowsError(try read(archive([(Data([0xff, 0xfe]), 0x801)])))
        XCTAssertThrowsError(try read(archive([(Data([0xe9]), 1)])))
        XCTAssertThrowsError(try read(archive([(Data("bad\0name".utf8), 1)])))
        XCTAssertThrowsError(try read(archive([(Data("same".utf8), 1), (Data("same".utf8), 1)])))
    }
    func testRealMixedPasswordAndAESArchives() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let mixed = root.appendingPathComponent(".local/fixtures/mixed-passwords.zip")
        let aes = root.appendingPathComponent(".local/fixtures/zip-aes256.zip")
        guard FileManager.default.fileExists(atPath: mixed.path), FileManager.default.fileExists(atPath: aes.path) else {
            throw XCTSkip("Local runtime validation archives are not present.")
        }
        XCTAssertEqual(try ZIPEntryReader.encryptedEntryNames(at: mixed), ["first.txt", "second.txt"])
        XCTAssertEqual(try ZIPEntryReader.encryptedEntryNames(at: aes), ["message.txt"])
    }
}
