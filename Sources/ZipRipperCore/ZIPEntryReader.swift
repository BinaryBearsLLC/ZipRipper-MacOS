import Foundation

/// Reads encrypted member names by seeking the ZIP central directory. File data
/// is never decompressed or loaded, including for single-volume ZIP64 archives.
public enum ZIPEntryReader {
    public enum ReaderError: LocalizedError {
        case malformed, multipart, limits, filename, duplicateName, unsupportedDirectory
        public var errorDescription: String? {
            switch self {
            case .malformed: return "The ZIP central directory is missing, truncated, or inconsistent. Select a complete, valid ZIP archive."
            case .multipart: return "Split or multi-volume ZIP archives are not supported. Combine the archive volumes into a single ZIP first."
            case .limits: return "This ZIP exceeds the supported directory limits (100,000 entries or 16 MiB of filenames)."
            case .filename: return "An encrypted ZIP member has a filename that cannot be passed safely to the recovery engine. Use an archive with UTF-8 or ASCII member names, without NUL or line-break characters."
            case .duplicateName: return "This ZIP contains duplicate encrypted member names. Separate or rename those members before attempting recovery."
            case .unsupportedDirectory: return "The ZIP central directory uses an unsupported structure or encryption. Use a ZIP with a readable standard central directory."
            }
        }
    }

    public static func encryptedEntryNames(at url: URL) throws -> [String] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 22 else { throw ReaderError.malformed }
        let tailSize = Int(min(size, 65_535 + 22))
        let tailOffset = size - UInt64(tailSize)
        let tail = try read(file, at: tailOffset, count: tailSize, size: size)
        var eocdIndex: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if number(tail, index, 4) == 0x06054b50,
               index + 22 + Int(number(tail, index + 20, 2)) == tail.count {
                eocdIndex = index
                break
            }
        }
        guard let eocdIndex else { throw ReaderError.malformed }
        let eocd = tail.subdata(in: eocdIndex..<(eocdIndex + 22))
        let eocdOffset = tailOffset + UInt64(eocdIndex)
        guard number(eocd, 4, 2) == 0, number(eocd, 6, 2) == 0 else { throw ReaderError.multipart }
        var count = number(eocd, 10, 2)
        var directorySize = number(eocd, 12, 4)
        var directoryOffset = number(eocd, 16, 4)
        var directoryLimit = eocdOffset
        let needsZIP64 = count == 0xffff || number(eocd, 8, 2) == 0xffff || directorySize == 0xffffffff || directoryOffset == 0xffffffff
        if needsZIP64 {
            guard eocdOffset >= 20 else { throw ReaderError.malformed }
            let locator = try read(file, at: eocdOffset - 20, count: 20, size: size)
            guard number(locator, 0, 4) == 0x07064b50 else { throw ReaderError.malformed }
            guard number(locator, 4, 4) == 0, number(locator, 16, 4) == 1 else { throw ReaderError.multipart }
            let zip64Offset = number(locator, 8, 8)
            guard zip64Offset <= eocdOffset - 20, eocdOffset - 20 - zip64Offset >= 56 else { throw ReaderError.malformed }
            let zip64 = try read(file, at: zip64Offset, count: 56, size: size)
            let recordSize = number(zip64, 4, 8)
            guard number(zip64, 0, 4) == 0x06064b50, recordSize >= 44,
                  recordSize == eocdOffset - 20 - zip64Offset - 12 else { throw ReaderError.malformed }
            guard number(zip64, 16, 4) == 0, number(zip64, 20, 4) == 0,
                  number(zip64, 24, 8) == number(zip64, 32, 8) else { throw ReaderError.multipart }
            count = number(zip64, 32, 8)
            directorySize = number(zip64, 40, 8)
            directoryOffset = number(zip64, 48, 8)
            directoryLimit = zip64Offset
        } else if number(eocd, 8, 2) != count {
            throw ReaderError.multipart
        }
        guard count <= 100_000 else { throw ReaderError.limits }
        guard directoryOffset <= directoryLimit, directorySize <= directoryLimit - directoryOffset,
              count <= directorySize / 46 else { throw ReaderError.malformed }
        let directoryEnd = directoryOffset + directorySize
        var cursor = directoryOffset
        var nameBytes = 0
        var names: [String] = []
        var seen: Set<String> = []
        for _ in 0..<Int(count) {
            guard cursor <= directoryEnd, directoryEnd - cursor >= 46 else { throw ReaderError.malformed }
            let header = try read(file, at: cursor, count: 46, size: size)
            guard number(header, 0, 4) == 0x02014b50 else { throw ReaderError.unsupportedDirectory }
            let length = Int(number(header, 28, 2))
            let extraLength = Int(number(header, 30, 2))
            let commentLength = Int(number(header, 32, 2))
            let recordLength = 46 + length + extraLength + commentLength
            guard UInt64(recordLength) <= directoryEnd - cursor else { throw ReaderError.malformed }
            nameBytes += length
            guard nameBytes <= 16 * 1024 * 1024 else { throw ReaderError.limits }
            let disk = number(header, 34, 2)
            if disk == 0xffff {
                let extra = try read(file, at: cursor + UInt64(46 + length), count: extraLength, size: size)
                try checkZIP64Disk(header: header, extra: extra)
            } else if disk != 0 {
                throw ReaderError.multipart
            }
            let flags = number(header, 8, 2)
            if flags & 1 != 0 {
                let bytes = try read(file, at: cursor + 46, count: length, size: size)
                guard !bytes.isEmpty, !bytes.contains(0), !bytes.contains(10), !bytes.contains(13),
                      flags & 0x800 != 0 || bytes.allSatisfy({ $0 < 128 }),
                      let name = String(data: bytes, encoding: .utf8) else { throw ReaderError.filename }
                guard seen.insert(name).inserted else { throw ReaderError.duplicateName }
                names.append(name)
            }
            cursor += UInt64(recordLength)
        }
        // An optional central-directory digital signature may follow the entries.
        if cursor != directoryEnd {
            guard directoryEnd - cursor >= 6 else { throw ReaderError.malformed }
            let signature = try read(file, at: cursor, count: 6, size: size)
            guard number(signature, 0, 4) == 0x05054b50,
                  number(signature, 4, 2) + 6 == directoryEnd - cursor else { throw ReaderError.unsupportedDirectory }
        }
        return names
    }

    private static func checkZIP64Disk(header: Data, extra: Data) throws {
        var index = 0
        while index + 4 <= extra.count {
            let fieldID = number(extra, index, 2)
            let length = Int(number(extra, index + 2, 2))
            guard length <= extra.count - index - 4 else { throw ReaderError.malformed }
            if fieldID == 1 {
                var diskOffset = index + 4
                if number(header, 24, 4) == 0xffffffff { diskOffset += 8 }
                if number(header, 20, 4) == 0xffffffff { diskOffset += 8 }
                if number(header, 42, 4) == 0xffffffff { diskOffset += 8 }
                guard diskOffset + 4 <= index + 4 + length else { throw ReaderError.malformed }
                guard number(extra, diskOffset, 4) == 0 else { throw ReaderError.multipart }
                return
            }
            index += 4 + length
        }
        throw ReaderError.malformed
    }

    private static func read(_ file: FileHandle, at offset: UInt64, count: Int, size: UInt64) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw ReaderError.malformed }
        try file.seek(toOffset: offset)
        var data = Data()
        while data.count < count {
            guard let part = try file.read(upToCount: count - data.count), !part.isEmpty else { throw ReaderError.malformed }
            data.append(part)
        }
        return data
    }

    private static func number(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count { value |= UInt64(data[offset + index]) << (index * 8) }
        return value
    }
}
