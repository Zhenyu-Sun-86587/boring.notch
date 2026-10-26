// Actual SwiftUI/AppKit display-cycle checks for the shared workspace shell modifier. Every
// fixture panel is pinned outside all physical screens and cannot become key or main.
import AppKit
import SwiftUI

private struct WorkspaceAnimationFailure: Error, CustomStringConvertible { let description: String }
@MainActor private func requireWorkspace(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw WorkspaceAnimationFailure(description: message) }
}

@MainActor final class BoringNotchSkyLightWindow: NSPanel {
    let islandKeyboardHandoffState = IslandKeyboardHandoffState()
    var allowsIslandKeyboard = false
    var isIslandScreenLocked = false
    var wantsKeyForTextInput = false
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
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    init() {
        let maxX = NSScreen.screens.map { $0.frame.maxX }.max() ?? 0
        let maxY = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        physicalAnchor = CGPoint(x: max(25_000, maxX + 5_000), y: max(25_000, maxY + 5_000))
        super.init(contentRect: NSRect(x: physicalAnchor.x - 476, y: physicalAnchor.y - 572, width: 952, height: 572),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)
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
        var fromTick = false
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
    var renderedFrames = 0
    var shadowFrames = 0
    var footerSamples = 0
    var measurementChanges = 0
    var intrinsicSamples: [(phase: String, size: CGSize)] = []
    var snapshotLayoutChanges = 0
    func record(frames: [String: CGRect]) {
        guard let window, let shell = frames["shell"], let content = frames["content"] else { return }
        let center = window.frame.minX + shell.midX
        let top = window.frame.maxY - shell.minY
        preferenceSamples.append(Sample(phase: phase, size: shell.size, canvasSize: window.frame.size,
            centerError: abs(center - window.physicalAnchor.x), topError: abs(top - window.physicalAnchor.y),
            contentTopError: abs(content.minY - shell.minY)))
    }
    func recordNativeFrames(fromTick: Bool = false) {
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
        if let root = window.contentView, let intrinsic = marker(named: "intrinsic", in: root) {
            intrinsicSamples.append((phase: phase, size: intrinsic.bounds.size))
        }
        guard let shellView, let contentView,
              shellView.window === window, contentView.window === window else { return }
        let shell = window.convertToScreen(shellView.convert(shellView.bounds, to: nil))
        let content = window.convertToScreen(contentView.convert(contentView.bounds, to: nil))
        samples.append(Sample(phase: phase, size: shell.size, canvasSize: window.frame.size,
            centerError: abs(shell.midX - window.physicalAnchor.x), topError: abs(shell.maxY - window.physicalAnchor.y),
            contentTopError: abs(content.maxY - shell.maxY), fromTick: fromTick))
    }
    func layout() {
        layouts += 1
        if Thread.callStackSymbols.contains(where: { $0.contains("NSDisplayCycle") || $0.contains("NSWindowGetDisplayCycle") }) {
            displayCycleLayouts += 1
        }
    }

    func capture(_ host: NSView, tick: Int) throws {
        guard let shellView, shellView.window != nil, let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw WorkspaceAnimationFailure(description: "Native rendering did not produce an image")
        }
        let beforeSnapshot = host.convert(shellView.bounds, from: shellView)
        host.cacheDisplay(in: host.bounds, to: image)
        let shell = host.convert(shellView.bounds, from: shellView)
        if abs(beforeSnapshot.height - shell.height) > 1 || abs(beforeSnapshot.width - shell.width) > 1 {
            snapshotLayoutChanges += 1
            print("SNAPSHOT_LAYOUT \(phase) tick\(tick): \(beforeSnapshot.size) -> \(shell.size)")
        }
        let scaleX = CGFloat(image.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(image.pixelsHigh) / host.bounds.height
        let top = host.isFlipped ? shell.minY : host.bounds.height - shell.maxY
        func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            let pixelX = max(0, min(image.pixelsWide - 1, Int(x * scaleX)))
            let pixelY = max(0, min(image.pixelsHigh - 1, Int(y * scaleY)))
            return image.colorAt(x: pixelX, y: pixelY)?.alphaComponent ?? -1
        }
        // Unlike a coordinate-only assertion, these inspect the composed shell. An independent
        // page fade, ghost background or stale shadow can have perfect NSView bounds and fail here.
        if shell.height > 80 {
            for fraction in [CGFloat(0.25), 0.5, 0.75] {
                try requireWorkspace(alpha(shell.midX, top + shell.height * fraction) >= 0.98,
                    "Opaque shell flashed transparent during \(phase): height=\(shell.height), fraction=\(fraction)")
            }
            let below = alpha(shell.midX, top + shell.height + 24)
            try requireWorkspace(below < 0.03, "Stale page/shadow remained below the current shell in \(phase): alpha=\(below)")
        }
        if ["open-hermes", "wide", "reopen-after-native", "reopen-reverse"].contains(phase), shell.height > 160 {
            func footer(in view: NSView) -> NSView? {
                if let marker = view as? FrameReader.Marker, marker.name == "footer" { return marker }
                return view.subviews.lazy.compactMap { footer(in: $0) }.first
            }
            if let footer = footer(in: host) {
                let rect = host.convert(footer.bounds, from: footer)
                let footerBottom = host.isFlipped ? rect.maxY : host.bounds.height - rect.minY
                try requireWorkspace(footerBottom <= top + shell.height + 1 && footerBottom >= top + shell.height - 32,
                    "Input did not follow the presentation height in \(phase): footer=\(footerBottom), bottom=\(top + shell.height)")
                footerSamples += 1
            }
        }
        if phase == "wide" || phase == "native-tab" {
            let shadow = alpha(shell.midX, top + shell.height + 3)
            if shadow > 0.005 && shadow < 0.8 { shadowFrames += 1 }
        }
        if let path = ProcessInfo.processInfo.environment["BORING_WORKSPACE_FRAMES"],
           let png = image.representation(using: .png, properties: [:]) {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("\(phase)-\(tick).png"), options: .atomic)
        }
        renderedFrames += 1
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
        if name == "shell" { metrics.shellView = view }
        else if name == "content" { metrics.contentView = view }
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
    @Published var open = false
    @Published var tab = 2
    @Published var rows = 20
    @Published var intrinsic = CGSize.zero
}

@MainActor private struct WorkspaceRoot: View {
    @ObservedObject var state: WorkspaceState
    let metrics: WorkspaceMetrics
    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 8) {
              if state.open {
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
                                .background(FrameReader(name: "footer", metrics: metrics))
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
                    } else if state.tab == 4 {
                        VStack { Text("Compact music fixture"); Capsule().fill(.gray).frame(height: 6); Text("⏮  ▶  ⏭") }
                            .frame(width: 336, height: 132)
                    } else {
                        VStack { Text(state.tab == 0 ? "Home fixture" : "Shelf fixture"); Spacer() }
                    }
                }
                .transition(.identity)
              } else {
                  Color.gray.opacity(0.2).frame(width: 193, height: 38)
              }
            }
            .fixedSize(horizontal: !state.open, vertical: !state.open || state.tab == 4)
            .background(FrameReader(name: "intrinsic", metrics: metrics).transaction { $0.animation = nil })
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: WorkspaceSurfaceMeasurementPreference.self,
                        value: .init(kind: !state.open ? .closed : (state.tab == 4 ? .compact : .inactive), size: geometry.size))
                }
                .transaction { $0.animation = nil }
            }
            .background(FrameReader(name: "content", metrics: metrics))
            .modifier(WorkspaceSurfaceFrame(presentationSize: state.target, contentSize: state.layout,
                enabled: state.enabled, nativeWindowSize: CGSize(width: 640, height: 210),
                windowEnvelopeSize: CGSize(width: 952, height: 572), shadowPadding: 20,
                topCornerRadius: state.open ? 19 : 6, bottomCornerRadius: state.open ? 24 : 14,
                shadowOpacity: state.open ? 0.7 : 0) { size in
                    IslandWindowBridge(size: size, wantsKeyboard: false, keyboardActivation: "fixture")
                        .background(WorkspaceRequestProbe(size: size, metrics: metrics))
                })
            .background(FrameReader(name: "shell", metrics: metrics))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .onPreferenceChange(WorkspaceSurfaceMeasurementPreference.self) { measurement in
            if measurement.kind != .inactive && state.intrinsic != measurement.size {
                state.intrinsic = measurement.size
                metrics.measurementChanges += 1
            }
        }
        .coordinateSpace(name: "workspace-canvas")
        .onPreferenceChange(WorkspaceFrames.self) { frames in metrics.record(frames: frames) }
    }
}

@MainActor private func animateWorkspace(_ state: WorkspaceState, metrics: WorkspaceMetrics, phase: String,
                                        size: CGSize, layout: CGSize? = nil, tab: Int? = nil, animated: Bool = true) {
    metrics.phase = phase
    let animation = size.height > 50 ? Animation.spring(response: 0.42, dampingFraction: 0.8)
        : Animation.spring(response: 0.45, dampingFraction: 1)
    withAnimation(animated ? animation : nil) {
        if let layout { state.layout = layout }
        if let tab { state.tab = tab }
        state.open = size.height > 50
        state.target = size
    }
}
@MainActor private func workspaceTick(_ window: BoringNotchSkyLightWindow, metrics: WorkspaceMetrics, count: Int = 1) async throws {
    for tick in 0..<count {
        try await Task.sleep(for: .milliseconds(16))
        try window.assertOffscreen()
        try requireWorkspace(window.isVisible, "Fixture exposed a hidden display frame during \(metrics.phase)")
        // Sample actual attached NSViews after the AppKit display cycle has serviced this tick.
        // SwiftUI preference callbacks can otherwise describe an earlier proposal than NSWindow.frame.
        metrics.recordNativeFrames(fromTick: true)
        if [0, 1, 2, 3, 8, 18, 36].contains(tick) {
            if let container = window.contentView as? NotchHostingContainer<WorkspaceRoot> {
                try metrics.capture(container.hostingView, tick: tick)
            }
        }
    }
}

@MainActor private func writeWorkspaceContactSheet() throws {
    guard let path = ProcessInfo.processInfo.environment["BORING_WORKSPACE_FRAMES"],
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 1000,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 1440, height: 1000).fill()
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    for (row, phase) in ["open-hermes", "wide", "native-tab", "close-complete"].enumerated() {
        for (column, tick) in [0, 1, 2, 3].enumerated() {
            guard let image = NSImage(contentsOf: directory.appendingPathComponent("\(phase)-\(tick).png")) else { continue }
            let rectangle = NSRect(x: column * 360 + 5, y: 1000 - row * 250 - 235, width: 350, height: 210)
            NSColor(calibratedRed: 0.68, green: 0.73, blue: 0.79, alpha: 1).setFill()
            rectangle.fill()
            image.draw(in: rectangle, from: .zero, operation: .sourceOver, fraction: 1)
            NSAttributedString(string: "\(phase) - sample \(tick)", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black
            ]).draw(at: NSPoint(x: rectangle.minX, y: rectangle.maxY + 6))
        }
    }
    if let png = bitmap.representation(using: .png, properties: [:]) {
        try png.write(to: directory.deletingLastPathComponent().appendingPathComponent("workspace-animation-contact-sheet.png"), options: .atomic)
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
    try requireWorkspace(abs(window.frame.height - 572) <= 1, "Expanded window changed its stable viewport")

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

    // Production releases before mutating the selected tab. Hiding a panel after the spring
    // starts lets SwiftUI cancel the in-flight presentation and jump to the new endpoint.
    window.releaseIslandKeyboard()
    try requireWorkspace(window.isVisible && !window.isKeyWindow && !window.isIslandKeyboardHandoffActive,
        "Ordinary native-tab keyboard release created an asynchronous hidden interval")
    animateWorkspace(state, metrics: metrics, phase: "native-tab", size: CGSize(width: 640, height: 190),
                     layout: CGSize(width: 640, height: 190), tab: 0)
    try await workspaceTick(window, metrics: metrics, count: 48)
    let native = metrics.samples.filter { $0.phase == "native-tab" && $0.fromTick }.map(\.size.height)
    try requireWorkspace(Set(native.filter { $0 > 191 && $0 < 419 }.map { Int($0.rounded()) }).count >= 3,
        "Native tab switch skipped continuous intermediate shell sizes: \(native.prefix(16))")
    try requireWorkspace(abs(window.frame.height - 572) <= 1, "Native tab switch prematurely shrank the viewport")
    try await workspaceTick(window, metrics: metrics, count: 10)
    try requireWorkspace(abs(window.frame.height - 572) <= 1, "Native tab changed the stable viewport")

    animateWorkspace(state, metrics: metrics, phase: "notification-height", size: CGSize(width: 640, height: 132), tab: 0)
    try await workspaceTick(window, metrics: metrics, count: 40)
    animateWorkspace(state, metrics: metrics, phase: "compact-height", size: CGSize(width: 430, height: 211), tab: 4)
    try await workspaceTick(window, metrics: metrics, count: 40)
    animateWorkspace(state, metrics: metrics, phase: "no-animation", size: CGSize(width: 640, height: 420), tab: 3, animated: false)
    try await workspaceTick(window, metrics: metrics, count: 12)
    try requireWorkspace(metrics.samples.filter { $0.phase == "no-animation" }.allSatisfy {
        abs($0.size.width - 640) <= 1 && abs($0.size.height - 420) <= 1
    }, "Disabling animation left an inherited transition or intermediate size")

    animateWorkspace(state, metrics: metrics, phase: "reopen-after-native", size: CGSize(width: 640, height: 420),
                     layout: CGSize(width: 640, height: 420), tab: 2)
    try await workspaceTick(window, metrics: metrics, count: 48)
    window.releaseIslandKeyboard()
    animateWorkspace(state, metrics: metrics, phase: "close-complete", size: CGSize(width: 193, height: 38),
                     layout: CGSize(width: 640, height: 420), tab: 2)
    try await workspaceTick(window, metrics: metrics, count: 48)
    let closed = metrics.samples.last?.size ?? .zero
    let closing = metrics.samples.filter { $0.phase == "close-complete" && $0.fromTick }.map(\.size.height)
    try requireWorkspace(Set(closing.filter { $0 > 39 && $0 < 419 }.map { Int($0.rounded()) }).count >= 3,
        "Closing skipped continuous intermediate shell sizes: \(closing.prefix(16))")
    let lastSamples = metrics.samples.suffix(5).map { "\($0.phase):\($0.size)" }
    try requireWorkspace(abs(closed.width - 193) <= 1 && abs(closed.height - 38) <= 1,
        "Closed presentation did not finish at the notch top: actual=\(closed), target=\(state.target), last=\(lastSamples)")
    try requireWorkspace(abs(window.frame.height - 572) <= 1, "Closing changed the stable viewport")
    let settled = window.frameWrites
    let settledMeasurements = metrics.measurementChanges
    try await workspaceTick(window, metrics: metrics, count: 16)
    try requireWorkspace(window.frameWrites == settled, "Workspace continued writing window frames after animation settled")
    try requireWorkspace(metrics.measurementChanges == settledMeasurements && metrics.measurementChanges < 12,
        "Native intrinsic geometry fed back into its own animation")
    let closedIntrinsic = metrics.intrinsicSamples.filter { $0.phase == "close-complete" }.map(\.size)
    let compactIntrinsic = metrics.intrinsicSamples.filter { $0.phase == "compact-height" }.map { $0.size.height }
    try requireWorkspace(closedIntrinsic.count > 10 && closedIntrinsic.allSatisfy {
        abs($0.width - 193) <= 1 && abs($0.height - 38) <= 1
    }, "Closed intrinsic measurement followed the animated shell instead of natural content: \(closedIntrinsic.prefix(16))")
    try requireWorkspace(compactIntrinsic.count > 10
        && (compactIntrinsic.max()! - compactIntrinsic.min()!) <= 1,
        "Compact natural height followed its animated destination")
    try requireWorkspace(metrics.samples.count > 20 && metrics.displayCycleLayouts > 0,
        "Fixture lacked geometry/display-cycle evidence: samples=\(metrics.samples.count), layouts=\(metrics.layouts), displayCycles=\(metrics.displayCycleLayouts)")
    let centerError = metrics.samples.map(\.centerError).max() ?? .infinity
    let topError = metrics.samples.map(\.topError).max() ?? .infinity
    let contentError = metrics.samples.map(\.contentTopError).max() ?? .infinity
    try requireWorkspace(centerError <= 1 && topError <= 1, "Shell left the top-center origin: center=\(centerError), top=\(topError)")
    try requireWorkspace(contentError <= 1, "Content entered from below its shell: top error=\(contentError)")
    try requireWorkspace(metrics.samples.allSatisfy { $0.canvasSize.width + 1 >= $0.size.width && $0.canvasSize.height + 1 >= $0.size.height + 20 }, "Visible shell exceeded the prepared viewport")
    try requireWorkspace(window.automaticFrames == 0 && window.focusRequests == 0, "Hosting view took over window frames or focus")
    try requireWorkspace(window.frameWrites == 0 && metrics.renderedFrames >= 30 && metrics.shadowFrames > 0 && metrics.footerSamples >= 8,
        "Missing stable-window/composited rendering evidence: writes=\(window.frameWrites), rendered=\(metrics.renderedFrames), shadows=\(metrics.shadowFrames), footer=\(metrics.footerSamples)")
    let empty = NSPoint(x: 4, y: 4)
    try requireWorkspace(container.hitTest(empty) == nil, "Transparent stable viewport captured pointer/drop input")
    try writeWorkspaceContactSheet()
    print("PASS ordered offscreen workspace animation: samples=\(metrics.samples.count), requests=\(metrics.requests.count), displayCycleLayouts=\(metrics.displayCycleLayouts), maxCenterError=\(centerError), maxTopError=\(topError), contentTopError=\(contentError)")
    print("PASS composited native frames: \(metrics.renderedFrames) opaque-shell/ghost-shadow pixel checks, \(metrics.shadowFrames) shadow gradients, \(metrics.footerSamples) live footer positions; stable natural closed/compact measurements=\(closedIntrinsic.count + compactIntrinsic.count)")
    print("PASS unified stable viewport: first open, wide, interrupted closing/reversal, Hermes/clipboard/home/notification/compact heights, no-animation, close; zero window writes and transparent hit-test pass-through")
    print("Native cacheDisplay snapshots are diagnostic composition samples, not a frame-rate or WindowServer visual-acceptance measurement; snapshot-induced layout changes=\(metrics.snapshotLayoutChanges)")
    print("After-run-loop tick native heights: \(native.prefix(14)); closing heights: \(closing.prefix(14))")
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
