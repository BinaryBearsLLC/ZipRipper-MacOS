import SwiftUI

struct EngineView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.showBenchmark {
                Button { model.showBenchmark = false } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.secondary)
                BenchmarkView(model: model)
            } else {
                HStack {
                    Label(model.runtimeReady ? "Ready to use" : "Engine missing", systemImage: model.runtimeReady ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(model.runtimeReady ? .mint : .orange)
                    Spacer()
                    Text("v" + AppModel.appVersion).font(.caption).foregroundStyle(.secondary)
                }
                Text(model.gpuName ?? "CPU only").font(.headline)
                Text("\(ProcessInfo.processInfo.activeProcessorCount) CPU workers available").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("GUI Size")
                    Spacer()
                    Picker("GUI Size", selection: $model.guiScale) { Text("1x").tag(1.0); Text("0.75x").tag(0.75) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
                Divider()
                if model.benchmarkSuggested {
                    Text("Benchmark this Mac?").font(.headline)
                    Text("Recommended once. Saves local performance estimates.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Run benchmark") { model.startBenchmark() }.buttonStyle(.borderedProminent).disabled(model.isBusy)
                        Button("Later") { model.deferBenchmark() }
                    }
                } else {
                    Button { model.showBenchmark = true } label: {
                        HStack { Label("Benchmark", systemImage: "speedometer"); Spacer(); Text(model.benchmarkStatus).font(.caption); Image(systemName: "chevron.right") }
                    }.buttonStyle(.plain)
                }
                DisclosureGroup("Versions") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(versions, id: \.0) { name, version in
                            HStack(alignment: .top) {
                                Text(name).frame(width: 82, alignment: .leading)
                                Text(version).textSelection(.enabled).font(.system(size: 10, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("Metal kernels · ZipRipper " + AppModel.appVersion)

                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                }
            }
        }
    }
    private var versions: [(String, String)] {
        guard let runtime = model.runtimeURL, let data = try? Data(contentsOf: runtime.appendingPathComponent("dependency-manifest.json")), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = manifest["dependencies"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let version = row["version"] as? String else { return nil }
            return (id == "john" ? "John Jumbo" : id, version)
        }
    }
}
