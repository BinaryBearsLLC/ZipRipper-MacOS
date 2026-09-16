import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var shell: MascotWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use the same mascot for the running process and the bundle's Finder icon.
        if let icon = Bundle.main.url(forResource: "MascotIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: icon) { NSApp.applicationIconImage = image }
        let shell = MascotWindowController(model: model)
        self.shell = shell
        shell.show()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shell?.show(); return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { model.selectArchive(url); shell?.show() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isBusy || model.benchmarking else { return .terminateNow }
        Task { @MainActor in await model.prepareToQuit(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main struct ZipRipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands { RecoveryCommands(model: delegate.model) }
    }
}

private struct RecoveryCommands: Commands {
    @ObservedObject var model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .appSettings) { }
        CommandGroup(replacing: .newItem) {
            Button("Open Archive…") { model.chooseArchive() }.keyboardShortcut("o").disabled(model.isBusy)
            Button("New Recovery") { model.newRecovery() }.keyboardShortcut("n").disabled(model.isBusy)
        }
        CommandMenu("Recovery") {
            Button("Start / Resume") { model.start() }.keyboardShortcut(.return, modifiers: .command).disabled(model.isBusy || model.benchmarking)
            Button("Pause and Save") { model.pause() }.keyboardShortcut(".", modifiers: .command).disabled(!model.isBusy)
            Divider()
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.rawValue) { model.openSection(section) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}
