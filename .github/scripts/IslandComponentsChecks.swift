import AppKit
import SwiftUI

private struct ComponentFailure: Error, CustomStringConvertible { let description: String }
@MainActor private func requireComponent(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ComponentFailure(description: message) }
}

@MainActor private final class ComponentPanel: NSPanel {
    let anchor: CGPoint
    var focusRequests = 0
    var frameWrites = 0
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func makeKey() { focusRequests += 1 }
    override func makeMain() { focusRequests += 1 }
    override func makeKeyAndOrderFront(_ sender: Any?) { focusRequests += 1 }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    init() {
        anchor = CGPoint(x: max(25_000, (NSScreen.screens.map { $0.frame.maxX }.max() ?? 0) + 5_000),
                         y: max(25_000, (NSScreen.screens.map { $0.frame.maxY }.max() ?? 0) + 5_000))
        super.init(contentRect: NSRect(x: anchor.x - 476, y: anchor.y - 572, width: 952, height: 572),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)
        title = "Isolated real island toolbar regression fixture"
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        // A production regression must never move this fixture onto a user's screen.
        frameWrites += 1
        super.setFrame(NSRect(x: anchor.x - frameRect.width / 2, y: anchor.y - frameRect.height,
                              width: frameRect.width, height: frameRect.height), display: flag)
    }
    func assertIsolated() throws {
        try requireComponent(!NSScreen.screens.contains { frame.intersects($0.frame) }, "Fixture approached a physical screen")
        try requireComponent(!isKeyWindow && !isMainWindow && focusRequests == 0, "Fixture requested focus")
        try requireComponent(isVisible, "Fixture was not ordered; display-cycle test would be inconclusive")
    }
}

struct ComponentMarker: NSViewRepresentable {
    let name: String
    final class Marker: NSView { var name = "" }
    func makeNSView(context: Context) -> Marker { let view = Marker(); view.name = name; return view }
    func updateNSView(_ view: Marker, context: Context) { view.name = name }
}

@MainActor private final class ComponentState: ObservableObject {
    @Published var size = CGSize(width: 640, height: 190)
    @Published var payload = 0
}

private struct ComponentPage: View {
    let tab: NotchViews
    let payload: Int
    private var color: Color {
        switch tab {
        case .home: return Color(red: 0.5, green: 0, blue: 1)
        case .shelf: return Color(red: 1, green: 0, blue: 0)
        case .hermes: return Color(red: 0, green: 1, blue: 0)
        case .clipboard: return Color(red: 0, green: 0, blue: 1)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            color.frame(height: 70)
            Spacer(minLength: 0)
            Text("\(tab.rawValue) \(payload)").frame(height: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ComponentMarker(name: "page-\(tab.rawValue)"))
    }
}

@MainActor private struct ComponentRoot: View {
    @ObservedObject var state: ComponentState
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    let vm: BoringViewModel
    @ViewBuilder private func page(_ tab: NotchViews) -> some View {
        // Distinct conditional branches match ContentView's former nested page switch. Both
        // variants use exactly the same passive payload, so only transition ownership differs.
        if tab == .clipboard { ComponentPage(tab: .clipboard, payload: state.payload) }
        else if tab == .hermes { ComponentPage(tab: .hermes, payload: state.payload) }
        else if tab == .shelf { ComponentPage(tab: .shelf, payload: state.payload) }
        else { ComponentPage(tab: .home, payload: state.payload) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BoringHeader()
                .frame(height: 38)
                .background(ComponentMarker(name: "header"))
            #if BASELINE
            VStack { page(coordinator.currentView) }
                .transition(.identity)
            #else
            IslandPageContainer(selection: coordinator.currentView) { page($0) }
            #endif
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .modifier(WorkspaceSurfaceFrame(presentationSize: state.size, contentSize: state.size,
            enabled: true, nativeWindowSize: CGSize(width: 640, height: 210),
            windowEnvelopeSize: CGSize(width: 952, height: 572), shadowPadding: 20,
            topCornerRadius: 19, bottomCornerRadius: 24, shadowOpacity: 0.7) { _ in EmptyView() })
        .background(ComponentMarker(name: "shell"))
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: state.size)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environmentObject(vm)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }
}

@MainActor private func componentMarkers(in view: NSView) -> [ComponentMarker.Marker] {
    (view as? ComponentMarker.Marker).map { [$0] } ?? view.subviews.flatMap { componentMarkers(in: $0) }
}

@MainActor private final class ComponentMetrics {
    var samples = 0, overlaps = 0, wrongPages = 0, rendered = 0, paintedGhosts = 0, toolbarSamples = 0
    var maximumHeaderTopError: CGFloat = 0
    var maximumIconYError: CGFloat = 0
    var initialIconY: [String: CGFloat] = [:]
    var shellHeights: [CGFloat] = []
    var firstButtons: [(String, CGRect)] = []
    var seenPages: Set<String> = []
    var pageViews: [String: ObjectIdentifier] = [:]
    var settledPixels: [NotchViews: SIMD3<Double>] = [:]
    var pixelSamples: [(tab: NotchViews, phase: String, tick: Int, value: SIMD3<Double>)] = []

    func sample(window: ComponentPanel, host: NSView, phase: String, tick: Int, settled: Bool) throws {
        try window.assertIsolated()
        let markers = componentMarkers(in: host)
        let pages = markers.filter { $0.name.hasPrefix("page-") && $0.window === window }
        let names = pages.map(\.name)
        seenPages.formUnion(names)
        if pages.count > 1 { overlaps += 1; if overlaps < 10 { print("OVERLAP \(phase) tick=\(tick) \(names)") } }
        if pages.count != 1 || names.first != "page-\(BoringViewCoordinator.shared.currentView.rawValue)" { wrongPages += 1 }
        for page in pages { pageViews[page.name] = ObjectIdentifier(page) }
        if let header = markers.first(where: { $0.name == "header" }), let shell = markers.first(where: { $0.name == "shell" }) {
            let headerRect = window.convertToScreen(header.convert(header.bounds, to: nil))
            let shellRect = window.convertToScreen(shell.convert(shell.bounds, to: nil))
            maximumHeaderTopError = max(maximumHeaderTopError, abs(headerRect.maxY - shellRect.maxY))
            shellHeights.append(shellRect.height)
        }
        let buttons = markers.filter { $0.name.hasPrefix("tab-") }.map {
            ($0.name, window.convertToScreen($0.convert($0.bounds, to: nil)))
        }
        if firstButtons.isEmpty && !buttons.isEmpty { firstButtons = buttons; print("ACTUAL_TOOLBAR_ICON_FRAMES \(buttons)") }
        for (label, frame) in buttons {
            guard !frame.isEmpty else { continue }
            let top = window.frame.maxY - frame.midY
            if let previous = initialIconY[label] { maximumIconYError = max(maximumIconYError, abs(previous - top)) }
            else { initialIconY[label] = top }
            toolbarSamples += 1
        }
        if [0, 1, 2, 4, 8, 15].contains(tick) || settled, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // A static saturated rectangle has the same pixel value throughout each selected
            // page. Calibrate against the page's settled frame instead of hardcoding RGB values:
            // color management can change those values on different displays / CI machines.
            let x = bitmap.pixelsWide / 2
            let y = Int(65 * CGFloat(bitmap.pixelsHigh) / host.bounds.height)
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                let value = SIMD3<Double>(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
                let tab = BoringViewCoordinator.shared.currentView
                pixelSamples.append((tab, phase, tick, value))
                if settled { settledPixels[tab] = value }
            }
            if let path = ProcessInfo.processInfo.environment["BORING_COMPONENT_FRAMES"],
               let png = bitmap.representation(using: .png, properties: [:]) {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("\(phase)-\(tick).png"), options: .atomic)
            }
            rendered += 1
        }
        samples += 1
    }

    func comparePaintedPages() throws {
        try requireComponent(settledPixels.count == 4 && pixelSamples.count >= 35, "Missing calibrated page pixel samples")
        for sample in pixelSamples {
            guard let expected = settledPixels[sample.tab] else { continue }
            let difference = sample.value - expected
            let error = max(abs(difference.x), abs(difference.y), abs(difference.z))
            if error > 0.04 {
                paintedGhosts += 1
                if paintedGhosts <= 8 { print("PAINTED_GHOST \(sample.phase) tick=\(sample.tick) target=\(sample.tab.rawValue) maxRGBError=\(error)") }
            }
        }
    }
}

@MainActor private func runComponentChecks() async throws {
    let originalFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    var fixtureActivations = 0
    let activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
        object: NSApplication.shared, queue: .main) { _ in
            MainActor.assumeIsolated { fixtureActivations += 1 }
        }
    let window = ComponentPanel()
    let vm = BoringViewModel()
    let state = ComponentState()
    let metrics = ComponentMetrics()
    let container = makeNotchHostingView(rootView: ComponentRoot(state: state, vm: vm))
    window.contentView = container
    defer {
        NotificationCenter.default.removeObserver(activationObserver)
        window.orderOut(nil); window.contentView = nil; window.close()
    }
    window.orderFrontRegardless()
    func ticks(_ phase: String, _ count: Int) async throws {
        for tick in 0..<count {
            try await Task.sleep(for: .milliseconds(16))
            try metrics.sample(window: window, host: container.hostingView, phase: phase, tick: tick,
                               settled: count >= 18 && tick == count - 1)
        }
    }
    try await ticks("settle", 18)
    func select(_ tab: NotchViews, size: CGSize) {
        #if BASELINE
        withAnimation(.smooth) { BoringViewCoordinator.shared.selectTab(tab); state.size = size }
        #else
        BoringViewCoordinator.shared.selectTab(tab); state.size = size
        #endif
    }
    select(.shelf, size: CGSize(width: 640, height: 190)); try await ticks("shelf", 28)
    select(.hermes, size: CGSize(width: 640, height: 420)); try await ticks("shelf-to-hermes", 32)
    select(.clipboard, size: CGSize(width: 640, height: 420)); try await ticks("clipboard", 24)
    select(.home, size: CGSize(width: 640, height: 190)); try await ticks("clipboard-to-home", 32)
    select(.hermes, size: CGSize(width: 920, height: 520)); try await ticks("wide-hermes", 32)
    select(.shelf, size: CGSize(width: 640, height: 190)); try await ticks("wide-to-shelf", 32)
    for index in 0..<12 {
        let tab: NotchViews = index.isMultiple(of: 2) ? .hermes : .shelf
        select(tab, size: CGSize(width: 640, height: index.isMultiple(of: 2) ? 420 : 190))
        try await ticks("rapid-\(index)", 3)
    }
    try await ticks("settled-final", 32)
    // Content changes within the same selection must keep the existing subtree and state.
    let previousPageViews = metrics.pageViews
    state.payload += 1
    try await ticks("same-page-payload", 8)
    let currentName = "page-\(BoringViewCoordinator.shared.currentView.rawValue)"
    try metrics.comparePaintedPages()
    let intermediate = Set(metrics.shellHeights.filter { $0 > 192 && $0 < 418 }.map { Int($0.rounded()) })
    print("RESULT real-header components: samples=\(metrics.samples), toolbarFrames=\(metrics.toolbarSamples), maxHeaderTopError=\(metrics.maximumHeaderTopError), maxIconYError=\(metrics.maximumIconYError), overlaps=\(metrics.overlaps), wrongPages=\(metrics.wrongPages), paintedGhosts=\(metrics.paintedGhosts), renderedFrames=\(metrics.rendered), intermediateHeights=\(intermediate.count), windowFrameWrites=\(window.frameWrites), focusRequests=\(window.focusRequests)")
    let foregroundUnchanged = NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmost
    print("ISOLATION prohibited=\(NSApp.activationPolicy() == .prohibited), fixtureActivations=\(fixtureActivations), externalForegroundUnchanged=\(foregroundUnchanged)")
    try requireComponent(previousPageViews[currentName] == metrics.pageViews[currentName], "Same-tab payload update recreated its page")
    // A user may switch apps while this read-only fixture runs. Observe our own activation,
    // rather than misattributing an external foreground change to the test.
    try requireComponent(NSApp.activationPolicy() == .prohibited && fixtureActivations == 0 && !NSApp.isActive,
                         "Fixture became an active application")
    try requireComponent(window.frameWrites == 0 && window.focusRequests == 0, "Fixture changed window frames or requested focus")
    try requireComponent(metrics.samples >= 250 && metrics.rendered >= 35 && metrics.seenPages.count == 4, "Insufficient component coverage")
    try requireComponent(metrics.maximumHeaderTopError <= 1, "Actual header left the shell top: \(metrics.maximumHeaderTopError)")
    try requireComponent(metrics.toolbarSamples >= 100 && metrics.initialIconY.count == 4, "Actual tab image bounds were not sampled")
    try requireComponent(metrics.maximumIconYError <= 1, "Actual toolbar icons shifted vertically: \(metrics.maximumIconYError)")
    try requireComponent(intermediate.count >= 8, "Atomic page replacement cancelled the shell-height animation")
    #if BASELINE
    if metrics.overlaps > 0 {
        print("BASELINE_GHOST_REPRODUCED: frozen b39850c header with its nested page replacement retained old/new page views during height changes; pixel evidence=\(metrics.paintedGhosts).")
        fflush(stdout); exit(2)
    }
    print("BASELINE_INCONCLUSIVE: component fixture did not reproduce nested-page overlap.")
    #else
    try requireComponent(metrics.overlaps == 0 && metrics.wrongPages == 0 && metrics.paintedGhosts == 0,
                         "Old/new pages overlapped during a selected-tab replacement")
    print("PASS actual BoringHeader/TabSelectionView/TabButton: fixed toolbar top across native/workspace/wide heights, atomic page replacement, rapid reversals, same-page identity retained, continuous shell animation.")
    #endif
    print("Offscreen actual-component marker bounds and cacheDisplay evidence only; no installed app, clipboard, user focus, or real display acceptance was exercised.")
}

@MainActor private final class ComponentDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await runComponentChecks(); fflush(stdout); exit(0) }
            catch { fputs("FAIL island components: \(error)\n", stderr); fflush(stderr); exit(1) }
        }
    }
}
@main private struct IslandComponentsChecks: App {
    @NSApplicationDelegateAdaptor(ComponentDelegate.self) private var delegate
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }
    var body: some Scene { Settings { EmptyView() } }
}
