// A real ordered-window display-cycle fixture. Every window is pinned outside all screens;
// no production bridge, user window, keyboard activation, clipboard or permission API is used.
import AppKit
import SwiftUI

private struct OrderedFailure: Error, CustomStringConvertible { let description: String }
@MainActor private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw OrderedFailure(description: message) }
}

@MainActor private final class OrderedMetrics {
    var layoutPasses = 0
    var displayCycleLayouts = 0
    var sampleStacks: [String] = []
    func sawLayout() {
        layoutPasses += 1
        let stack = Thread.callStackSymbols
        if stack.contains(where: { $0.contains("NSDisplayCycle") || $0.contains("NSWindowGetDisplayCycle") }) {
            displayCycleLayouts += 1
            if sampleStacks.count < 2 { sampleStacks.append(stack.joined(separator: "\n")) }
        }
    }
}

private struct OrderedLayoutProbe: NSViewRepresentable {
    let revision: Int
    let metrics: OrderedMetrics
    final class Probe: NSView {
        var revision = -1
        var metrics: OrderedMetrics?
        override func layout() { metrics?.sawLayout(); super.layout() }
    }
    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateNSView(_ view: Probe, context: Context) {
        view.metrics = metrics
        if view.revision != revision {
            view.revision = revision
            // Schedule the ordinary AppKit display-cycle layout; never invoke layout manually.
            view.needsLayout = true
        }
    }
}

@MainActor private final class OrderedState: ObservableObject {
    @Published var tab = 0
    @Published var rows = 20
    @Published var size = CGSize(width: 640, height: 440)
    @Published var revision = 0
}

private struct OrderedTabs: View {
    @ObservedObject var state: OrderedState
    let metrics: OrderedMetrics
    var body: some View {
        VStack(spacing: 8) {
            Picker("Fixture", selection: $state.tab) {
                Text("Home").tag(0); Text("Shelf").tag(1); Text("Hermes").tag(2); Text("Clipboard").tag(3)
            }.pickerStyle(.segmented)
            Group {
                switch state.tab {
                case 0:
                    VStack {
                        Image(systemName: "music.note").font(.system(size: 48))
                        Text("Music fixture")
                        Slider(value: .constant(0.5))
                    }
                case 1:
                    ScrollView(.horizontal) {
                        LazyHStack {
                            ForEach(0..<state.rows, id: \.self) { index in
                                VStack { Image(systemName: "doc").font(.system(size: 40)); Text("File \(index)") }
                                    .frame(width: 90, height: 110)
                            }
                        }
                    }
                case 2:
                    VStack {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(0..<state.rows, id: \.self) { index in
                                    Text("Answer \(index) " + String(repeating: "markdown ", count: 18))
                                    ScrollView(.horizontal) {
                                        HStack { ForEach(0..<12, id: \.self) { Text("Column \($0)").frame(width: 90) } }
                                    }.frame(height: 40)
                                }
                            }
                        }
                        TextField("Prompt", text: .constant(""))
                    }
                default:
                    VStack {
                        TextField("Search", text: .constant(""))
                        ScrollViewReader { _ in
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    ForEach(0..<state.rows, id: \.self) { index in
                                        HStack {
                                            Image(systemName: "photo").resizable().scaledToFit().frame(width: 50, height: 42)
                                            VStack(alignment: .leading) {
                                                Text("Clipboard \(index)").lineLimit(2)
                                                Text("Source app").font(.caption2)
                                            }
                                            Spacer()
                                        }
                                        .padding(8)
                                        .background(index == state.rows / 2 ? Color.gray.opacity(0.2) : Color.clear)
                                        .id(index)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .id(state.tab)
            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .top)))
        }
        .padding(12)
        .frame(width: state.size.width - 38, height: state.size.height)
        .background(OrderedLayoutProbe(revision: state.revision, metrics: metrics))
    }
}

@MainActor private final class OrderedPanel: NSPanel {
    var requested = CGSize(width: 640, height: 440)
    var driverWrites = 0
    var automaticFrameWrites = 0
    var focusAttempts = 0
    var unexpectedStacks: [String] = []
    private var driverWrite = false
    private var initialized = false
    private var pinnedOrigin = NSPoint(x: 20_000, y: 20_000)

    init() {
        super.init(contentRect: NSRect(x: 20_000, y: 20_000, width: 640, height: 440),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow], backing: .buffered, defer: false)
        initialized = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        hasShadow = false
        title = "Boring Notch isolated offscreen layout fixture"
        driveFrame(requested)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func makeKey() { focusAttempts += 1 }
    override func makeMain() { focusAttempts += 1 }
    override func makeKeyAndOrderFront(_ sender: Any?) { focusAttempts += 1 }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    private func safeOrigin() -> NSPoint {
        // Keep x/y at 20,000 on normal desktops and farther out if a large virtual screen exists.
        let frames = NSScreen.screens.map(\.frame)
        return NSPoint(x: max(20_000, (frames.map(\.maxX).max() ?? 0) + 5_000),
                       y: max(20_000, (frames.map(\.maxY).max() ?? 0) + 5_000))
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard frameRect.width.isFinite, frameRect.height.isFinite,
              frameRect.width > 0, frameRect.height > 0 else { return }
        pinnedOrigin = safeOrigin()
        let pinned = NSRect(origin: pinnedOrigin, size: frameRect.size)
        if initialized, !driverWrite {
            automaticFrameWrites += 1
            if unexpectedStacks.count < 2 { unexpectedStacks.append(Thread.callStackSymbols.joined(separator: "\n")) }
        }
        super.setFrame(pinned, display: flag)
    }
    func driveFrame(_ size: CGSize) {
        requested = size
        driverWrites += 1
        driverWrite = true
        setFrame(NSRect(origin: safeOrigin(), size: size), display: false)
        driverWrite = false
    }
    func assertSafe() throws {
        if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
            orderOut(nil)
            throw OrderedFailure(description: "Fixture approached a physical screen; immediately ordered out")
        }
        try require(frame.minX >= 20_000 && frame.minY >= 20_000, "Fixture left the guarded offscreen origin")
        try require(!isKeyWindow && !isMainWindow, "Fixture acquired real keyboard/main-window status")
    }
}

@MainActor private func tick(_ window: OrderedPanel, milliseconds: Int = 16) async throws {
    // Let NSApplication's actual run loop service NSDisplayCycle layout, animation and drawing.
    // Intentionally no layoutIfNeeded/layoutSubtreeIfNeeded calls from this harness.
    try await Task.sleep(for: .milliseconds(milliseconds))
    try window.assertSafe()
}

@MainActor private func runOrdered(mode: String, cycles: Int) async throws -> Bool {
    let state = OrderedState()
    let metrics = OrderedMetrics()
    let root = OrderedTabs(state: state, metrics: metrics)
    let window = OrderedPanel()
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    if mode == "baseline" {
        // Exactly the previous factory: the NSHostingView itself occupies NSWindow.contentView.
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
    } else {
        let container = makeNotchHostingView(rootView: root)
        window.contentView = container
        try require(window.contentView === container && container.hostingView.superview === container,
                    "Production container was bypassed")
    }
    window.driveFrame(state.size)
    try window.assertSafe()
    window.orderFrontRegardless()
    try window.assertSafe()
    try require(window.isVisible, "Fixture was not ordered; display-cycle test would be inconclusive")
    print("ORDERED \(mode): pid=\(ProcessInfo.processInfo.processIdentifier) frame=\(window.frame) cycles=\(cycles)")
    fflush(stdout)
    for _ in 0..<12 { try await tick(window) }
    let originalMin = window.contentMinSize
    let originalMax = window.contentMaxSize
    var sizeMismatches = 0
    var constraintMismatches = 0
    let sizes = [CGSize(width: 640, height: 210), .init(width: 640, height: 440), .init(width: 920, height: 540), .init(width: 640, height: 440)]
    for index in 0..<cycles {
        let size = sizes[index % 4]
        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
            state.tab = index % 4
            state.rows = [1, 12, 80, 120][index % 4]
            state.size = size
            state.revision = index + 1
        }
        // Match the production bridge's deferred frame submission without using its screen-centering code.
        DispatchQueue.main.async { [weak window] in window?.driveFrame(size) }
        try await tick(window, milliseconds: [8, 16, 24, 16][index % 4])
        if abs(window.frame.width - size.width) > 0.5 || abs(window.frame.height - size.height) > 0.5 { sizeMismatches += 1 }
        if window.contentMinSize != originalMin || window.contentMaxSize != originalMax { constraintMismatches += 1 }
        if mode != "baseline" {
            try require(sizeMismatches == 0 && constraintMismatches == 0,
                        "Production container lost requested size or changed content constraints at cycle \(index): \(window.frame)")
        }
    }
    for _ in 0..<45 { try await tick(window) }
    let expected = sizes[(cycles - 1) % 4]
    let settledMismatch = abs(window.frame.width - expected.width) > 0.5 || abs(window.frame.height - expected.height) > 0.5
    let settledWrites = window.automaticFrameWrites
    for _ in 0..<20 { try await tick(window) }
    let continuingWrites = window.automaticFrameWrites - settledWrites
    print("RESULT \(mode): layouts=\(metrics.layoutPasses) displayCycleLayouts=\(metrics.displayCycleLayouts) autoFrames=\(window.automaticFrameWrites) sizeMismatches=\(sizeMismatches) constraintMismatches=\(constraintMismatches) settledMismatch=\(settledMismatch) continuingWrites=\(continuingWrites) final=\(window.frame) focusAttempts=\(window.focusAttempts)")
    for stack in metrics.sampleStacks { print("DISPLAY_CYCLE_STACK \(mode)\n\(stack)") }
    for stack in window.unexpectedStacks { print("AUTOMATIC_FRAME_STACK \(mode)\n\(stack)") }
    fflush(stdout)
    try require(metrics.layoutPasses > 20 && metrics.displayCycleLayouts > 0,
                "Fixture did not observe real NSDisplayCycle layouts; result is inconclusive")
    if mode != "baseline" {
        try require(!settledMismatch && continuingWrites == 0, "Production container continued resizing after animation settled")
        print("PASS production ordered offscreen display-cycle fixture")
        return true
    }
    let anomaly = sizeMismatches > 0 || constraintMismatches > 0 || settledMismatch || continuingWrites > 0
    print(anomaly ? "BASELINE_ANOMALY_OBSERVED" : "BASELINE_NO_ANOMALY_REPRODUCED")
    return anomaly
}

@MainActor private final class OrderedDelegate: NSObject, NSApplicationDelegate {
    let mode = CommandLine.arguments.contains("--baseline") ? "baseline" : "production"
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                let observed = try await runOrdered(mode: mode, cycles: 240)
                fflush(stdout)
                exit(mode == "baseline" && observed ? 2 : 0)
            } catch {
                fputs("FAIL ordered \(mode): \(error)\n", stderr)
                fflush(stderr)
                exit(1)
            }
        }
    }
}

@main private struct OrderedWindowLayoutChecks: App {
    @NSApplicationDelegateAdaptor(OrderedDelegate.self) private var delegate
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }
    var body: some Scene { Settings { EmptyView() } }
}
