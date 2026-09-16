import XCTest
@testable import ZipRipperCore

final class IntegrationTests: XCTestCase {
    func testExhaustiveDigitsAndRecommendedRules() async throws {
        let (runtime, fixtures) = try paths()
        for (name, strategy, password) in [("zip-digits.zip", RecoveryStrategy.exhaustive, "17"), ("rar5-p0-password.rar", RecoveryStrategy.recommended, "password")] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try JobStore(root: root)
            var config = RecoveryConfiguration(archivePath: fixtures.appendingPathComponent(name).path)
            config.strategy = strategy; config.workers = 1; config.minimumLength = 2; config.maximumLength = 2; config.backend = .cpu
            let engine = JohnEngine(runtime: runtime, store: store)
            let result = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { _ in })
            XCTAssertEqual(result.phase, .recovered)
            XCTAssertEqual(engine.passwords(for: result), [password])
        }
    }
    func testPartialRecoveryIsExplicit() async throws {
        let (runtime, fixtures) = try paths()
        let preferred = fixtures.appendingPathComponent("mixed-passwords.zip")
        let archive = FileManager.default.fileExists(atPath: preferred.path) ? preferred : fixtures.deletingLastPathComponent().appendingPathComponent("review-probes/mixed-passwords.zip")
        guard FileManager.default.fileExists(atPath: archive.path) else { throw XCTSkip("Mixed password fixture missing") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(root: root)
        let words = root.appendingPathComponent("one.txt"); try "AlphaSecret42\n".write(to: words, atomically: true, encoding: .utf8)
        var config = RecoveryConfiguration(archivePath: archive.path)
        config.strategy = .wordlist; config.wordlistPath = words.path; config.useRules = false; config.workers = 1
        let engine = JohnEngine(runtime: runtime, store: store)
        let result = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { _ in })
        XCTAssertEqual(result.phase, .partial)
        XCTAssertEqual(engine.passwords(for: result), ["AlphaSecret42"])
    }
    func testHashMarkerFilenameAndExactPattern() async throws {
        let (runtime, fixtures) = try paths()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(root: root)
        let archive = root.appendingPathComponent("$pkzip$.zip")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("zip-aes256.zip"), to: archive)
        var config = RecoveryConfiguration(archivePath: archive.path)
        config.strategy = .mask; config.mask = "ZipRipper42!"; config.workers = 1
        let engine = JohnEngine(runtime: runtime, store: store)
        let result = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { _ in })
        XCTAssertEqual(result.phase, .recovered)
        XCTAssertEqual(engine.passwords(for: result), ["ZipRipper42!"])
    }
    func testMixedPasswordZIP() async throws {
        let (runtime, fixtures) = try paths()
        let preferred = fixtures.appendingPathComponent("mixed-passwords.zip")
        let archive = FileManager.default.fileExists(atPath: preferred.path) ? preferred : fixtures.deletingLastPathComponent().appendingPathComponent("review-probes/mixed-passwords.zip")
        guard FileManager.default.fileExists(atPath: archive.path) else { throw XCTSkip("Mixed password fixture missing") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(root: root)
        var config = RecoveryConfiguration(archivePath: archive.path)
        config.strategy = .wordlist; config.backend = .cpu; config.useRules = false; config.workers = 2
        config.wordlistPath = archive.deletingLastPathComponent().appendingPathComponent("mixed-words.txt").path
        let engine = JohnEngine(runtime: runtime, store: store)
        let result = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { text in
            XCTAssertFalse(text.contains("AlphaSecret42")); XCTAssertFalse(text.contains("BetaSecret73"))
        })
        XCTAssertEqual(result.phase, .recovered)
        XCTAssertEqual(Set(engine.passwords(for: result)), Set(["AlphaSecret42", "BetaSecret73"]))
    }
    func testMetalMixedPasswordZIP() async throws {
        let (runtime, fixtures) = try paths()
        let preferred = fixtures.appendingPathComponent("mixed-passwords.zip")
        let archive = FileManager.default.fileExists(atPath: preferred.path) ? preferred : fixtures.deletingLastPathComponent().appendingPathComponent("review-probes/mixed-passwords.zip")
        guard FileManager.default.fileExists(atPath: archive.path) else { throw XCTSkip("Mixed password fixture missing") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(root: root)
        var config = RecoveryConfiguration(archivePath: archive.path)
        config.strategy = .wordlist; config.backend = .metal; config.useRules = false; config.workers = 2
        config.wordlistPath = archive.deletingLastPathComponent().appendingPathComponent("mixed-words.txt").path
        let engine = JohnEngine(runtime: runtime, store: store)
        let result = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { text in
            XCTAssertFalse(text.contains("AlphaSecret42")); XCTAssertFalse(text.contains("BetaSecret73"))
        })
        XCTAssertTrue(result.engine.hasPrefix("Metal"), result.engine)
        XCTAssertEqual(result.phase, .recovered)
        XCTAssertEqual(Set(engine.passwords(for: result)), Set(["AlphaSecret42", "BetaSecret73"]))
    }
    func testUnsupportedEncryptedZIPMemberIsNotSilentlySkipped() async throws {
        let (runtime, fixtures) = try paths()
        let preferred = fixtures.appendingPathComponent("unsupported-member.zip")
        let archive = FileManager.default.fileExists(atPath: preferred.path) ? preferred : fixtures.deletingLastPathComponent().appendingPathComponent("review-probes/unsupported-member.zip")
        guard FileManager.default.fileExists(atPath: archive.path) else { throw XCTSkip("Unsupported member fixture missing") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(root: root)
        let engine = JohnEngine(runtime: runtime, store: store)
        do { _ = try await engine.run(job: store.create(configuration: .init(archivePath: archive.path)), update: { _ in }, log: { _ in }); XCTFail("Unsupported encrypted entry must not be silently skipped") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unsupported")) }
    }
    func testPauseBeforeStartIsPreserved() async throws {
        let (runtime, fixtures) = try paths()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(root: root)
        let config = RecoveryConfiguration(archivePath: fixtures.appendingPathComponent("zip-aes256.zip").path)
        let engine = JohnEngine(runtime: runtime, store: store); engine.pause()
        let result = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { _ in })
        XCTAssertEqual(result.phase, .paused)
    }
    func testCPUCheckpointAndResume() async throws {
        let (runtime, fixtures) = try paths()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(root: root)
        var config = RecoveryConfiguration(archivePath: fixtures.appendingPathComponent("zip-aes256.zip").path)
        config.strategy = .mask; config.mask = "?a?a?a?a?a?a?a?a"; config.backend = .cpu; config.workers = 2
        let engine = JohnEngine(runtime: runtime, store: store)
        let initial = try store.create(configuration: config)
        let task = Task { try await engine.run(job: initial, update: { _ in }, log: { _ in }) }
        try await Task.sleep(nanoseconds: 3_000_000_000); engine.pause()
        let paused = try await task.value
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: paused.id).appendingPathComponent("session.rec").path))
        let resumedEngine = JohnEngine(runtime: runtime, store: store)
        let resumedTask = Task { try await resumedEngine.run(job: paused, update: { _ in }, log: { _ in }) }
        try await Task.sleep(nanoseconds: 2_000_000_000); resumedEngine.pause()
        let result = try await resumedTask.value
        XCTAssertEqual(result.phase, .paused)
        XCTAssertGreaterThan(result.elapsedSeconds, paused.elapsedSeconds)
    }
    private func paths() throws -> (URL, URL) {
        guard let root = ProcessInfo.processInfo.environment["ZIPRIPPER_INTEGRATION_ROOT"] else { throw XCTSkip("Set ZIPRIPPER_INTEGRATION_ROOT to run real archive tests.") }
        let base = URL(fileURLWithPath: root)
        return (base.appendingPathComponent(".local/runtime"), base.appendingPathComponent(".local/fixtures"))
    }
    func testRealCPUMatrix() async throws {
        let (runtime, fixtures) = try paths()
        let cases = ["zip-traditional.zip", "zip-aes256.zip", "seven-data.7z", "seven-header.7z", "rar5-p0-password.rar", "rar5-hp0-password.rar", "test-3-RC4-40-open-testpassword.pdf", "test-5-RC4-128-open-testpassword.pdf", "test-7-AES-128-open-testpassword.pdf", "test-X-AES-256-open-testpassword.pdf"]
        for name in cases {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ZipRipper test è \(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = try JobStore(root: folder)
            var config = RecoveryConfiguration(archivePath: fixtures.appendingPathComponent(name).path)
            config.strategy = .wordlist; config.wordlistPath = fixtures.appendingPathComponent("words.txt").path
            config.useRules = false; config.backend = .cpu; config.workers = 1
            let job = try store.create(configuration: config)
            let engine = JohnEngine(runtime: runtime, store: store)
            let result = try await engine.run(job: job, update: { _ in }, log: { _ in })
            XCTAssertEqual(result.phase, .recovered, "\(name): \(result.status)")
            XCTAssertFalse(engine.passwords(for: result).isEmpty, name)
        }
    }
    func testRealMetalToJohnVerification() async throws {
        let (runtime, fixtures) = try paths()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ZipRipper Metal \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try JobStore(root: folder)
        var config = RecoveryConfiguration(archivePath: fixtures.appendingPathComponent("zip-aes256.zip").path)
        config.strategy = .wordlist; config.wordlistPath = fixtures.appendingPathComponent("words.txt").path
        config.useRules = false; config.backend = .metal; config.workers = 1
        let engine = JohnEngine(runtime: runtime, store: store)
        let result = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { _ in })
        XCTAssertEqual(result.phase, .recovered)
        XCTAssertTrue(result.engine.hasPrefix("Metal"), result.engine)
        XCTAssertEqual(engine.passwords(for: result), ["ZipRipper42!"])
    }
    func testRealMetalArchiveMatrix() async throws {
        let (runtime, fixtures) = try paths()
        for (name, password) in [("hp0.rar", "password"), ("test-3-RC4-40-open-testpassword.pdf", "testpassword"), ("test-5-RC4-128-open-testpassword.pdf", "testpassword"), ("test-7-AES-128-open-testpassword.pdf", "testpassword"), ("zip-traditional.zip", "ZipRipper42!"), ("seven-data.7z", "ZipRipper42!"), ("seven-header.7z", "ZipRipper42!"), ("rar5-p0-password.rar", "password"), ("rar5-hp0-password.rar", "password")] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try JobStore(root: root)
            var config = RecoveryConfiguration(archivePath: fixtures.appendingPathComponent(name).path)
            config.strategy = .wordlist; config.wordlistPath = fixtures.appendingPathComponent("words.txt").path
            config.useRules = false; config.backend = .metal; config.workers = 1
            let engine = JohnEngine(runtime: runtime, store: store)
            let result = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { _ in })
            XCTAssertEqual(result.phase, .recovered, "\(name): \(result.status)")
            XCTAssertTrue(result.engine.hasPrefix("Metal"), "\(name): \(result.engine)")
            XCTAssertEqual(engine.passwords(for: result), [password])
        }
    }
    func testMetalCandidateStrategiesAndResume() async throws {
        let (runtime, fixtures) = try paths()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(root: root)
        let zip = root.appendingPathComponent("digits-aes.zip")
        let created = try await ProcessRunner().run(executable: fixtures.appendingPathComponent(".tools/7zz"), arguments: ["a", "-tzip", "-mem=AES256", "-p17", zip.path, fixtures.appendingPathComponent("message.txt").path], directory: root)
        XCTAssertEqual(created.exitCode, 0)
        for strategy in [RecoveryStrategy.mask, .exhaustive, .recommended, .wordlist] {
            let words = root.appendingPathComponent("words.txt")
            try "wrong\npassword\n".write(to: words, atomically: true, encoding: .utf8)
            var config = RecoveryConfiguration(archivePath: (strategy == .recommended || strategy == .wordlist) ? fixtures.appendingPathComponent("rar5-p0-password.rar").path : zip.path)
            config.strategy = strategy; config.mask = "?d?d"; config.minimumLength = 2; config.maximumLength = 2
            config.backend = .metal; config.workers = 1; config.wordlistPath = words.path; config.useRules = true
            let engine = JohnEngine(runtime: runtime, store: store)
            let result = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { _ in })
            XCTAssertEqual(result.phase, .recovered, "\(strategy): \(result.status)")
            XCTAssertTrue(result.engine.hasPrefix("Metal"), result.engine)
            XCTAssertEqual(engine.passwords(for: result), [strategy == .recommended || strategy == .wordlist ? "password" : "17"])
        }
        // Pause after a committed 4096-candidate GPU batch, then replay the
        // deterministic generator from the beginning and skip that exact count.
        var config = RecoveryConfiguration(archivePath: fixtures.appendingPathComponent("zip-aes256.zip").path)
        config.strategy = .mask; config.mask = "?d?d?d?d"; config.backend = .metal; config.workers = 1
        let engine = JohnEngine(runtime: runtime, store: store)
        let paused = try await engine.run(job: store.create(configuration: config), update: { job in
            if job.processedCandidates >= 4096 { engine.pause() }
        }, log: { _ in })
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(paused.processedCandidates, 4096)
        let resumed = try await JohnEngine(runtime: runtime, store: store).run(job: paused, update: { _ in }, log: { _ in })
        XCTAssertEqual(resumed.phase, .exhausted)
        XCTAssertEqual(resumed.processedCandidates, 10000)
    }
    func testCandidateGeneratorCompletionAndExplicitClose() throws {
        let (runtime, _) = try paths()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Exercise a fast exit before the reader/cleanup runs; this exposed a
        // Foundation waitUntilExit race when async recovery changed threads.
        for _ in 0..<12 {
            let stream = try JohnCandidateStream(executable: runtime.appendingPathComponent("bin/john"), arguments: ["--stdout=319", "--mask=?d"], directory: root)
            var words = [String]()
            while let word = try stream.next() { words.append(word) }
            XCTAssertEqual(Set(words), Set((0...9).map(String.init)))
            stream.close(); stream.close()
        }
        let stream = try JohnCandidateStream(executable: runtime.appendingPathComponent("bin/john"), arguments: ["--stdout=319", "--mask=?a?a?a?a?a?a"], directory: root)
        XCTAssertNotNil(try stream.next())
        stream.close()
    }
    func testMetalRAR3PackedAndPDFR5ToJohn() async throws {
        let (runtime, _) = try paths()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vectors = [
            ("rar", "test", "$RAR3$*1*b4eee1a48dc95d12*965f1453*64*47*1*0fe529478798c0960dd88a38a05451f9559e15f0cf20b4cac58260b0e5b56699d5871bdcc35bee099cc131eb35b9a116adaedf5ecc26b1c09cadf5185b3092e6*33"),
            ("PDF", "openwall", "$pdf$5*5*256*-1028*1*16*762896ef582ca042a15f380c63ab9f2c*48*8713e2afdb65df1d3801f77a4c4da4905c49495e7103afc2deb06d9fba7949a565143288823871270d9d882075a75da6*48*15d0b992974ff80529e4b616b8c4c79d787705b6c8a9e0f85446498ae2432e0027d8406b57f78b60b11341a0757d7c4a")
        ]
        let gpu = try MetalArchiveFilter()
        for (format, password, hash) in vectors {
            let survivors = try gpu.filter(candidates: ["wrong", password, "incorrect"], hashLine: hash)
            XCTAssertTrue(survivors.contains(password))
            let hashURL = root.appendingPathComponent("\(format).hash"), words = root.appendingPathComponent("\(format).words"), pot = root.appendingPathComponent("\(format).pot")
            try ("fixture:" + hash + "\n").write(to: hashURL, atomically: true, encoding: .utf8)
            try (survivors.joined(separator: "\n") + "\n").write(to: words, atomically: true, encoding: .utf8)
            let verified = try await ProcessRunner().run(executable: runtime.appendingPathComponent("bin/john"), arguments: [hashURL.path, "--format=\(format)", "--wordlist=\(words.path)", "--pot=\(pot.path)", "--session=\(root.appendingPathComponent(format).path)", "--input-encoding=UTF-8"], directory: root)
            XCTAssertEqual(verified.exitCode, 0)
            XCTAssertEqual(JohnResult.passwords(fromPot: try String(contentsOf: pot, encoding: .utf8)), [password])
        }
    }
    func testUnicodeRulesFallbackPreservesCandidatesBeforeAndAfterInvalidBytes() async throws {
        let (runtime, fixtures) = try paths()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(root: root)
        let words = root.appendingPathComponent("unicode.txt"), message = root.appendingPathComponent("message.txt")
        try "päss\n".write(to: words, atomically: true, encoding: .utf8)
        try Data(contentsOf: fixtures.appendingPathComponent("message.txt")).write(to: message)
        for (index, password) in ["päss", "päss0"].enumerated() {
            let archive = root.appendingPathComponent("unicode-\(index).zip")
            let created = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/zip"), arguments: ["-j", "-P", password, archive.path, message.path], directory: root)
            XCTAssertEqual(created.exitCode, 0)
            var config = RecoveryConfiguration(archivePath: archive.path)
            config.strategy = .wordlist; config.wordlistPath = words.path; config.useRules = true; config.backend = .metal; config.workers = 1
            let engine = JohnEngine(runtime: runtime, store: store)
            let result = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { _ in })
            XCTAssertEqual(result.phase, .recovered, "\(password): \(result.status)")
            XCTAssertEqual(engine.passwords(for: result), [password])
            XCTAssertTrue(result.engine.hasPrefix("CPU"), result.engine)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: result.id).appendingPathComponent("metal-cpu-fallback").path))
        }
    }
    func testMetalStopsWhenAllArchiveEntriesAreRecovered() async throws {
        let (runtime, fixtures) = try paths()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(root: root), archive = root.appendingPathComponent("two-files.zip")
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        let payload = try Data(contentsOf: fixtures.appendingPathComponent("message.txt"))
        try payload.write(to: first); try payload.write(to: second)
        let created = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/zip"), arguments: ["-j", "-P", "0000", archive.path, first.path, second.path], directory: root)
        XCTAssertEqual(created.exitCode, 0)
        var config = RecoveryConfiguration(archivePath: archive.path)
        config.strategy = .mask; config.mask = "?d?d?d?d"; config.backend = .metal; config.workers = 1
        let engine = JohnEngine(runtime: runtime, store: store)
        let result = try await engine.run(job: store.create(configuration: config), update: { _ in }, log: { _ in })
        XCTAssertEqual(result.phase, .recovered)
        XCTAssertTrue(result.engine.hasPrefix("Metal"), result.engine)
        // The matching candidate is in the second 1024-entry batch; stop
        // before searching the rest of the 10,000-candidate mask.
        XCTAssertEqual(result.processedCandidates, 2048)
        XCTAssertEqual(engine.passwords(for: result), ["0000"])
    }
    func testChangedArchiveRejectsResume() async throws {
        let (runtime, fixtures) = try paths()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try JobStore(root: folder)
        var config = RecoveryConfiguration(archivePath: fixtures.appendingPathComponent("zip-aes256.zip").path)
        config.strategy = .wordlist; config.wordlistPath = fixtures.appendingPathComponent("words.txt").path
        var job = try store.create(configuration: config); job.archiveDigest = "changed"
        let engine = JohnEngine(runtime: runtime, store: store)
        do { _ = try await engine.run(job: job, update: { _ in }, log: { _ in }); XCTFail("Changed archive must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    }
}
