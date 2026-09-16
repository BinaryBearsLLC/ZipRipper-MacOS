import Foundation
import CryptoKit

public final class JobStore {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    public func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func create(configuration: RecoveryConfiguration) throws -> RecoveryJob {
        let job = RecoveryJob(configuration: configuration)
        try FileManager.default.createDirectory(at: directory(for: job.id), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try save(job); return job
    }
    public func save(_ job: RecoveryJob) throws {
        let data = try JSONEncoder().encode(job)
        let path = directory(for: job.id).appendingPathComponent("job.json")
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    public func load() throws -> [RecoveryJob] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
            return try? JSONDecoder().decode(RecoveryJob.self, from: Data(contentsOf: directory.appendingPathComponent("job.json")))
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func delete(_ job: RecoveryJob) throws { try FileManager.default.removeItem(at: directory(for: job.id)) }
    public static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty else { return false }
            hasher.update(data: block)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
