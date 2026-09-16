import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Metal
import ZipRipperCore

enum AppSection: String, CaseIterable { case recovery = "Recovery", sessions = "Sessions", engine = "Engine", about = "About" }

@MainActor final class AppModel: ObservableObject {
    @Published var section: AppSection = .recovery { didSet { popupVisible = true } }
    @Published var popupVisible = false
    @Published var configuration = RecoveryConfiguration(archivePath: "")
    @Published var jobs: [RecoveryJob] = []
    @Published var selectedID: UUID?
    @Published var activeID: UUID?
    @Published var log = ""
    @Published var error: String?
    @Published var isPausing = false
    @Published var reveal = false
    @Published var runtimeURL: URL?
    @Published var guiScale: Double = 1 { didSet { UserDefaults.standard.set(guiScale, forKey: "guiScale") } }
    @Published var wordlistSummary = ""
    @Published var currentCandidate: String?
    @Published var benchmarking = false
    @Published var benchmarkResults: [BenchmarkResult] = []
    @Published var benchmarkStatus = ""
    private var benchmark: RecoveryBenchmark?
    private var benchmarkTask: Task<Void, Never>?
    @Published var deleteCandidate: RecoveryJob?
    let store: JobStore?
    let gpuName = MTLCreateSystemDefaultDevice()?.name
    private var engine: JohnEngine?
    private var task: Task<Void, Never>?
    private var lockDescriptor: Int32 = -1
    let dataRoot: URL

    init() {
        let override = ProcessInfo.processInfo.environment["ZIPRIPPER_DATA_ROOT"]
        dataRoot = override.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ZipRipper", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            store = try JobStore(root: dataRoot.appendingPathComponent("Sessions"))
        } catch { store = nil; self.error = error.localizedDescription }
        lockDescriptor = open(dataRoot.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        if lockDescriptor < 0 || flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            error = "Another ZipRipper instance is using these sessions. Quit it before starting recovery here."
            lockDescriptor = -1
        }
        if let store, lockDescriptor >= 0 {
            jobs = (try? store.load()) ?? []
            for index in jobs.indices where jobs[index].phase == .running || jobs[index].phase == .preparing {
                jobs[index].phase = .paused; jobs[index].status = "Previous session interrupted. Ready to resume."
                try? store.save(jobs[index])
            }
        }
        guiScale = UserDefaults.standard.double(forKey: "guiScale") == 0.75 ? 0.75 : 1
        locateRuntime()
        if let runtimeURL {
            profileIdentity = PerformanceProfile.identity(runtime: runtimeURL, appVersion: Self.appVersion)
            if let saved = PerformanceProfile.load(from: profileURL, identity: profileIdentity) {
                benchmarkResults = saved.results
                benchmarkStatus = "Saved " + saved.date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().locale(Locale(identifier: "en_US")))
            } else {
                benchmarkSuggested = UserDefaults.standard.string(forKey: "benchmarkDeferredIdentity") != profileIdentity
            }
        }
    }
    var currentJob: RecoveryJob? { jobs.first { $0.id == selectedID } }
    var isBusy: Bool { activeID != nil }
    var passwords: [String] {
        guard let job = currentJob, let store else { return [] }
        let path = store.directory(for: job.id).appendingPathComponent("passwords.pot")
        return JohnResult.passwords(fromPot: (try? String(contentsOf: path, encoding: .utf8)) ?? "")
    }
    var runtimeReady: Bool { runtimeURL != nil }
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.5.3"
    @Published var speedText = "Measuring…"
    @Published var etaText = ""
    @Published var benchmarkSuggested = false
    @Published var showBenchmark = false
    private var profileIdentity = ""
    private var progressTimer: Timer?
    private var estimateGate = SearchEstimate()
    private var profileURL: URL { dataRoot.appendingPathComponent("benchmark.json") }
    func offerBenchmark() {
        if benchmarkSuggested { openSection(.engine) }
    }
    func deferBenchmark() {
        benchmarkSuggested = false
        UserDefaults.standard.set(profileIdentity, forKey: "benchmarkDeferredIdentity")
    }
    private func refreshEstimate() {
        guard let job = currentJob, job.phase == .running, estimateGate.shouldUpdate(at: ProcessInfo.processInfo.systemUptime) else { return }
        let rate = job.engine.hasPrefix("Metal") ? job.measuredRate : (RecoveryBenchmark.aggregateRate(log, workers: job.configuration.workers) ?? job.measuredRate)
        speedText = rate.map { "\(Int(min($0, Double(Int.max / 2))).formatted()) passwords/s" } ?? "Measuring…"
        let fraction = job.engine.hasPrefix("Metal") ? nil : RecoveryBenchmark.progressFraction(log, workers: job.configuration.workers)
        let completed = job.engine.hasPrefix("Metal") ? Double(job.processedCandidates) : (job.candidateCount ?? 0) * (fraction ?? 0)
        if let seconds = SearchEstimate.remaining(total: job.candidateCount, completed: completed, rate: rate) {
            etaText = (job.engine.hasPrefix("Metal") || fraction != nil ? "Remaining: " : "Full search: ") + SearchEstimate.text(seconds: seconds)
        } else { etaText = job.candidateCount == nil ? "ETA unavailable for this search" : "Estimating…" }
    }
    func locateRuntime() {
        var choices: [URL] = []
        if let resources = Bundle.main.resourceURL { choices.append(resources.appendingPathComponent("runtime")) }
        // Development only: an executable launched by swift run can use a local build.
        if Bundle.main.bundleURL.pathExtension != "app" {
            if let override = ProcessInfo.processInfo.environment["ZIPRIPPER_RUNTIME"] { choices.append(URL(fileURLWithPath: override)) }
            choices.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/runtime")) }
        runtimeURL = choices.first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("bin/john").path) && FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("run/extract-hash").path) }
    }
    func closePopup() { error = nil; deleteCandidate = nil; popupVisible = false }
    func openSection(_ section: AppSection) { self.section = section; popupVisible = true }
    func chooseArchive() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["zip", "rar", "7z", "pdf"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a file you own or are authorized to recover."
        if panel.runModal() == .OK, let url = panel.url { selectArchive(url) }
    }
    func selectArchive(_ url: URL) {
        guard !isBusy else { return }
        selectedID = nil; reveal = false; configuration.archivePath = url.path; section = .recovery; log = ""
    }
    func chooseWordlist() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.message = "Choose a UTF-8 text file with one password per line."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let inspection = try WordlistReader.inspect(url: url)
                configuration.wordlistPath = url.path
                wordlistSummary = inspection.summary
            } catch { self.error = error.localizedDescription }
        }
    }
    func newRecovery() { guard !isBusy else { return }; selectedID = nil; reveal = false; log = ""; section = .recovery }
    func start() {
        guard UserDefaults.standard.bool(forKey: "authorizedUseAcceptedV1") else { error = "Accept the authorized-use notice before starting recovery."; return }
        guard !isBusy, !benchmarking, lockDescriptor >= 0, let store else { return }
        popupVisible = true
        guard let runtimeURL else { section = .engine; return }
        do {
            let job: RecoveryJob
            if let previous = currentJob, previous.phase.resumable { job = previous }
            else {
                try configuration.validate()
                if configuration.strategy == .mask && !configuration.mask.utf8.allSatisfy({ $0 < 128 }) {
                    throw RecoveryError.message("Pattern searches support ASCII characters. For accents or emoji, choose a UTF-8 wordlist.")
                }
                guard FileManager.default.isReadableFile(atPath: configuration.archivePath) else { throw RecoveryError.message("This file cannot be read. Choose the archive again.") }
                job = try store.create(configuration: configuration); jobs.insert(job, at: 0)
            }
            selectedID = job.id; activeID = job.id; reveal = false; log = ""; currentCandidate = nil; isPausing = false
            speedText = "Measuring…"; etaText = ""; estimateGate = SearchEstimate()
            progressTimer?.invalidate()
            progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshEstimate() }
            }
            let recovery = JohnEngine(runtime: runtimeURL, store: store, profile: PerformanceProfile.load(from: profileURL, identity: profileIdentity)); engine = recovery
            task = Task {
                do {
                    _ = try await recovery.run(job: job, update: { [weak self] job in
                        Task { @MainActor in self?.receive(job) }
                    }, log: { [weak self] text in
                        Task { @MainActor in self?.log = String(((self?.log ?? "") + text).suffix(18000)) }
                    }, currentCandidate: { [weak self] candidate in
                        Task { @MainActor in
                            guard self?.activeID == job.id else { return }
                            self?.currentCandidate = candidate
                        }
                    })
                } catch { self.error = error.localizedDescription }
                self.jobs = (try? store.load()) ?? self.jobs
                self.progressTimer?.invalidate(); self.progressTimer = nil
                self.activeID = nil; self.currentCandidate = nil; self.isPausing = false; self.engine = nil
                if self.currentJob?.phase == .recovered { NSSound(named: "Glass")?.play(); NSApp.requestUserAttention(.informationalRequest) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func receive(_ job: RecoveryJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }), jobs[index].updatedAt <= job.updatedAt { jobs[index] = job }
        refreshEstimate()
    }
    func pause() { guard isBusy else { return }; isPausing = true; engine?.pause() }
    func prepareToQuit() async {
        pause()
        benchmark?.cancel()
        await task?.value
        await benchmarkTask?.value
    }
    func select(_ job: RecoveryJob) {
        selectedID = job.id; configuration = job.configuration; reveal = false; section = .recovery
        wordlistSummary = (try? WordlistReader.inspect(url: URL(fileURLWithPath: configuration.wordlistPath)).summary) ?? ""
    }
    func delete(_ job: RecoveryJob) {
        guard job.id != activeID, let store else { return }
        do { try store.delete(job); jobs.removeAll { $0.id == job.id }; if selectedID == job.id { selectedID = nil } }
        catch { self.error = error.localizedDescription }
    }
    func copyPassword() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(passwords.joined(separator: "\n"), forType: .string) }
    func exportPassword() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Recovered password.txt"; panel.allowedContentTypes = [.plainText]
        panel.message = "This file will contain the recovered password in plain text."
        if panel.runModal() == .OK, let url = panel.url {
            do { try (passwords.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            catch { self.error = error.localizedDescription }
        }
    }
    func startBenchmark() {
        guard !isBusy, !benchmarking, lockDescriptor >= 0 else { return }
        guard UserDefaults.standard.bool(forKey: "authorizedUseAcceptedV1") else { return }
        guard let runtimeURL else { section = .engine; return }
        deferBenchmark(); showBenchmark = true
        benchmarkResults = []; benchmarkStatus = "Testing one format at a time…"; benchmarking = true
        let runner = RecoveryBenchmark(runtime: runtimeURL); benchmark = runner
        benchmarkTask = Task {
            do {
                let results = try await runner.run { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        if let index = self.benchmarkResults.firstIndex(where: { $0.id == result.id }) { self.benchmarkResults[index] = result }
                        else { self.benchmarkResults.append(result) }
                    }
                }
                benchmarkResults = results
                try PerformanceProfile(identity: profileIdentity, results: results).save(to: profileURL)
                benchmarkStatus = "Saved"
            } catch is CancellationError { benchmarkStatus = "Stopped" }
            catch { benchmarkStatus = error.localizedDescription }
            benchmarking = false; benchmark = nil
        }
    }
    func cancelBenchmark() { benchmarkStatus = "Stopping…"; benchmark?.cancel() }
}
