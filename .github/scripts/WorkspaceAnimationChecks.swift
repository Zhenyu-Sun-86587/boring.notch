// Actual SwiftUI/AppKit display-cycle checks for the shared workspace shell modifier. Every
// fixture panel is pinned outside all physical screens and cannot become key or main.
import AppKit
import SwiftUI

private struct WorkspaceAnimationFailure: Error, CustomStringConvertible { let description: String }
@MainActor private func requireWorkspace(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw WorkspaceAnimationFailure(description: message) }
}

@MainActor final class BoringNotchSkyLightWindow: NSPanel {
    var allowsIslandKeyboard = false
    var isIslandScreenLocked = false
    var wantsKeyForTextInput = false
    var isIslandKeyboardHandoffActive = false
    var islandKeyboardOwner: UUID?
    var frameWrites = 0
    var automaticFrames = 0
    var focusRequests = 0
    let physicalAnchor: CGPoint
    override var screen: NSScreen? { NSScreen.main }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func makeKey() { focusRequests += 1 }
    override func makeMain() { focusRequests += 1 }
    override func makeKeyAndOrderFront(_ sender: Any?) { focusRequests += 1 }
    func releaseIslandKeyboard() {}
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    init() {
        let maxX = NSScreen.screens.map { $0.frame.maxX }.max() ?? 0
        let maxY = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        physicalAnchor = CGPoint(x: max(25_000, maxX + 5_000), y: max(25_000, maxY + 5_000))
        super.init(contentRect: NSRect(x: physicalAnchor.x - 320, y: physicalAnchor.y - 210, width: 640, height: 210),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        hasShadow = false
        title = "Boring Notch workspace animation isolated offscreen fixture"
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard frameRect.width.isFinite, frameRect.height.isFinite, frameRect.width > 0, frameRect.height > 0 else { return }
        let stack = Thread.callStackSymbols
        if stack.contains(where: { $0.contains("updateAnimatedWindowSize") }) { automaticFrames += 1 }
        let pinned = NSRect(x: physicalAnchor.x - frameRect.width / 2, y: physicalAnchor.y - frameRect.height,
                            width: frameRect.width, height: frameRect.height)
        // The real bridge compares real screen origins. This fixture pins those requests offscreen;
        // ignore an already-applied pinned frame so that translation cannot create a fake loop.
        let current = frame
        guard abs(current.minX - pinned.minX) > 0.5 || abs(current.minY - pinned.minY) > 0.5
            || abs(current.width - pinned.width) > 0.5 || abs(current.height - pinned.height) > 0.5 else { return }
        frameWrites += 1
        super.setFrame(pinned, display: flag)
    }
    func assertOffscreen() throws {
        try requireWorkspace(!NSScreen.screens.contains(where: { frame.intersects($0.frame) }), "Fixture approached a physical screen")
        try requireWorkspace(frame.minX >= 20_000 && frame.minY >= 20_000, "Fixture left its guarded offscreen anchor")
        try requireWorkspace(!isKeyWindow && !isMainWindow && focusRequests == 0, "Fixture attempted keyboard/main-window activation")
    }
}

extension NSScreen { static func screen(withUUID _: String) -> NSScreen? { main } }

@MainActor private final class WorkspaceMetrics {
    struct Sample {
        let phase: String
        let size: CGSize
        let canvasSize: CGSize
        let centerError: CGFloat
        let topError: CGFloat
        let contentTopError: CGFloat
    }
    weak var window: BoringNotchSkyLightWindow?
    var phase = "closed"
    var samples: [Sample] = []
    var preferenceSamples: [Sample] = []
    weak var shellView: NSView?
    weak var contentView: NSView?
    var requests: [(phase: String, size: CGSize)] = []
    var layouts = 0
    var displayCycleLayouts = 0
    func record(frames: [String: CGRect]) {
        guard let window, let shell = frames["shell"], let content = frames["content"] else { return }
        let center = window.frame.minX + shell.midX
        let top = window.frame.maxY - shell.minY
        preferenceSamples.append(Sample(phase: phase, size: shell.size, canvasSize: window.frame.size,
            centerError: abs(center - window.physicalAnchor.x), topError: abs(top - window.physicalAnchor.y),
            contentTopError: abs(content.minY - shell.minY)))
    }
    func recordNativeFrames() {
        guard let window else { return }
        func marker(named name: String, in view: NSView) -> NSView? {
            if let marker = view as? FrameReader.Marker, marker.name == name { return marker }
            for child in view.subviews {
                if let match = marker(named: name, in: child) { return match }
            }
            return nil
        }
        if shellView?.window !== window, let root = window.contentView { shellView = marker(named: "shell", in: root) }
        if contentView?.window !== window, let root = window.contentView { contentView = marker(named: "content", in: root) }
        guard let shellView, let contentView,
              shellView.window === window, contentView.window === window else { return }
        let shell = window.convertToScreen(shellView.convert(shellView.bounds, to: nil))
        let content = window.convertToScreen(contentView.convert(contentView.bounds, to: nil))
        samples.append(Sample(phase: phase, size: shell.size, canvasSize: window.frame.size,
            centerError: abs(shell.midX - window.physicalAnchor.x), topError: abs(shell.maxY - window.physicalAnchor.y),
            contentTopError: abs(content.maxY - shell.maxY)))
    }
    func layout() {
        layouts += 1
        if Thread.callStackSymbols.contains(where: { $0.contains("NSDisplayCycle") || $0.contains("NSWindowGetDisplayCycle") }) {
            displayCycleLayouts += 1
        }
    }
}

private struct WorkspaceFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private struct FrameReader: NSViewRepresentable {
    let name: String
    let metrics: WorkspaceMetrics
    final class Marker: NSView { var name = "" }
    func makeNSView(context: Context) -> Marker {
        let view = Marker(frame: .zero)
        view.name = name
        return view
    }
    func updateNSView(_ view: Marker, context: Context) {
        if name == "shell" { metrics.shellView = view } else { metrics.contentView = view }
    }
}

private struct WorkspaceRequestProbe: NSViewRepresentable {
    let size: CGSize
    let metrics: WorkspaceMetrics
    final class Probe: NSView {
        weak var metrics: WorkspaceMetrics?
        var previousSize: CGSize?
        override func layout() { metrics?.layout(); super.layout() }
    }
    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateNSView(_ view: Probe, context: Context) {
        view.metrics = metrics
        metrics.requests.append((phase: metrics.phase, size: size))
        if view.previousSize != size { view.previousSize = size; view.needsLayout = true }
    }
}

@MainActor private final class WorkspaceState: ObservableObject {
    @Published var target = CGSize(width: 193, height: 38)
    @Published var envelope = CGSize(width: 640, height: 210)
    @Published var layout = CGSize(width: 640, height: 420)
    @Published var enabled = true
    @Published var tab = 2
    @Published var rows = 20
}

@MainActor private struct WorkspaceRoot: View {
    @ObservedObject var state: WorkspaceState
    let metrics: WorkspaceMetrics
    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 8) {
                HStack { Text("Home   Shelf   Hermes   Clipboard"); Spacer() }.frame(height: 38)
                Group {
                    if state.tab == 2 {
                        VStack {
                            ScrollView {
                                LazyVStack(alignment: .leading) {
                                    ForEach(0..<state.rows, id: \.self) { index in
                                        Text("Answer \(index) " + String(repeating: "formula/text ", count: 12))
                                    }
                                }
                            }
                            TextField("Prompt fixture", text: .constant(""))
                        }
                    } else if state.tab == 3 {
                        VStack {
                            TextField("Search fixture", text: .constant(""))
                            ScrollView {
                                LazyVStack {
                                    ForEach(0..<state.rows, id: \.self) { index in
                                        HStack { Image(systemName: "photo"); Text("Clipboard \(index)"); Spacer() }.frame(height: 48)
                                    }
                                }
                            }
                        }
                    } else {
                        VStack { Text(state.tab == 0 ? "Home fixture" : "Shelf fixture"); Spacer() }
                    }
                }
                .transition(.opacity)
            }
            .frame(width: state.layout.width, height: state.layout.height, alignment: .top)
            .background(FrameReader(name: "content", metrics: metrics))
            .modifier(WorkspaceSurfaceFrame(presentationSize: state.target, contentSize: state.layout,
                enabled: state.enabled, nativeWindowSize: CGSize(width: 640, height: 210),
                windowEnvelopeSize: state.envelope, shadowPadding: 20) { size in
                    IslandWindowBridge(size: size, wantsKeyboard: false, keyboardActivation: "fixture")
                        .background(WorkspaceRequestProbe(size: size, metrics: metrics))
                })
            .background(Color.black)
            .background(FrameReader(name: "shell", metrics: metrics))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "workspace-canvas")
        .onPreferenceChange(WorkspaceFrames.self) { frames in metrics.record(frames: frames) }
    }
}

@MainActor private func animateWorkspace(_ state: WorkspaceState, metrics: WorkspaceMetrics, phase: String,
                                        size: CGSize, layout: CGSize? = nil, tab: Int? = nil) {
    metrics.phase = phase
    if let layout { state.layout = layout }
    if let tab { state.tab = tab }
    state.envelope = WorkspaceSurfaceGeometry.preparedEnvelope(current: state.envelope, target: size,
        native: CGSize(width: 640, height: 210), shadowPadding: 20)
    withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { state.target = size }
}
@MainActor private func workspaceTick(_ window: BoringNotchSkyLightWindow, metrics: WorkspaceMetrics, count: Int = 1) async throws {
    for _ in 0..<count {
        try await Task.sleep(for: .milliseconds(16))
        try window.assertOffscreen()
        // Sample actual attached NSViews after the AppKit display cycle has serviced this tick.
        // SwiftUI preference callbacks can otherwise describe an earlier proposal than NSWindow.frame.
        metrics.recordNativeFrames()
    }
}

@MainActor private func runWorkspaceChecks() async throws {
    let window = BoringNotchSkyLightWindow()
    let metrics = WorkspaceMetrics(); metrics.window = window
    let state = WorkspaceState()
    let container = makeNotchHostingView(rootView: WorkspaceRoot(state: state, metrics: metrics))
    window.contentView = container
    let updateObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { _ in
        MainActor.assumeIsolated { metrics.recordNativeFrames() }
    }
    defer { NotificationCenter.default.removeObserver(updateObserver); window.orderOut(nil); window.contentView = nil; window.close() }
    try window.assertOffscreen()
    window.orderFrontRegardless()
    try window.assertOffscreen()
    try requireWorkspace(window.isVisible, "Fixture was not ordered, so NSDisplayCycle evidence would be inconclusive")
    try await workspaceTick(window, metrics: metrics, count: 16)

    animateWorkspace(state, metrics: metrics, phase: "open-hermes", size: CGSize(width: 640, height: 420))
    try await workspaceTick(window, metrics: metrics, count: 48)
    let opening = metrics.samples.filter { $0.phase == "open-hermes" }.map(\.size.height)
    try requireWorkspace(opening.filter { $0 > 75 && $0 < 425 }.count >= 4,
        "Visible shell jumped to final height instead of following presentation animation")
    try requireWorkspace(abs(window.frame.height - 472) <= 1, "Expanded window did not keep its prepared envelope")

    animateWorkspace(state, metrics: metrics, phase: "clipboard-tab", size: CGSize(width: 640, height: 420),
                     layout: CGSize(width: 640, height: 420), tab: 3)
    try await workspaceTick(window, metrics: metrics, count: 12)
    animateWorkspace(state, metrics: metrics, phase: "wide", size: CGSize(width: 920, height: 520),
                     layout: CGSize(width: 920, height: 520), tab: 2)
    try await workspaceTick(window, metrics: metrics, count: 40)
    try requireWorkspace(abs(window.frame.width - 952) <= 1 && abs(window.frame.height - 572) <= 1,
        "Wide shell/window geometry diverged")

    animateWorkspace(state, metrics: metrics, phase: "close-reverse", size: CGSize(width: 193, height: 38))
    try await workspaceTick(window, metrics: metrics, count: 5)
    try requireWorkspace(window.frame.height > 350,
        "Closing workspace prematurely fell back to the native 210-point canvas")
    animateWorkspace(state, metrics: metrics, phase: "reopen-reverse", size: CGSize(width: 640, height: 420),
                     layout: CGSize(width: 640, height: 420), tab: 3)
    try await workspaceTick(window, metrics: metrics, count: 48)
    try requireWorkspace(abs(window.frame.height - 572) <= 1, "Reversal prematurely shrank the retained workspace viewport")

    animateWorkspace(state, metrics: metrics, phase: "native-tab", size: CGSize(width: 640, height: 190),
                     layout: CGSize(width: 640, height: 190), tab: 0)
    try await workspaceTick(window, metrics: metrics, count: 48)
    let native = metrics.samples.filter { $0.phase == "native-tab" }.map(\.size.height)
    try requireWorkspace(native.contains { $0 > 200 && $0 < 410 }, "Native tab switch skipped intermediate shell sizes")
    try requireWorkspace(abs(window.frame.height - 572) <= 1, "Native tab switch prematurely shrank the viewport")
    state.enabled = false
    state.envelope = CGSize(width: 640, height: 210)
    try await workspaceTick(window, metrics: metrics, count: 10)
    try requireWorkspace(abs(window.frame.height - 210) <= 1, "Clearing workspace retention changed native window bounds")

    state.enabled = true
    animateWorkspace(state, metrics: metrics, phase: "reopen-after-native", size: CGSize(width: 640, height: 420),
                     layout: CGSize(width: 640, height: 420), tab: 2)
    try await workspaceTick(window, metrics: metrics, count: 48)
    animateWorkspace(state, metrics: metrics, phase: "close-complete", size: CGSize(width: 193, height: 38),
                     layout: CGSize(width: 640, height: 420), tab: 2)
    try await workspaceTick(window, metrics: metrics, count: 48)
    let closed = metrics.samples.last?.size ?? .zero
    let lastSamples = metrics.samples.suffix(5).map { "\($0.phase):\($0.size)" }
    try requireWorkspace(abs(closed.width - 193) <= 1 && abs(closed.height - 38) <= 1,
        "Closed presentation did not finish at the notch top: actual=\(closed), target=\(state.target), last=\(lastSamples)")
    try requireWorkspace(abs(window.frame.height - 472) <= 1, "Closing prematurely discarded its envelope")
    let settled = window.frameWrites
    try await workspaceTick(window, metrics: metrics, count: 16)
    try requireWorkspace(window.frameWrites == settled, "Workspace continued writing window frames after animation settled")
    try requireWorkspace(metrics.samples.count > 20 && metrics.displayCycleLayouts > 0,
        "Fixture lacked geometry/display-cycle evidence: samples=\(metrics.samples.count), layouts=\(metrics.layouts), displayCycles=\(metrics.displayCycleLayouts)")
    let centerError = metrics.samples.map(\.centerError).max() ?? .infinity
    let topError = metrics.samples.map(\.topError).max() ?? .infinity
    let contentError = metrics.samples.map(\.contentTopError).max() ?? .infinity
    try requireWorkspace(centerError <= 1 && topError <= 1, "Shell left the top-center origin: center=\(centerError), top=\(topError)")
    try requireWorkspace(contentError <= 1, "Content entered from below its shell: top error=\(contentError)")
    try requireWorkspace(metrics.samples.allSatisfy { $0.canvasSize.width + 1 >= $0.size.width && $0.canvasSize.height + 1 >= $0.size.height + 20 }, "Visible shell exceeded the prepared viewport")
    try requireWorkspace(window.automaticFrames == 0 && window.focusRequests == 0, "Hosting view took over window frames or focus")
    print("PASS ordered offscreen workspace animation: samples=\(metrics.samples.count), requests=\(metrics.requests.count), displayCycleLayouts=\(metrics.displayCycleLayouts), maxCenterError=\(centerError), maxTopError=\(topError), contentTopError=\(contentError)")
    print("PASS shared presentation/envelope geometry: closed/open/wide, reversal, clipboard/native tabs, retained closing, stable settled geometry")
    fflush(stdout)
}

@MainActor private final class WorkspaceCheckDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await runWorkspaceChecks(); fflush(stdout); exit(0) }
            catch { fputs("FAIL workspace animation: \(error)\n", stderr); fflush(stderr); exit(1) }
        }
    }
}
@main private struct WorkspaceAnimationChecks: App {
    @NSApplicationDelegateAdaptor(WorkspaceCheckDelegate.self) private var delegate
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }
    var body: some Scene { Settings { EmptyView() } }
}
