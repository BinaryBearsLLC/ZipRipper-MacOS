import Foundation

public final class JohnEngine: @unchecked Sendable {
    public let runtime: URL
    public let store: JobStore
    private let runner = ProcessRunner()
    private let lock = NSLock()
    private var interrupted = false
    private var candidateStream: JohnCandidateStream?
    private var calibration: RecoveryBenchmark?
    private let profile: PerformanceProfile?
    public init(runtime: URL, store: JobStore, profile: PerformanceProfile? = nil) { self.runtime = runtime; self.store = store; self.profile = profile }
    public func pause() { lock.lock(); interrupted = true; let stream = candidateStream; let calibration = calibration; lock.unlock(); stream?.interrupt(); calibration?.cancel(); runner.interrupt() }
    private var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return interrupted }
    public static func arguments(configuration c: RecoveryConfiguration, directory d: URL) throws -> [String] {
        try c.validate()
        // Level 3 disables Jumbo's whole-wordlist preload (doc/OPTIONS).
        var args = [d.appendingPathComponent("hash.txt").path, "--pot=\(d.appendingPathComponent("passwords.pot").path)", "--session=\(d.appendingPathComponent("session").path)", "--progress-every=1", "--input-encoding=UTF-8", "--save-memory=3"]
        if c.workers > 1 { args.append("--fork=\(c.workers)") }
        switch c.strategy {
        case .recommended, .wordlist:
            args.append("--wordlist=\(d.appendingPathComponent("wordlist.txt").path)")
            if c.useRules { args.append("--rules=single,wordlist") }
        case .mask: args.append("--mask=\(c.mask)")
        case .exhaustive:
            let mode = ["Digits": "Digits", "Lowercase": "Lower", "Alphanumeric": "Alnum", "ASCII": "ASCII"][c.characterSet] ?? "Digits"
            args += ["--incremental=\(mode)", "--min-length=\(c.minimumLength)", "--max-length=\(c.maximumLength)"]
        }
        return args
    }
    private func setCandidateStream(_ stream: JohnCandidateStream?) {
        lock.lock(); candidateStream = stream; let paused = interrupted; lock.unlock()
        if paused { stream?.interrupt() }
    }
    private func setCalibration(_ probe: RecoveryBenchmark?) {
        lock.lock(); calibration = probe; let paused = interrupted; lock.unlock()
        if paused { probe?.cancel() }
    }
    static func candidateArguments(configuration: RecoveryConfiguration, directory: URL, maximumLength: Int = 319) throws -> [String] {
        let search = try arguments(configuration: configuration, directory: directory)
        return ["--stdout=\(maximumLength)", "--input-encoding=UTF-8"] + search.filter {
            $0.hasPrefix("--save-memory=") || $0.hasPrefix("--wordlist=") || $0.hasPrefix("--rules=") || $0.hasPrefix("--mask=") || $0.hasPrefix("--incremental=") || $0.hasPrefix("--min-length=") || $0.hasPrefix("--max-length=")
        }
    }
    public func run(job initial: RecoveryJob, update: @escaping @Sendable (RecoveryJob) -> Void, log: @escaping @Sendable (String) -> Void, currentCandidate: @escaping @Sendable (String?) -> Void = { _ in }) async throws -> RecoveryJob {
        // A coordinator is created per run, so an immediate Pause must not be reset.
        var job = initial
        let start = Date(), previousElapsed = job.elapsedSeconds
        let folder = store.directory(for: job.id), fm = FileManager.default
        let pattern = job.configuration.strategy == .mask ? try? PasswordPattern(mask: job.configuration.mask) : nil
        let logSink = JohnLogSink(emit: log, candidate: currentCandidate, candidateLength: pattern?.isValid == true ? pattern?.length : nil)
        defer { logSink.finish(); currentCandidate(nil) }
        func publish(_ status: String? = nil) throws {
            if let status { job.status = status }
            job.updatedAt = Date(); job.elapsedSeconds = previousElapsed + Date().timeIntervalSince(start)
            try store.save(job); update(job)
        }
        do {
            try job.configuration.validate()
            job.phase = .preparing; try publish("Checking the archive")
            let archive = URL(fileURLWithPath: job.configuration.archivePath)
            let digest = try JobStore.digest(of: archive)
            if job.archiveDigest == nil && fm.fileExists(atPath: folder.appendingPathComponent("hash.txt").path) {
                throw RecoveryError.message("This session has no saved archive identity. Start a new recovery to avoid reusing an unverified checkpoint.")
            }
            if let old = job.archiveDigest, old != digest { throw RecoveryError.message("The archive has changed since this session began. Start a new recovery to keep the saved session consistent.") }
            job.archiveDigest = digest
            // Commit identity before publishing any reusable derived files.
            try publish()
            if isPaused { throw CancellationError() }
            let hashURL = folder.appendingPathComponent("hash.txt")
            if !fm.fileExists(atPath: hashURL.path) {
                let extracted: CommandResult
                if archive.pathExtension.lowercased() == "zip" {
                    let entries = try ZIPEntryReader.encryptedEntryNames(at: archive)
                    guard !entries.isEmpty else { throw RecoveryError.message("This ZIP contains no encrypted entries.") }
                    var lines = [String](), seen = Set<String>(), diagnostics = ""
                    for entry in entries {
                        if isPaused { throw CancellationError() }
                        let item = try await runner.run(executable: runtime.appendingPathComponent("bin/zip2john"), arguments: ["-o", entry, archive.path], directory: folder)
                        guard item.exitCode == 0 else { throw RecoveryError.message("Could not inspect ZIP entry: \(entry).\n\(JohnResult.redactedDiagnostics(item.stderr).suffix(800))") }
                        guard !item.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecoveryError.message("The encrypted ZIP entry ‘\(entry)’ uses an unsupported compression or encryption variant. No entries were silently skipped; the archive is unchanged.\n\(JohnResult.redactedDiagnostics(item.stderr).suffix(800))") }
                        for line in item.stdout.split(separator: "\n").map(String.init) where seen.insert(line).inserted { lines.append(line) }
                        diagnostics += item.stderr
                    }
                    extracted = CommandResult(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: diagnostics)
                } else {
                    extracted = try await runner.run(executable: runtime.appendingPathComponent("run/extract-hash"), arguments: [archive.path], directory: folder)
                }
                if isPaused { throw CancellationError() }
                guard extracted.exitCode == 0, !extracted.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RecoveryError.message("Could not read an encrypted password from this file. It may be unencrypted, damaged or unsupported.\n\(JohnResult.redactedDiagnostics(extracted.stderr).suffix(1600))")
                }
                try Data(extracted.stdout.utf8).write(to: hashURL, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hashURL.path)
            }
            let hash = try String(contentsOf: hashURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let groups = try Self.hashGroups(hash)
            let wordlist = folder.appendingPathComponent("wordlist.txt")
            if [.recommended, .wordlist].contains(job.configuration.strategy), !fm.fileExists(atPath: wordlist.path) {
                let source: URL
                if job.configuration.strategy == .wordlist { source = URL(fileURLWithPath: job.configuration.wordlistPath) }
                else {
                    let standard = runtime.appendingPathComponent("run/password.lst")
                    source = fm.fileExists(atPath: standard.path) ? standard : CoreResources.bundle.url(forResource: "default-passwords", withExtension: "txt")!
                }
                try publish("Validating and copying the wordlist (this may take time for large files)")
                var lastProgress = Date.distantPast
                let inspection = try WordlistReader.stage(source: source, destination: wordlist, isCancelled: { self.isPaused }, progress: { copied, total in
                    if Date().timeIntervalSince(lastProgress) >= 0.5 || copied == total {
                        lastProgress = Date()
                        let percentage = total > 0 ? Int(Double(copied) / Double(total) * 100) : 0
                        job.status = "Validating wordlist: \(percentage)% · \(ByteCountFormatter.string(fromByteCount: copied, countStyle: .file))"
                        update(job)
                    }
                })
                job.candidateCount = SearchEstimate.candidateCount(job.configuration, wordCount: inspection.candidateCount)
                try publish()
            }
            if job.candidateCount == nil { job.candidateCount = SearchEstimate.candidateCount(job.configuration, wordCount: nil) }
            let hashLines = hash.split(separator: "\n").map(String.init)
            // Every record must have a safe filter. Multi-entry archives use the
            // union of survivors so different entry passwords remain visible.
            let fallbackMarker = folder.appendingPathComponent("metal-cpu-fallback")
            let usesRules = job.configuration.useRules && [.recommended, .wordlist].contains(job.configuration.strategy)
            let compatibleRuleLengths = groups.count == 1 || !usesRules
            let canUseMetal = job.configuration.backend != .cpu && !fm.fileExists(atPath: fallbackMarker.path)
                && compatibleRuleLengths && hashLines.allSatisfy { MetalArchiveFilter.supports(hashLine: $0) }
            var gpu: MetalArchiveFilter?
            if canUseMetal { do { gpu = try MetalArchiveFilter() } catch { log("Metal unavailable: \(error.localizedDescription). Using CPU.\n") } }
            // Never move an existing checkpoint between CPU and GPU semantics.
            if job.resolvedBackend == nil {
                if job.processedCandidates > 0 { job.resolvedBackend = .metal }
                else if (try? fm.contentsOfDirectory(atPath: folder.path))?.contains(where: { $0.hasSuffix(".rec") }) == true { job.resolvedBackend = .cpu }
            }
            // A probe would cost more than a very small search.
            if job.configuration.backend == .automatic, job.resolvedBackend == nil, let count = job.candidateCount, count <= 64 {
                job.resolvedBackend = .cpu
            }
            if job.resolvedBackend == .cpu { gpu = nil }
            if job.configuration.backend == .automatic, job.resolvedBackend == nil, let device = gpu {
                try publish("Calibrating CPU and Metal for this file…")
                let sampleSize = hashLines.allSatisfy { MetalZIPFilter.supports(hashLine: $0) } ? 4096 : MetalArchiveFilter.recommendedBatchSize
                var sample = [String]()
                if [.recommended, .wordlist].contains(job.configuration.strategy), !usesRules {
                    let reader = try WordlistReader(url: wordlist)
                    for _ in 0..<sampleSize {
                        if isPaused { throw CancellationError() }
                        guard let word = try reader.next() else { break }
                        if word.utf8.count <= 319 { sample.append(word) }
                    }
                }
                if sample.isEmpty { sample = (0..<sampleSize).map { "zrbench" + String(format: "%010d", $0) } }
                let probe = RecoveryBenchmark(runtime: runtime, workers: job.configuration.workers)
                setCalibration(probe)
                defer { setCalibration(nil) }
                do {
                    let rates = try await probe.calibrate(lines: hashLines, candidates: sample, gpu: device)
                    job.resolvedBackend = rates.metal > rates.cpu ? .metal : .cpu
                    job.measuredRate = max(rates.cpu, rates.metal)
                    log("File calibration: CPU \(Int(rates.cpu)) p/s · Metal + verification \(Int(rates.metal)) p/s.\n")
                    if job.resolvedBackend == .cpu { gpu = nil }
                } catch is CancellationError { throw CancellationError() }
                catch { log("Calibration unavailable; using the supported engine.\n") }
            }
            job.resolvedBackend = gpu == nil ? .cpu : .metal
            if gpu == nil && groups.count > 1 { job.candidateCount = nil }
            if job.measuredRate == nil { job.measuredRate = profile?.referenceRate(lines: hashLines, backend: job.resolvedBackend ?? .cpu, workers: job.configuration.workers) }
            job.phase = .running
            var usedMetal = false
            if let gpu {
                do {
                    job.engine = "Metal · \(gpu.deviceName)"
                    try publish("Generating candidates and checking them on the GPU")
                    let gpuPot = folder.appendingPathComponent("passwords.pot")
                    for (format, lines) in groups {
                        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("verify-\(format).txt"), options: .atomic)
                    }
                    func gpuEntriesComplete() async throws -> Bool {
                        var remaining = 0
                        for (format, _) in groups {
                            let checked = try await runner.run(executable: runtime.appendingPathComponent("bin/john"), arguments: ["--show", "--format=\(format)", "--pot=\(gpuPot.path)", folder.appendingPathComponent("verify-\(format).txt").path], directory: folder)
                            if isPaused { throw CancellationError() }
                            guard checked.exitCode == 0, let count = JohnResult.remainingCount(fromShow: checked.stdout), count + JohnResult.crackedCount(fromShow: checked.stdout) > 0 else { throw RecoveryError.message("Could not verify the recovered entries. The session is preserved.") }
                            remaining += count
                        }
                        return remaining == 0
                    }
                    var lastCheckedPot = (try? Data(contentsOf: gpuPot)) ?? Data()
                    var allRecovered = false
                    if !lastCheckedPot.isEmpty { allRecovered = try await gpuEntriesComplete() }
                    let directWords = [.recommended, .wordlist].contains(job.configuration.strategy) && !job.configuration.useRules
                    let reader = directWords ? try WordlistReader(url: wordlist) : nil
                    // Match the running John's format length for length-sensitive
                    // rules. Never assume stdout's default length matches RAR/7z.
                    var generatorLength = 319
                    if !directWords && !allRecovered {
                        let details = try await runner.run(executable: runtime.appendingPathComponent("bin/john"), arguments: ["--list=format-details", "--format=\(groups.map { $0.0 }.joined(separator: ","))"], directory: folder)
                        let lengths = details.stdout.split(separator: "\n").compactMap { row -> Int? in
                            let fields = row.split(separator: "\t")
                            return fields.count >= 2 ? Int(fields[1]) : nil
                        }
                        guard details.exitCode == 0, lengths.count == groups.count, lengths.allSatisfy({ (1...319).contains($0) }), let length = lengths.max() else { throw RecoveryError.message("Could not determine John's candidate length. Use CPU recovery for this search.") }
                        generatorLength = length
                    }
                    let stream = (directWords || allRecovered) ? nil : try JohnCandidateStream(executable: runtime.appendingPathComponent("bin/john"), arguments: Self.candidateArguments(configuration: job.configuration, directory: folder, maximumLength: generatorLength), directory: folder)
                    setCandidateStream(stream)
                    defer { setCandidateStream(nil); stream?.close() }
                    func next() throws -> String? { if isPaused { throw CancellationError() }; return try reader?.next() ?? stream?.next() }
                    var skipped: UInt64 = 0
                    while skipped < job.processedCandidates && !allRecovered {
                        guard try next() != nil else { throw RecoveryError.message("The saved candidate checkpoint is no longer valid. Start a new session.") }
                        skipped += 1
                    }
                    // Keep replay bounded while filling enough GPU lanes for expensive KDFs.
                    let batchSize = hashLines.allSatisfy { MetalZIPFilter.supports(hashLine: $0) } ? 4096 : MetalArchiveFilter.recommendedBatchSize
                    var lastCandidateReport = Date.distantPast
                    var rateWindowStart = ProcessInfo.processInfo.systemUptime
                    var rateWindowCount: UInt64 = 0
                    while !isPaused && !allRecovered {
                        var batch = [String]()
                        for _ in 0..<batchSize { guard let line = try next() else { break }; batch.append(line) }
                        if batch.isEmpty { break }
                        if Date().timeIntervalSince(lastCandidateReport) >= 0.25 {
                            currentCandidate("Batch: " + String((batch.first ?? "").prefix(160)))
                            lastCandidateReport = Date()
                        }
                        var survivors = Set<String>()
                        for line in hashLines {
                            survivors.formUnion(try gpu.filter(candidates: batch, hashLine: line, isCancelled: { self.isPaused }))
                        }
                        if isPaused { throw CancellationError() }
                        if !survivors.isEmpty {
                            let candidateFile = folder.appendingPathComponent("candidates.txt")
                            try Data((batch.filter { survivors.contains($0) }.joined(separator: "\n") + "\n").utf8).write(to: candidateFile, options: .atomic)
                            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidateFile.path)
                            for (format, _) in groups {
                                let verifyHash = folder.appendingPathComponent("verify-\(format).txt")
                                let checked = try await runner.run(executable: runtime.appendingPathComponent("bin/john"), arguments: [verifyHash.path, "--format=\(format)", "--input-encoding=UTF-8", "--wordlist=\(candidateFile.path)", "--pot=\(folder.appendingPathComponent("passwords.pot").path)", "--session=\(folder.appendingPathComponent("verify").path)"], directory: folder, onOutput: { logSink.accept($0) })
                                if isPaused { throw CancellationError() }
                                guard checked.exitCode == 0 else { throw RecoveryError.message("CPU verification failed: \(JohnResult.redactedDiagnostics(checked.stderr).suffix(1200))") }
                            }
                        }
                        job.processedCandidates += UInt64(batch.count)
                        rateWindowCount += UInt64(batch.count)
                        let rateElapsed = ProcessInfo.processInfo.systemUptime - rateWindowStart
                        if rateElapsed >= 10 || job.measuredRate == nil {
                            job.measuredRate = Double(rateWindowCount) / max(0.001, rateElapsed)
                            rateWindowStart = ProcessInfo.processInfo.systemUptime; rateWindowCount = 0
                        }
                        try publish("\(job.processedCandidates.formatted()) candidates checked")
                        let currentPot = (try? Data(contentsOf: folder.appendingPathComponent("passwords.pot"))) ?? Data()
                        if !currentPot.isEmpty && currentPot != lastCheckedPot {
                            lastCheckedPot = currentPot
                            allRecovered = try await gpuEntriesComplete()
                        }
                    }
                    usedMetal = true
                } catch CandidateStreamError.nonUTF8 {
                    if isPaused { throw CancellationError() }
                    // Standard John rules can turn valid UTF-8 words into raw
                    // byte candidates. Replay the complete search on John so
                    // neither those bytes nor an earlier valid word is lost.
                    try Data("John rules produced raw byte candidates. CPU replay preserves exact candidate semantics.\n".utf8).write(to: fallbackMarker, options: .atomic)
                    job.processedCandidates = 0; job.resolvedBackend = .cpu; job.measuredRate = nil
                    log("John rules generated raw byte candidates. Restarting this search on the CPU to preserve every candidate exactly.\n")
                }
            }
            if !usedMetal {
                job.engine = "CPU · \(job.configuration.workers) workers"
                if job.configuration.backend != .cpu {
                    if fm.fileExists(atPath: fallbackMarker.path) {
                        log("CPU selected to preserve the raw byte candidates generated by John's rules.\n")
                    } else if !compatibleRuleLengths {
                        log("CPU selected because rule transformations depend on the different candidate lengths of these archive formats.\n")
                    } else if !canUseMetal {
                        log("CPU selected: this record includes a variant without a safe Metal filter. Metal supports WinZip AES, ZipCrypto, RAR3/RAR5, selected 7z records and PDF revisions 2–5.\n")
                    }
                }
                for (format, lines) in groups {
                    if isPaused { throw CancellationError() }
                    let multiple = groups.count > 1
                    let session = folder.appendingPathComponent(multiple ? "session-\(format)" : "session")
                    let groupHash = multiple ? folder.appendingPathComponent("hash-\(format).txt") : hashURL
                    let completed = folder.appendingPathComponent("completed-\(format)")
                    if fm.fileExists(atPath: completed.path) { continue }
                    if multiple { try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: groupHash, options: .atomic) }
                    let restore = fm.fileExists(atPath: session.appendingPathExtension("rec").path)
                    try publish(restore ? "Resuming the saved \(format) session" : "Searching \(format) entries for passwords")
                    var args = try Self.arguments(configuration: job.configuration, directory: folder)
                    args[0] = groupHash.path
                    args = args.map { $0.hasPrefix("--session=") ? "--session=\(session.path)" : $0 }
                    args.append("--format=\(format)")
                    if restore { args = ["--restore=\(session.path)"] }
                    let result = try await runner.run(executable: runtime.appendingPathComponent("bin/john"), arguments: args, directory: folder, onOutput: { logSink.accept($0) })
                    if isPaused { throw CancellationError() }
                    guard result.exitCode == 0 else { throw RecoveryError.message("Recovery engine stopped: \(JohnResult.redactedDiagnostics(result.stderr).suffix(1800))") }
                    try Data().write(to: completed, options: .atomic)
                }
            }
            if isPaused { throw CancellationError() }
            let found = passwords(for: job)
            var remaining = 0
            for (format, lines) in groups {
                let reportHash = folder.appendingPathComponent("report-\(format).txt")
                try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: reportHash, options: .atomic)
                let report = try await runner.run(executable: runtime.appendingPathComponent("bin/john"), arguments: ["--show", "--format=\(format)", "--pot=\(folder.appendingPathComponent("passwords.pot").path)", reportHash.path], directory: folder)
                if isPaused { throw CancellationError() }
                guard report.exitCode == 0, let count = JohnResult.remainingCount(fromShow: report.stdout), count + JohnResult.crackedCount(fromShow: report.stdout) > 0 else { throw RecoveryError.message("Could not verify the final recovery summary. Your session has been preserved.") }
                remaining += count
            }
            job.phase = found.isEmpty ? .exhausted : (remaining == 0 ? .recovered : .partial)
            try publish(found.isEmpty ? "No password matched this search. Try a different wordlist or pattern." : remaining == 0 ? "Password recovery verified by John for all extracted entries" : "Recovered \(found.count) password(s); \(remaining) encrypted entry hash(es) remain. Try another search for the remaining entries.")
        } catch is CancellationError {
            job.phase = .paused; try publish("Session saved. You can resume later.")
        } catch {
            job.phase = .failed; try publish(error.localizedDescription)
            throw error
        }
        return job
    }
    public func passwords(for job: RecoveryJob) -> [String] {
        let pot = store.directory(for: job.id).appendingPathComponent("passwords.pot")
        return JohnResult.passwords(fromPot: (try? String(contentsOf: pot, encoding: .utf8)) ?? "")
    }
    static func hashGroups(_ text: String) throws -> [(String, [String])] {
        // Match record grammar after a field delimiter, never a bare marker in
        // an archive/member filename. Ambiguous records are rejected explicitly.
        let markers = [(#":\$pkzip2?\$[0-9]+\*"#, "PKZIP"), (#":\$zip2\$\*[0-9]+\*"#, "ZIP"), (#":\$rar5\$[0-9]+\$"#, "RAR5"), (#":\$RAR3\$\*[01]\*"#, "rar"), (#":\$7z\$[0-9]+\$"#, "7z"), (#":\$pdf\$[0-9]+\*"#, "PDF")]
        var groups: [String: [String]] = [:]
        for line in text.split(separator: "\n").map(String.init) {
            let formats = markers.filter { line.range(of: $0.0, options: .regularExpression) != nil }.map(\.1)
            guard formats.count == 1, let format = formats.first else { throw RecoveryError.message("The extractor returned an unsupported or ambiguous password record. Try an archive filename without hash-like punctuation.") }
            groups[format, default: []].append(line)
        }
        return groups.keys.sorted().map { ($0, groups[$0]!) }
    }
}
