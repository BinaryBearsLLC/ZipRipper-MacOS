import SwiftUI
import ZipRipperCore

struct AboutContent: View {
    @ObservedObject var model: AppModel
    @State private var page: Page = .about
    private enum Page { case about, wordlists, licenses }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if page != .about {
                Button { page = .about } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            switch page {
            case .about:
                HStack {
                    Text("ZipRipper").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.5.3").foregroundStyle(.secondary)
                }
                Text("Only recover files you own or have permission to access. Recovery is not guaranteed.")
                HStack(spacing: 16) {
                    Link("Original project", destination: URL(string: "https://github.com/illsk1lls/ZipRipper")!)
                    Link("John the Ripper", destination: URL(string: "https://github.com/openwall/john")!)
                }.font(.caption)
                VStack(spacing: 8) {
                    navigation("Need a wordlist?", icon: "text.badge.plus", to: .wordlists)
                    navigation("Licenses & notices", icon: "doc.text", to: .licenses)
                }
                Text("BinaryBears · Independent macOS port").font(.caption).foregroundStyle(.secondary)
            case .wordlists: WordlistResourcesView()
            case .licenses: NoticesView()
            }
        }
    }
    private func navigation(_ title: String, icon: String, to destination: Page) -> some View {
        Button { page = destination } label: {
            HStack { Label(title, systemImage: icon); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                .padding(11).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

private struct WordlistResourcesView: View {
    @State private var generate = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Need a wordlist?").font(.headline)
            Picker("Wordlist source", selection: $generate) {
                Text("Download a list").tag(false)
                Text("Make my own").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if generate {
                Text("Build a custom list from words and variations you choose.").foregroundStyle(.secondary)
                Link(destination: URL(string: "https://github.com/sc0tfree/mentalist")!) { Label("Open Mentalist on GitHub", systemImage: "arrow.up.right.square") }
            } else {
                Text("Browse wordlists, then choose an extracted UTF-8 text file in Recovery.").foregroundStyle(.secondary)
                Link(destination: URL(string: "https://github.com/cyclone-github/wordlist")!) { Label("Cyclone wordlists", systemImage: "arrow.up.right.square") }
                Link(destination: URL(string: "https://github.com/danielmiessler/SecLists/tree/master/Passwords")!) { Label("SecLists Passwords", systemImage: "arrow.up.right.square") }
                Link(destination: URL(string: "https://weakpass.com/")!) { Label("Weakpass", systemImage: "arrow.up.right.square") }
            }
            Text("External websites. None of these projects are affiliated with BinaryBears.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct NoticesView: View {
    @State private var selection = "ZipRipper"
    private static let notices: [(String, String)] = {
        var values = [("ZipRipper", "ZipRipper for macOS — BinaryBears.\nFor authorized local password recovery only.\n\nIndependent macOS port inspired by illsk1lls/ZipRipper. CPU recovery uses Openwall John the Ripper Jumbo. Third-party components retain their own licenses.")]
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("runtime/licenses") else { return values }
        let files = ["john/LICENSE", "john/COPYING", "john/CREDITS", "john/CREDITS-jumbo", "john/SIPcrack-LICENSE", "OpenSSL-LICENSE.txt", "Perl-Artistic.txt", "Perl-Copying.txt", "xz-COPYING.txt", "xz-COPYING.0BSD.txt", "Compress-Raw-Lzma-README.txt", "unrar-header.txt"]
        for file in files {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(file)) {
                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
                values.append((file, text))
            }
        }
        return values
    }()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Licenses & notices").font(.headline)
            CanvasChooser(label: "Component", selection: $selection,
                          choices: Self.notices.map(\.0), title: { $0 })
            ScrollView {
                Text(Self.notices.first(where: { $0.0 == selection })?.1 ?? "")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.frame(height: 260).background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct BenchmarkView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Benchmark").font(.headline)
            Text("CPU and Metal + verification. Results are saved on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.benchmarking {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.cancelBenchmark() }
                } else {
                    Button(model.benchmarkResults.isEmpty ? "Run benchmark" : "Run again") { model.startBenchmark() }
                        .buttonStyle(.borderedProminent).disabled(model.isBusy)
                }
                Spacer()
                if !model.benchmarkStatus.isEmpty { Text(model.benchmarkStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            if model.isBusy { Text("Available after recovery finishes.").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.benchmarkResults) { result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(result.name).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(result.passwordsPerSecond.map {
                            "\($0 < 1 ? $0.formatted(.number.precision(.fractionLength(1))) : Int($0).formatted()) p/s"
                        } ?? "—").monospacedDigit()
                    }
                    HStack { Text(result.backend); Spacer(); Text(result.detail == "Measuring…" && !model.benchmarking ? "Stopped" : result.detail).lineLimit(2).multilineTextAlignment(.trailing) }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }
}
