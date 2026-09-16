import AppKit
import SwiftUI
import Combine

private final class MascotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
private final class SectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { closeAction?() }
    var closeAction: (() -> Void)?
}

@MainActor final class MascotWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let window: MascotWindow
    private var popup: SectionPanel?
    private var subscriptions = Set<AnyCancellable>()
    private var showingSection: AppSection?
    private var consentPending: Bool { !UserDefaults.standard.bool(forKey: "authorizedUseAcceptedV1") }

    init(model: AppModel) {
        self.model = model
        window = MascotWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
                              styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "ZipRipper"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.delegate = self
        recordWindowState("configured")
        let view = MainView(model: model, minimize: { [weak self] in self?.minimize() })
        let canvas = ScaledCanvas(content: view, logicalSize: NSSize(width: 600, height: 620), scale: model.guiScale)
        window.setContentSize(NSSize(width: 600 * model.guiScale, height: 620 * model.guiScale))
        window.contentView = canvas
        window.center()
        model.$guiScale.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] scale in self?.applyScale(scale) }.store(in: &subscriptions)
        model.$popupVisible.combineLatest(model.$section)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible, section in
                guard let self else { return }
                guard !self.window.isMiniaturized else { return }
                if self.consentPending { self.presentConsent() }
                else if visible { self.present(section) }
                else { self.dismissPopup() }
            }.store(in: &subscriptions)
        model.$error.compactMap { $0 }.receive(on: DispatchQueue.main)
            .sink { [weak model] _ in
                guard let model, !model.popupVisible else { return }
                model.popupVisible = true
            }.store(in: &subscriptions)
    }
    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        restorePopup()
    }
    private func restorePopup() {
        if consentPending { presentConsent() }
        else { model.offerBenchmark(); if model.popupVisible { present(model.section) } }
    }
    private func minimize() { dismissPopup(); model.popupVisible = false; window.miniaturize(nil) }
    private func makePanel(size: NSSize) -> SectionPanel {
        let scaled = NSSize(width: size.width * model.guiScale, height: size.height * model.guiScale)
        let panel = SectionPanel(contentRect: NSRect(origin: .zero, size: scaled), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.closeAction = { [weak self] in self?.model.closePopup() }
        return panel
    }
    private func install<Content: View>(_ content: Content, in panel: NSPanel) {
        let logical = NSSize(width: panel.frame.width / model.guiScale, height: panel.frame.height / model.guiScale)
        panel.contentView = ScaledCanvas(content: content, logicalSize: logical, scale: model.guiScale)
    }
    private func applyScale(_ scale: Double) {
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        (window.contentView as? ScaledCanvas)?.scale = scale
        window.setFrame(NSRect(x: center.x - 300 * scale, y: center.y - 310 * scale,
                               width: 600 * scale, height: 620 * scale), display: true)
        if let panel = popup, let canvas = panel.contentView as? ScaledCanvas {
            let logical = canvas.logicalSize
            canvas.scale = scale
            panel.setContentSize(NSSize(width: logical.width * scale, height: logical.height * scale))
        }
        positionPopup()
        recordWindowState("scaled")
    }

    private func present(_ section: AppSection) {
        if showingSection == section, let popup { popup.makeKeyAndOrderFront(nil); return }
        dismissPopup()
        showingSection = section
        let height: CGFloat
        switch section { case .recovery: height = 492; case .sessions: height = 392; case .engine: height = 420; case .about: height = 300 }
        let panel = makePanel(size: NSSize(width: 420, height: height))
        panel.title = section.rawValue
        install(SectionPopup(model: model, section: section, contentHeightChanged: { [weak self, weak panel] height in
            guard let self, let panel, height > 0 else { return }
            let scale = self.model.guiScale
            let limit = min(520, ((self.window.screen?.visibleFrame.height ?? 800) - 50) / scale)
            let newHeight = max(212, min(floor(limit / 4) * 4, ceil(height / 4) * 4)) * scale
            guard abs(panel.frame.height - newHeight) > 1 else { return }
            var frame = panel.frame
            frame.origin.y += frame.height - newHeight
            frame.size.height = newHeight
            panel.setFrame(frame, display: true)
            self.positionPopup()
        }), in: panel)
        popup = panel
        positionPopup()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.recordWindowState("popup") }
    }
    private func presentConsent() {
        guard popup?.title != "Welcome" else { return }
        dismissPopup()
        let panel = makePanel(size: NSSize(width: 412, height: 268))
        panel.title = "Welcome"
        panel.closeAction = nil
        install(ConsentView {
            UserDefaults.standard.set(true, forKey: "authorizedUseAcceptedV1")
            self.dismissPopup()
            self.model.offerBenchmark()
            if self.model.popupVisible { self.present(self.model.section) }
        }, in: panel)
        popup = panel
        positionPopup()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.recordWindowState("popup") }
    }
    private func positionPopup() {
        guard let panel = popup else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let size = panel.frame.size
        var x = window.frame.maxX - 38 * model.guiScale
        if x + size.width > screen.maxX - 14 { x = window.frame.minX - size.width + 38 * model.guiScale }
        x = max(screen.minX + 14, min(x, screen.maxX - size.width - 14))
        let y = max(screen.minY + 14, min(window.frame.midY - size.height / 2, screen.maxY - size.height - 14))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    private func dismissPopup() {
        if let popup { window.removeChildWindow(popup); popup.orderOut(nil) }
        popup = nil; showingSection = nil
    }
    // Opt-in local UI-test evidence; records window geometry only, never user data.
    private func recordWindowState(_ event: String) {
        guard let path = ProcessInfo.processInfo.environment["ZIPRIPPER_UI_DIAGNOSTICS"] else { return }
        let state: [String: Any] = ["event": event, "opaque": window.isOpaque,
            "backgroundAlpha": window.backgroundColor.alphaComponent,
            "miniaturized": window.isMiniaturized, "visible": window.isVisible,
            "titled": window.styleMask.contains(.titled), "resizable": window.styleMask.contains(.resizable),
            "x": window.frame.minX, "y": window.frame.minY,
            "width": window.frame.width, "height": window.frame.height,
            "scale": model.guiScale,
            "logicalWidth": (window.contentView as? ScaledCanvas)?.logicalSize.width ?? 0,
            "logicalHeight": (window.contentView as? ScaledCanvas)?.logicalSize.height ?? 0,
            "popupLogicalWidth": (popup?.contentView as? ScaledCanvas)?.logicalSize.width ?? 0,
            "popupLogicalHeight": (popup?.contentView as? ScaledCanvas)?.logicalSize.height ?? 0,
            "popupWidth": popup?.frame.width ?? 0, "popupHeight": popup?.frame.height ?? 0]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([10]))
    }
    func windowDidMove(_ notification: Notification) { positionPopup(); recordWindowState("moved") }
    func windowDidMiniaturize(_ notification: Notification) {
        dismissPopup(); model.popupVisible = false; recordWindowState("minimized")
    }
    func windowDidDeminiaturize(_ notification: Notification) { restorePopup(); recordWindowState("restored") }
}

/// Dragging belongs to the artwork; buttons and popup controls keep normal clicks.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) { }
    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// Keep AppKit in physical window coordinates. SwiftUI owns the transform so
/// its event graph applies the same scale to drawing and physical mouse input.
private final class CanvasGeometry: ObservableObject {
    @Published var size: NSSize
    @Published var scale: CGFloat
    init(size: NSSize, scale: CGFloat) { self.size = size; self.scale = scale }
}

private struct ScaledContent<Content: View>: View {
    let content: Content
    @ObservedObject var geometry: CanvasGeometry
    var body: some View {
        content.frame(width: geometry.size.width, height: geometry.size.height)
            .scaleEffect(geometry.scale, anchor: .topLeading)
            .frame(width: geometry.size.width * geometry.scale,
                   height: geometry.size.height * geometry.scale, alignment: .topLeading)
    }
}

private final class ScaledCanvas: NSView {
    var scale: CGFloat
    var logicalSize: NSSize { geometry.size }
    private let hosted: NSView
    private let geometry: CanvasGeometry
    init<Content: View>(content: Content, logicalSize: NSSize, scale: CGFloat) {
        self.scale = scale
        let geometry = CanvasGeometry(size: logicalSize, scale: scale)
        self.geometry = geometry
        let hosting = NSHostingView(rootView: ScaledContent(content: content, geometry: geometry))
        hosting.sizingOptions = []
        hosted = hosting
        super.init(frame: NSRect(x: 0, y: 0, width: logicalSize.width * scale, height: logicalSize.height * scale))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hosted)
        resizeCanvas()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeCanvas()
    }
    private func resizeCanvas() {
        // No ancestor bounds scaling: NSHostingView must receive unscaled
        // window events and let SwiftUI transform them into content space.
        bounds = NSRect(origin: .zero, size: frame.size)
        hosted.frame = bounds
        geometry.size = NSSize(width: frame.width / scale, height: frame.height / scale)
        geometry.scale = scale
    }
}
