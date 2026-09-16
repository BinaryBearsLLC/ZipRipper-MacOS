import SwiftUI
import ZipRipperCore

struct PatternMakerView: View {
    let apply: (String) -> Void
    let back: () -> Void
    @State private var pattern: PasswordPattern
    @State private var remembered = ""
    @State private var importError: String?

    init(mask: String, apply: @escaping (String) -> Void, back: @escaping () -> Void) {
        self.apply = apply; self.back = back
        do { _pattern = State(initialValue: try PasswordPattern(mask: mask)) }
        catch { _pattern = State(initialValue: PasswordPattern()); _importError = State(initialValue: error.localizedDescription) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button(action: back) { Label("Recovery", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Text("Pattern maker").font(.headline)
            }
            if let importError {
                Text(importError).font(.caption).foregroundStyle(.secondary)
                Button("Start a new pattern") { self.importError = nil }
            } else {
                HStack(spacing: 8) {
                    TextField("Text you remember, e.g. Summer", text: $remembered)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Remembered text")
                        .onSubmit(addText)
                    Button("Add", action: addText).disabled(remembered.isEmpty || !PasswordPattern.isPrintable(remembered))
                }
                if !PasswordPattern.isPrintable(remembered) {
                    Text("Use a UTF-8 wordlist for accents or emoji.").font(.caption).foregroundStyle(.orange)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(PasswordPattern.Kind.allCases.filter { $0 != .text }, id: \.self) { kind in
                        Button {
                            // Commit pending remembered text first; preserve its position.
                            addText()
                            pattern.parts.append(.init(kind: kind))
                        } label: {
                            VStack(spacing: 2) {
                                Text(kind.title).font(.system(size: 11, weight: .medium))
                                Text(kind.token).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).frame(height: 33)
                                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).accessibilityLabel("Add " + kind.title.lowercased())
                            .disabled(!PasswordPattern.isPrintable(remembered))
                    }
                }
                if pattern.parts.isEmpty {
                    Text("Add the parts in the order you remember.").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach($pattern.parts) { $part in
                                HStack(spacing: 8) {
                                    if part.kind == .text {
                                        TextField("Known text", text: $part.text).textFieldStyle(.roundedBorder)
                                            .accessibilityLabel("Known text block")
                                    } else {
                                        Text(part.kind.title).font(.system(size: 12))
                                        Spacer(minLength: 0)
                                        Stepper("\(part.count)", value: $part.count, in: 1...32)
                                            .fixedSize().accessibilityLabel(part.kind.title + " count")
                                    }
                                    Button { let id = part.id; pattern.parts.removeAll { $0.id == id } } label: {
                                        Image(systemName: "xmark").font(.system(size: 10)).frame(width: 23, height: 23).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("Remove " + part.kind.title.lowercased())
                                }.padding(.horizontal, 8).frame(height: 32)
                                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }.frame(height: min(106, CGFloat(pattern.parts.count * 37 - 5)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.mask.isEmpty ? "Your pattern" : preview.mask)
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                        .accessibilityLabel("Pattern preview: " + preview.mask)
                    PatternExampleView(pattern: preview)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Clear") { pattern.parts = []; remembered = "" }.disabled(pattern.parts.isEmpty && remembered.isEmpty)
                    Spacer()
                    Button("Use pattern") { apply(preview.mask) }.buttonStyle(.borderedProminent).disabled(!preview.isValid)
                }
                if preview.length > 319 { Text("Keep the pattern under 320 characters.").font(.caption).foregroundStyle(.orange) }
            }
        }
    }
    private var preview: PasswordPattern {
        var result = pattern
        if !remembered.isEmpty { result.parts.append(.init(kind: .text, text: remembered)) }
        return result
    }
    private func addText() {
        guard !remembered.isEmpty, PasswordPattern.isPrintable(remembered) else { return }
        pattern.parts.append(.init(kind: .text, text: remembered)); remembered = ""
    }
}

/// Only this label refreshes: one sample every two seconds, no engine or frame timer.
private struct PatternExampleView: View {
    let pattern: PasswordPattern
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = NSApp.isActive
    @State private var step = 0

    private var animationKey: String? {
        active && !reduceMotion && pattern.isValid && pattern.parts.contains { $0.kind != .text }
            ? pattern.mask : nil
    }

    var body: some View {
        Text("Example: " + (pattern.parts.isEmpty ? "—" : pattern.example(at: step)))
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
            .task(id: animationKey) {
                step = 0
                guard animationKey != nil else { return }
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        try Task.checkCancellation()
                        step = (step + 1) % 780
                    }
                } catch { /* View closed, pattern changed or app became inactive. */ }
            }
    }
}
