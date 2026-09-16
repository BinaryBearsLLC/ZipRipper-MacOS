import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ZipRipperCore

struct MainView: View {
    @ObservedObject var model: AppModel
    let minimize: () -> Void
    var body: some View {
        ZStack(alignment: .topLeading) {
            mascot.resizable().scaledToFit().frame(width: 558, height: 558)
                .overlay(WindowDragRegion()).position(x: 300, y: 280)
                .accessibilityLabel("ZipRipper mascot. Drag to move.")
            HStack(spacing: 7) {
                windowButton("minus", label: "Minimize", action: minimize)
                windowButton("xmark", label: "Quit ZipRipper") { NSApp.terminate(nil) }
            }.position(x: 547, y: 42)
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                OrbButton(section: section, active: model.popupVisible && model.section == section,
                          busy: section == .recovery && model.isBusy) { model.openSection(section) }
                    .position(x: 84 + CGFloat(index) * 144, y: index == 0 || index == 3 ? 515 : 552)
            }
        }
        .frame(width: 600, height: 620).background(Color.clear).preferredColorScheme(.dark)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.selectArchive(url) } } }
            return true
        }
    }
    private static let mascotImage: NSImage = {
        if let url = AppResources.bundle.url(forResource: "mascot", withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil)!
    }()
    private var mascot: Image { Image(nsImage: Self.mascotImage) }
    private func windowButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 25, height: 25).background(Color(white: 0.09).opacity(0.88), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.8))
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

private struct OrbButton: View {
    let section: AppSection
    let active: Bool
    let busy: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(RadialGradient(stops: [
                    .init(color: Color(red: 0.30, green: 0.36, blue: 0.43), location: 0),
                    .init(color: Color(red: 0.10, green: 0.13, blue: 0.17), location: 0.60),
                    .init(color: Color(red: 0.27, green: 0.33, blue: 0.41), location: 0.82),
                    .init(color: Color(red: 0.69, green: 0.79, blue: 0.9), location: 0.96),
                    .init(color: Color(white: 0.28), location: 1)
                ], center: .center, startRadius: 0, endRadius: 66))
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.05), Color(red: 0.59, green: 0.75, blue: 0.91), .white.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.6)
                Circle().inset(by: 6).stroke(.white.opacity(0.19), lineWidth: 1)
                Ellipse().fill(LinearGradient(colors: [.white.opacity(0.48), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 94, height: 45).rotationEffect(.degrees(-25)).offset(x: -12, y: -36).blur(radius: 1.5)
                Ellipse().fill(.white.opacity(0.85)).frame(width: 22, height: 9).rotationEffect(.degrees(-42)).offset(x: -39, y: -40).blur(radius: 1)
                Ellipse().fill(Color(red: 0.65, green: 0.81, blue: 0.98).opacity(0.7)).frame(width: 72, height: 10).offset(y: 52).blur(radius: 5)
                VStack(spacing: 7) {
                    Image(systemName: section.symbol).font(.system(size: 31, weight: .regular))
                    Text(section.rawValue)
                        .font(.system(size: section == .engine ? 12 : 14, weight: .medium))
                        .multilineTextAlignment(.center).lineSpacing(0)
                }.foregroundStyle(.white.opacity(0.95)).shadow(color: .black.opacity(0.7), radius: 3, y: 2).offset(y: 10)
                if busy { Circle().fill(.mint).frame(width: 7, height: 7).offset(x: 36, y: -36) }
            }.frame(width: 132, height: 132)
                .overlay(Circle().strokeBorder(.white.opacity(active || hovered ? 0.5 : 0), lineWidth: 2))
                .shadow(color: Color(red: 0.55, green: 0.7, blue: 0.9).opacity(active || hovered ? 0.4 : 0.18), radius: active || hovered ? 12 : 6, y: 3)
                .contentShape(Circle()).scaleEffect(hovered ? 1.035 : 1)
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .accessibilityLabel(section.rawValue)
    }
}

extension AppSection {
    var symbol: String {
        switch self { case .recovery: return "key.horizontal"; case .sessions: return "clock.arrow.circlepath"; case .engine: return "cpu"; case .about: return "info.circle" }
    }
}

struct SectionPopup: View {
    @ObservedObject var model: AppModel
    let section: AppSection
    var contentHeightChanged: (CGFloat) -> Void = { _ in }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol).foregroundStyle(.white.opacity(0.65))
                Text(section.rawValue).font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { model.closePopup() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 25, height: 25).background(.white.opacity(0.07), in: Circle()) }
                    .buttonStyle(.plain).accessibilityLabel("Close popup").keyboardShortcut(.escape, modifiers: [])
            }.padding(.horizontal, 20).frame(height: 58).background(WindowDragRegion())
            Divider().overlay(.white.opacity(0.07)).padding(.horizontal, 20)
            ScrollView {
                Group {
                    if let error = model.error {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Unable to continue", systemImage: "exclamationmark.circle").font(.headline).foregroundStyle(.orange)
                            Text(error).textSelection(.enabled)
                            HStack { Spacer(); Button("OK") { model.error = nil }.buttonStyle(.borderedProminent) }
                        }
                    } else if let job = model.deleteCandidate {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Delete session?").font(.headline)
                            Text(job.name).lineLimit(2)
                            Text("Saved progress and passwords will be removed. Your archive stays untouched.").foregroundStyle(.secondary)
                            HStack {
                                Button("Cancel") { model.deleteCandidate = nil }
                                Spacer()
                                Button("Delete", role: .destructive) { model.delete(job); model.deleteCandidate = nil }
                            }
                        }
                    } else {
                        switch section {
                        case .recovery: RecoveryContent(model: model)
                        case .sessions: SessionsContent(model: model)
                        case .engine: EngineView(model: model)
                        case .about: AboutContent(model: model)
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { proxy in Color.clear.preference(key: PopupHeightKey.self, value: proxy.size.height + 59) })
            }.scrollIndicators(.hidden)
        }
        .modifier(PopupSurface())
        .onPreferenceChange(PopupHeightKey.self, perform: contentHeightChanged)

    }
}

private struct PopupHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PopupSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 13)).foregroundStyle(.white.opacity(0.92))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(colors: [Color(red: 0.15, green: 0.18, blue: 0.22), Color(red: 0.065, green: 0.08, blue: 0.105)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 23))
            .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .tint(Color(red: 0.63, green: 0.80, blue: 1)).preferredColorScheme(.dark)
    }
}

private struct RecoveryContent: View {
    @ObservedObject var model: AppModel
    @State private var advanced = false
    @State private var dropTargeted = false
    @State private var showVariationInfo = false
    @State private var variationInfoHovered = false
    @State private var makingPattern = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let job = model.currentJob { detail(job) }
            else if makingPattern {
                PatternMakerView(mask: model.configuration.mask, apply: { mask in
                    model.configuration.mask = mask; makingPattern = false
                }, back: { makingPattern = false })
            } else { setup }
        }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { model.chooseArchive() } label: {
                HStack(spacing: 13) {
                    Image(systemName: "doc.zipper").font(.system(size: 27, weight: .light))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.configuration.archivePath.isEmpty ? "Choose or drop a file" : URL(fileURLWithPath: model.configuration.archivePath).lastPathComponent).font(.system(size: 14, weight: .medium)).lineLimit(2)
                        Text("ZIP · RAR · 7z · PDF").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "plus").foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(dropTargeted ? 0.13 : 0.04), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.23), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            }.buttonStyle(.plain).onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.selectArchive(url) } } }
                return true
            }
            CanvasChooser(label: "Search", selection: $model.configuration.strategy,
                          choices: RecoveryStrategy.allCases, title: { $0.title })
            strategyOptions
            DisclosureGroup("Processing", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 10) {
                    CanvasChooser(label: "Engine", selection: $model.configuration.backend,
                                  choices: ComputeBackend.allCases, title: { $0.title })
                    Stepper("CPU workers: \(model.configuration.workers)", value: $model.configuration.workers, in: 1...ProcessInfo.processInfo.activeProcessorCount)
                    Text("Automatic compares CPU and Metal on your file.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 9)
            }.foregroundStyle(.secondary)
            Button { model.start() } label: {
                Label(model.runtimeReady ? "Start recovery" : "Engine unavailable", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 7)
            }.buttonStyle(.borderedProminent).disabled(model.configuration.archivePath.isEmpty || model.benchmarking)
        }
    }
    @ViewBuilder private var strategyOptions: some View {
        switch model.configuration.strategy {
        case .recommended:
            Text("Uses John’s bundled password.lst. Add your own list with My wordlist.")
                .font(.caption).foregroundStyle(.secondary)
            variations
        case .wordlist:
            HStack {
                Text(model.configuration.wordlistPath.isEmpty ? "UTF-8 wordlist" : URL(fileURLWithPath: model.configuration.wordlistPath).lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer(); Button("Choose…") { model.chooseWordlist() }
            }
            if !model.wordlistSummary.isEmpty {
                Text(model.wordlistSummary).font(.caption).foregroundStyle(.secondary)
            }
            variations
        case .mask:
            TextField("Summer?d?d?d?d", text: $model.configuration.mask).textFieldStyle(.roundedBorder).accessibilityLabel("Password pattern")
            HStack(alignment: .top, spacing: 12) {
                if model.configuration.mask.utf8.allSatisfy({ $0 < 128 }) {
                    Text("?d digit   ?l lowercase   ?u uppercase\n?s symbol   ?a any character   ?? question mark").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Use a UTF-8 wordlist for accents or emoji.").font(.caption).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                Button { makingPattern = true } label: {
                    Label("Pattern maker", systemImage: "wand.and.stars").font(.caption)
                }.fixedSize().accessibilityLabel("Open pattern maker")
            }
        case .exhaustive:
            CanvasChooser(label: "Characters", selection: $model.configuration.characterSet,
                          choices: ["Digits", "Lowercase", "Alphanumeric", "ASCII"], title: { $0 })
            HStack {
                Stepper("Min: \(model.configuration.minimumLength)", value: $model.configuration.minimumLength, in: 1...model.configuration.exhaustiveLengthLimit)
                Spacer(minLength: 22)
                Stepper("Max: \(model.configuration.maximumLength)", value: $model.configuration.maximumLength, in: 1...model.configuration.exhaustiveLengthLimit)
            }
            Text(combinationExample).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var variations: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Toggle("Try common variations", isOn: $model.configuration.useRules)
                Button { showVariationInfo.toggle() } label: {
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("About common variations")
                    .accessibilityValue(showVariationInfo ? "expanded" : "collapsed")
                    .onHover { variationInfoHovered = $0 }
            }
            if showVariationInfo || variationInfoHovered {
                Text(variationExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }
    private let variationExplanation = "Tries changes such as bear → Bear, bear1 or bear!. Often thousands of candidates per word, so a full search can take thousands of times longer. The exact cost depends on the word and encryption."
    private var combinationExample: String {
        switch model.configuration.characterSet {
        case "Digits": return "Example: 2 digits tries every value from 00 to 99. Each extra digit makes 10× more combinations."
        case "Lowercase": return "Example: 2 lowercase letters tries aa, ab… zz (676 combinations)."
        case "Alphanumeric": return "Example: 2 characters tries pairs of letters and digits, such as a0, Z9 and 42."
        default: return "Example: 2 characters tries every printable pair, including letters, digits and symbols: a!, 9?, @@…"
        }
    }
    private func detail(_ job: RecoveryJob) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(job.name).font(.headline).lineLimit(2)
                Spacer()
                Button { model.newRecovery() } label: { Image(systemName: "plus") }.disabled(model.isBusy).accessibilityLabel("New recovery")
            }
            HStack {
                Label(job.phase.title, systemImage: job.phase == .recovered ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(job.phase == .recovered ? .mint : .white)
                Spacer()
                Text(job.engine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.isBusy { ProgressView().progressViewStyle(.linear) }
            if job.phase == .preparing || job.phase == .failed || job.phase == .partial || job.phase == .exhausted { Text(job.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = Int(job.elapsedSeconds + (model.activeID == job.id ? max(0, context.date.timeIntervalSince(job.updatedAt)) : 0))
                    Label(String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60), systemImage: "clock").monospacedDigit()
                }
                Spacer()
                if model.isBusy { Text(model.speedText).lineLimit(1) }
                else if job.processedCandidates > 0 { Text("\(job.processedCandidates.formatted()) checked") }
            }.font(.caption).foregroundStyle(.secondary)
            if model.isBusy, !model.etaText.isEmpty { Text(model.etaText).font(.caption).foregroundStyle(.secondary) }
            if model.isBusy {
                Button(model.isPausing ? "Saving…" : "Pause & save", systemImage: "pause.fill") { model.pause() }.disabled(model.isPausing)
            } else if job.phase.resumable {
                Button("Resume", systemImage: "play.fill") { model.start() }.buttonStyle(.borderedProminent)
            } else if job.phase != .recovered {
                Button("Adjust search", systemImage: "slider.horizontal.3") { model.newRecovery() }
            }
            if job.phase == .recovered || job.phase == .partial {
                panel {
                    VStack(alignment: .leading, spacing: 13) {
                        Text(model.reveal ? model.passwords.map { $0.isEmpty ? "(empty password)" : $0 }.joined(separator: "\n") : "••••••••••••")
                            .font(.system(size: 20, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button(model.reveal ? "Hide" : "Show", systemImage: model.reveal ? "eye.slash" : "eye") { model.reveal.toggle() }
                            Button("Copy") { model.copyPassword() }
                            Button("Export…") { model.exportPassword() }
                        }
                        Button("Show archive in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.configuration.archivePath)]) }.font(.caption)
                    }
                }
            }
            DisclosureGroup {
                Text(job.status).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                Text(model.log.isEmpty ? "No engine output." : model.log).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            } label: {
                HStack {
                    Text("Details")
                    Spacer(minLength: 12)
                    if model.activeID == job.id {
                        Text(model.currentCandidate ?? "Waiting for candidates…")
                            .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.white.opacity(0.85))
                            .accessibilityHint("A sample from the current batch. Samples indicates multiple CPU candidates, not one longer password.")
                            .accessibilityLabel("Current candidate: " + (model.currentCandidate ?? "Waiting"))
                    }
                }
            }.foregroundStyle(.secondary)
        }
    }
}

private struct SessionsContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            if model.jobs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text("No saved sessions").foregroundStyle(.secondary)
                    Button("New recovery") { model.newRecovery() }
                }.frame(maxWidth: .infinity).padding(.vertical, 55)
            }
            ForEach(model.jobs) { job in
                panel {
                    HStack(spacing: 10) {
                        Image(systemName: job.phase == .recovered ? "checkmark.circle.fill" : "clock.fill")
                            .font(.system(size: 20)).foregroundStyle(job.phase == .recovered ? .green : .orange)
                            .accessibilityLabel(job.phase == .recovered ? "Complete" : "Pending or unfinished")
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("\(job.phase.title) · \(job.createdAt.formatted(.dateTime.month(.abbreviated).day().year().locale(Locale(identifier: "en_US"))))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button { model.select(job) } label: { Image(systemName: "arrow.up.right") }.disabled(model.isBusy && model.activeID != job.id).accessibilityLabel("Open \(job.name)")
                        Button { model.deleteCandidate = job } label: { Image(systemName: "trash") }.disabled(model.activeID == job.id).accessibilityLabel("Delete \(job.name)")
                    }
                }
            }
        }
    }
}

struct ConsentView: View {
    let accept: () -> Void
    @State private var checked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Welcome to ZipRipper", systemImage: "key.horizontal").font(.system(size: 20, weight: .semibold))
            Text("Recover passwords only for files you own or have permission to access. Your files stay on your Mac. Recovery is not guaranteed.").fixedSize(horizontal: false, vertical: true)
            Toggle("I own these files or have permission.", isOn: $checked)
            HStack { Button("Quit") { NSApp.terminate(nil) }; Spacer(); Button("Continue", action: accept).buttonStyle(.borderedProminent).disabled(!checked) }
        }.padding(25).modifier(PopupSurface())
    }
}

func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content().padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.08), lineWidth: 1))
}
