// Native, hidden-window checks for the production notch hosting factory and window bridge.
// No installed application, clipboard, permission, activation, or ordered window is involved.
import AppKit
import Combine
import SwiftUI

private struct LayoutCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor private func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    guard condition() else { throw LayoutCheckFailure(description: description) }
}

// These stubs provide only the application-specific types used by the production bridge.
// Focus and ordering calls are intercepted and NEVER forwarded to AppKit/WindowServer.
@MainActor final class BoringNotchSkyLightWindow: NSPanel {
    var allowsIslandKeyboard = false
    var isIslandScreenLocked = false
    var wantsKeyForTextInput = false
    var islandKeyboardOwner: UUID?
    var frameWrites = 0
    var focusRequests = 0
    var resignRequests = 0
    var orderingRequests = 0
    private var fixtureKey = false
    override var screen: NSScreen? { NSScreen.main }
    override var isKeyWindow: Bool { fixtureKey }
    override var canBecomeKey: Bool { false }
    override func makeKey() { focusRequests += 1; fixtureKey = true }
    override func resignKey() { resignRequests += 1; fixtureKey = false }
    override func orderFront(_ sender: Any?) { orderingRequests += 1 }
    override func orderFrontRegardless() { orderingRequests += 1 }
    override func makeKeyAndOrderFront(_ sender: Any?) { orderingRequests += 1; focusRequests += 1 }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        frameWrites += 1
        super.setFrame(frameRect, display: flag)
    }
}

extension NSScreen {
    static func screen(withUUID _: String) -> NSScreen? { main }
}

@MainActor private func panel() throws -> BoringNotchSkyLightWindow {
    guard NSScreen.main != nil else {
        throw LayoutCheckFailure(description: "A macOS WindowServer screen is needed for hidden native layout checks")
    }
    let result = BoringNotchSkyLightWindow(contentRect: NSRect(x: 20_000, y: 20_000, width: 320, height: 180),
        styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow], backing: .buffered, defer: false)
    result.isReleasedWhenClosed = false
    result.isOpaque = false
    result.backgroundColor = .clear
    return result
}

@MainActor private func finish(_ window: BoringNotchSkyLightWindow) {
    window.contentView = nil
    window.close()
}

@MainActor private func pump(_ windows: [BoringNotchSkyLightWindow], ticks: Int = 8) async throws {
    for _ in 0..<ticks {
        try await Task.sleep(for: .milliseconds(4))
        for window in windows {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            try check(!window.isVisible, "Fixture window became visible")
            try check(window.orderingRequests == 0, "Production bridge attempted to order a fixture window")
        }
    }
}

@MainActor private func checkSize(_ window: NSWindow, _ requested: CGSize, _ context: String) throws {
    let scale = max(1, window.screen?.backingScaleFactor ?? 1)
    // AppKit rounds hidden panel origins to whole logical points even on Retina screens.
    let tolerance = max(0.5, 0.5 / scale) + 0.001
    try check(abs(window.frame.width - requested.width) <= tolerance
        && abs(window.frame.height - requested.height) <= tolerance, "\(context): requested \(requested), got \(window.frame.size)")
    if let screen = window.screen {
        try check(abs(window.frame.midX - screen.frame.midX) <= tolerance, "\(context): window lost top centering; frame=\(window.frame), screen=\(screen.frame), scale=\(scale)")
        try check(abs(window.frame.maxY - screen.frame.maxY) <= tolerance, "\(context): window lost top alignment; frame=\(window.frame), screen=\(screen.frame), scale=\(scale)")
    }
}

@MainActor private func requestChecks() async throws {
    let first = try panel()
    let second = try panel()
    defer { finish(first); finish(second) }
    let container = NSView(frame: first.contentView!.bounds)
    first.contentView = container
    let otherContainer = NSView(frame: second.contentView!.bounds)
    second.contentView = otherContainer
    let anchor = IslandWindowBridge.Anchor(frame: .zero)
    container.addSubview(anchor)
    let before = first.frameWrites
    for index in 0..<100 {
        anchor.receive(size: CGSize(width: 500 + index, height: 220 + index),
                       wantsKeyboard: false, permitsKeyboardWithoutHover: false)
    }
    anchor.receive(size: CGSize(width: 640, height: 440), wantsKeyboard: false, permitsKeyboardWithoutHover: false)
    try check(first.frameWrites == before, "receive() synchronously resized its containing window")
    try await pump([first, second])
    try checkSize(first, CGSize(width: 640, height: 440), "Latest queued request")
    try check(first.frameWrites == before + 1, "Repeated requests were not coalesced into one frame write")

    let oddSize = CGSize(width: 599, height: 319)
    anchor.receive(size: oddSize, wantsKeyboard: false, permitsKeyboardWithoutHover: false)
    try await pump([first, second])
    try checkSize(first, oddSize, "Odd-sized panel")
    let oddWrites = first.frameWrites
    for _ in 0..<100 {
        anchor.receive(size: oddSize, wantsKeyboard: false, permitsKeyboardWithoutHover: false)
    }
    try await pump([first, second])
    try check(first.frameWrites == oddWrites, "AppKit's odd-width origin rounding caused repeated corrective writes")

    let beforeDetach = first.frameWrites
    anchor.receive(size: CGSize(width: 920, height: 540), wantsKeyboard: false, permitsKeyboardWithoutHover: false)
    anchor.removeFromSuperview()
    try await pump([first, second])
    try check(first.frameWrites == beforeDetach, "Detached anchor applied a stale frame request")

    otherContainer.addSubview(anchor)
    anchor.receive(size: CGSize(width: 640, height: 440), wantsKeyboard: false, permitsKeyboardWithoutHover: false)
    try await pump([first, second])
    try check(first.frameWrites == beforeDetach, "Reparented anchor changed its previous window")
    try checkSize(second, CGSize(width: 640, height: 440), "Reparented anchor")
    let beforeDismantle = second.frameWrites
    anchor.receive(size: CGSize(width: 880, height: 500), wantsKeyboard: false, permitsKeyboardWithoutHover: false)
    IslandWindowBridge.dismantleNSView(anchor, coordinator: ())
    try await pump([first, second])
    try check(second.frameWrites == beforeDismantle, "Dismantled anchor applied a stale frame request")
    print("PASS production bridge: deferred writes, latest request, coalescing, detach/reparent/dismantle")
}

@MainActor private func focusChecks() async throws {
    let window = try panel()
    defer { finish(window) }
    let container = NSView(frame: window.contentView!.bounds)
    window.contentView = container
    let old = IslandWindowBridge.Anchor(frame: .zero)
    let new = IslandWindowBridge.Anchor(frame: .zero)
    container.addSubview(old); container.addSubview(new)
    old.receive(size: CGSize(width: 640, height: 440), wantsKeyboard: true, permitsKeyboardWithoutHover: true)
    try check(window.focusRequests == 0, "receive() synchronously requested focus")
    try await pump([window])
    try check(window.allowsIslandKeyboard && window.focusRequests == 1, "Keyboard session did not acquire fixture focus")
    let previousOwner = window.islandKeyboardOwner
    new.receive(size: CGSize(width: 640, height: 440), wantsKeyboard: true, permitsKeyboardWithoutHover: true)
    old.invalidate()
    try await pump([window])
    try check(window.islandKeyboardOwner != nil && window.islandKeyboardOwner != previousOwner
        && window.allowsIslandKeyboard, "Stale anchor revoked the current keyboard owner")
    window.isIslandScreenLocked = true
    new.receive(size: CGSize(width: 640, height: 440), wantsKeyboard: true, permitsKeyboardWithoutHover: true)
    try await pump([window])
    try check(!window.allowsIslandKeyboard && !window.isKeyWindow && window.islandKeyboardOwner == nil,
              "Locked window retained keyboard ownership")
    try check(window.resignRequests == 1 && window.orderingRequests == 0, "Unexpected fixture focus/order calls")
    print("PASS production bridge: keyboard ownership, stale release and screen lock (focus intercepted)")
}

@MainActor private final class StressState: ObservableObject {
    @Published var size = CGSize(width: 640, height: 440)
    @Published var rows = 4
}

private struct CompetingRoot: View {
    @ObservedObject var state: StressState
    let includesBridge: Bool
    var body: some View {
        VStack(spacing: 8) {
            HStack { Text("Fixture"); Spacer(); Text("chips \(state.rows)") }
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(0..<state.rows, id: \.self) { index in
                        Text("row \(index) " + String(repeating: "text ", count: index % 17 + 1))
                    }
                }
            }
            TextField("fixture input", text: .constant(""))
        }
        .padding(12)
        // This deliberately requests width-38, matching the observed 640 -> 602 competition.
        // The window bridge remains the authority for the actual panel's full requested size.
        .frame(width: state.size.width - 38, height: state.size.height)
        .background {
            if includesBridge {
                IslandWindowBridge(size: state.size, wantsKeyboard: false)
            }
        }
    }
}

@MainActor private func hostingChecks(cycles: Int) async throws {
    let baseline = try panel()
    defer { finish(baseline) }
    let baselineState = StressState()
    let automatic = NSHostingView(rootView: CompetingRoot(state: baselineState, includesBridge: false))
    baseline.contentView = automatic
    try await pump([baseline], ticks: 12)
    try check(abs(baseline.contentMaxSize.width - 602) < 0.01,
              "Baseline no longer demonstrates NSHostingView's content-derived maximum width")
    print("BASELINE default host derives max width \(baseline.contentMaxSize.width) from competing content")

    let window = try panel()
    defer { finish(window) }
    let state = StressState()
    let host = makeNotchHostingView(rootView: CompetingRoot(state: state, includesBridge: true))
    try check(host.sizingOptions.isEmpty, "Notch host re-enabled content-derived sizing")
    try check(host.safeAreaRegions.isEmpty, "Notch host re-enabled system safe area regions")
    try check(host.autoresizingMask.contains([.width, .height]), "Notch host stopped following the manual panel frame")
    window.contentView = host
    try await pump([window], ticks: 12)
    let originalMinimum = window.contentMinSize
    let originalMaximum = window.contentMaxSize
    try check(originalMinimum == .zero && originalMaximum.width > 1_000_000 && originalMaximum.height > 1_000_000, "Manual host initialized content-derived bounds")
    let sizes = [CGSize(width: 640, height: 210), .init(width: 640, height: 440),
                 .init(width: 920, height: 540), .init(width: 602, height: 440), .init(width: 640, height: 210)]
    for index in 0..<cycles {
        withAnimation(.spring(response: 0.12, dampingFraction: 0.9)) {
            state.size = sizes[index % sizes.count]
            state.rows = [4, 80, 12, 1, 8][index % sizes.count]
        }
        try await pump([window], ticks: 1)
        try check(window.contentMinSize == originalMinimum && window.contentMaxSize == originalMaximum,
                  "Animated SwiftUI content changed manual bounds from \(originalMinimum)/\(originalMaximum) to \(window.contentMinSize)/\(window.contentMaxSize)")
    }
    try await pump([window], ticks: 40)
    try checkSize(window, sizes[(cycles - 1) % sizes.count], "Production host after animated transitions")
    try check(window.frameWrites > 20, "Stress fixture did not execute real bridge frame writes")
    let settledWrites = window.frameWrites
    try await pump([window], ticks: 30)
    try check(window.frameWrites == settledWrites, "Window kept resizing after requests stopped")
    try check(window.focusRequests == 0, "Layout-only fixture requested keyboard focus")
    print("PASS production host: \(cycles) animated compact/wide/closed transitions, \(settledWrites) frame writes, stable bounds/size")

    // Simulate entry from either side by changing only this unshown fixture window's
    // starting origin. No real pointer event or user window is read or manipulated.
    guard let screen = window.screen else { throw LayoutCheckFailure(description: "Fixture screen disappeared") }
    let closed = CGSize(width: 640, height: 210)
    for side in [-1, 1] {
        state.size = closed
        state.rows = 1
        try await pump([window], ticks: 12)
        try checkSize(window, closed, "Closed fixture before simulated entry")
        let startX = side < 0 ? screen.frame.minX - 1_000 : screen.frame.maxX + 1_000
        window.setFrameOrigin(NSPoint(x: startX, y: screen.frame.maxY - closed.height))
        try check(side < 0 ? window.frame.maxX < screen.frame.minX : window.frame.minX > screen.frame.maxX,
                  "Simulated entry did not establish a distinct left/right starting origin")
        let stages: [(String, CGSize)] = [
            ("open", CGSize(width: 640, height: 440)),
            ("wide", CGSize(width: 920, height: 540)),
            ("close", closed),
            ("reopen", CGSize(width: 640, height: 440))
        ]
        for (stage, size) in stages {
            withAnimation(.spring(response: 0.12, dampingFraction: 0.9)) {
                state.size = size
                state.rows = stage == "wide" ? 80 : 4
            }
            try await pump([window], ticks: 12)
            try checkSize(window, size, "Simulated \(side < 0 ? "left" : "right") entry / \(stage)")
            try check(window.contentMinSize == originalMinimum && window.contentMaxSize == originalMaximum,
                      "Entry/reopen changed manual host bounds")
        }
        let afterReopen = window.frameWrites
        try await pump([window], ticks: 16)
        try check(window.frameWrites == afterReopen, "Entry/reopen did not stabilize")
    }
    try check(window.focusRequests == 0 && !window.isVisible, "Entry-side geometry fixture affected UI focus/visibility")
    print("PASS simulated left/right entry: open, wide, close and reopen stay top-centered with stable bounds")
}

@MainActor private final class CheckDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await requestChecks()
                try await focusChecks()
                try await hostingChecks(cycles: 450)
                print("PASS native window layout checks; all windows stayed hidden")
                fflush(stdout)
                NSApp.terminate(nil)
            } catch {
                fputs("FAIL native window layout checks: \(error)\n", stderr)
                fflush(stderr)
                exit(1)
            }
        }
    }
}

@main private struct WindowLayoutChecks {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let delegate = CheckDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
