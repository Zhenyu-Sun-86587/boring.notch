import AppKit
import SwiftUI

@MainActor
enum HermesLayout {
    static func size(screenUUID: String?, wide: Bool) -> CGSize {
        let screen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
        let key = wide ? "island.hermesWideWidth" : "island.hermesWidth"
        let stored = UserDefaults.standard.double(forKey: key)
        let requested = stored.isFinite && stored >= 480 ? min(stored, 1_920) : (wide ? 920 : 640)
        let minimumWidth: Double = (screen?.safeAreaInsets.top ?? 0) > 0 ? 640 : 480
        return CGSize(width: min(max(requested, minimumWidth), max(320, frame.width - 32)),
                      height: min(wide ? 520 : 420, max(240, frame.height - 80)))
    }
}

/// Like the upstream native tabs, every surface animates inside one stable transparent window.
/// Preparing the configured largest surface before ordering the panel avoids resizing AppKit's
/// backing store during opening, tab changes, closing, or an interrupted spring.
@MainActor
enum IslandViewportLayout {
    static func size(screenUUID: String?) -> CGSize {
        size(compact: HermesLayout.size(screenUUID: screenUUID, wide: false),
             wide: HermesLayout.size(screenUUID: screenUUID, wide: true))
    }

    static func size(compact: CGSize, wide: CGSize) -> CGSize {
        let springRoom: CGFloat = 32
        return CGSize(width: max(640, compact.width, wide.width) + springRoom,
                      height: max(210, compact.height + 20, wide.height + 20) + springRoom)
    }
}

/// Submit window changes after SwiftUI reconciliation, rather than resizing
/// the NSHostingView's own window from inside updateNSView/viewDidMoveToWindow.
struct IslandWindowBridge: NSViewRepresentable {
    private static let keyboardRequest = Notification.Name("IslandKeyboardFocusRequested")

    @MainActor static func requestKeyboardFocus(in window: NSWindow) {
        InteractionDiagnostics.record("focus.bridge", "explicit-request", InteractionDiagnostics.windowFields(window))
        NotificationCenter.default.post(name: keyboardRequest, object: window)
    }

    let size: CGSize
    let wantsKeyboard: Bool
    var permitsKeyboardWithoutHover = false
    var keyboardActivation: String?
    var keyboardReady = true
    var pointerInside = false

    @MainActor
    final class Anchor: NSView, IslandInteractionRegionProviding {
        private struct Request {
            let size: CGSize
            let wantsKeyboard: Bool
            let permitsKeyboardWithoutHover: Bool
            let keyboardActivation: String?
            let keyboardReady: Bool
            let pointerInside: Bool
        }
        private let ownerID = UUID()
        private var request: Request?
        private var generation: UInt = 0
        private var pending: DispatchWorkItem?
        private weak var previousWindow: NSWindow?
        private var lastDiagnosticSignature: String?
        private var attemptedKeyboardActivation = false
        private var explicitKeyboardEntry = false
        private var explicitKeyboardDeadline: TimeInterval = 0
        private var keyboardObserver: NSObjectProtocol?
        private var competingKeyboardObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func receive(size: CGSize, wantsKeyboard: Bool, permitsKeyboardWithoutHover: Bool,
                     keyboardActivation: String? = nil, keyboardReady: Bool = true, pointerInside: Bool = false) {
            if !wantsKeyboard, request?.wantsKeyboard == true { explicitKeyboardEntry = false }
            if !wantsKeyboard || request?.wantsKeyboard != true
                || request?.keyboardActivation != keyboardActivation {
                attemptedKeyboardActivation = false
            }
            if InteractionDiagnostics.enabled {
                let signature = "\(size)|\(wantsKeyboard)|\(keyboardReady)|\(pointerInside)|\(keyboardActivation ?? "nil")"
                if signature != lastDiagnosticSignature {
                    lastDiagnosticSignature = signature
                    var fields = InteractionDiagnostics.windowFields(window)
                    fields.merge(["activation": keyboardActivation ?? "nil", "wantsKeyboard": String(wantsKeyboard), "ready": String(keyboardReady), "width": String(describing: size.width), "height": String(describing: size.height), "owner": ownerID.uuidString, "current": String(pointerInside)]) { _, new in new }
                    InteractionDiagnostics.record("focus.bridge", "request", fields)
                }
            }
            request = Request(size: size, wantsKeyboard: wantsKeyboard,
                              permitsKeyboardWithoutHover: permitsKeyboardWithoutHover,
                              keyboardActivation: keyboardActivation, keyboardReady: keyboardReady, pointerInside: pointerInside)
            schedule()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            InteractionDiagnostics.record("focus.bridge", "anchor-window", InteractionDiagnostics.windowFields(window))
            if let previousWindow, previousWindow !== window { releaseKeyboard(in: previousWindow) }
            if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
            if let competingKeyboardObserver { NotificationCenter.default.removeObserver(competingKeyboardObserver) }
            keyboardObserver = nil
            competingKeyboardObserver = nil
            explicitKeyboardEntry = false
            if let window {
                keyboardObserver = NotificationCenter.default.addObserver(forName: IslandWindowBridge.keyboardRequest,
                    object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window, self.window === window else { return }
                        self.explicitKeyboardEntry = true
                        self.explicitKeyboardDeadline = ProcessInfo.processInfo.systemUptime + 5
                        self.attemptedKeyboardActivation = false
                        self.schedule()
                    }
                }
                competingKeyboardObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                    object: nil, queue: .main) { [weak self, weak window] notification in
                    MainActor.assumeIsolated {
                        guard let self, let window, self.window === window,
                              self.request?.wantsKeyboard == true,
                              let winner = notification.object as? NSWindow, winner !== window else { return }
                        // A delayed target snapshot is not permission to steal focus from Settings.
                        // Only a new explicit entry/input click may re-arm this session afterward.
                        InteractionDiagnostics.record("focus.bridge", "competing-window", InteractionDiagnostics.windowFields(winner))
                        self.attemptedKeyboardActivation = true
                        self.explicitKeyboardEntry = false
                        self.explicitKeyboardDeadline = 0
                    }
                }
            }
            previousWindow = window
            schedule()
        }

        private func schedule() {
            generation &+= 1
            pending?.cancel()
            pending = nil
            guard let window, request != nil else { return }
            let expectedGeneration = generation
            let work = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      self.generation == expectedGeneration, let request = self.request else { return }
                self.pending = nil
                self.apply(request, to: window)
            }
            pending = work
            DispatchQueue.main.async(execute: work)
        }

        private func apply(_ request: Request, to window: NSWindow) {
            guard let screen = window.screen,
                  request.size.width.isFinite, request.size.height.isFinite,
                  request.size.width > 0, request.size.height > 0 else {
                InteractionDiagnostics.record("focus.bridge", "invalid-screen-or-size", InteractionDiagnostics.windowFields(window))
                return
            }
            let scale = max(1, screen.backingScaleFactor)
            func pixelAligned(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
            let frame = NSRect(x: pixelAligned(screen.frame.midX - request.size.width / 2),
                               y: pixelAligned(screen.frame.maxY - request.size.height),
                               width: pixelAligned(request.size.width), height: pixelAligned(request.size.height))
            // WindowServer may round an origin to whole points even on Retina.
            // Accept that half-point difference instead of repeatedly correcting it.
            let tolerance: CGFloat = 0.5
            let current = window.frame
            if abs(current.minX - frame.minX) > tolerance || abs(current.minY - frame.minY) > tolerance
                || abs(current.width - frame.width) > tolerance || abs(current.height - frame.height) > tolerance {
                // AppKit will schedule its normal display/layout pass. Never force a
                // synchronous display while SwiftUI is updating its view hierarchy.
                window.setFrame(frame, display: false)
            }
            guard let panel = window as? BoringNotchSkyLightWindow,
                  !panel.isIslandKeyboardHandoffActive else {
                InteractionDiagnostics.record("focus.bridge", "blocked-handoff", InteractionDiagnostics.windowFields(window))
                return
            }
            if request.wantsKeyboard && !panel.isIslandScreenLocked && panel.isVisible {
                guard request.keyboardReady else {
                    InteractionDiagnostics.record("focus.bridge", "waiting-target", InteractionDiagnostics.windowFields(window))
                    return
                }
                // Admission happens once per explicit opening/tab/session. A
                // streamed answer or layout update must not steal key status
                // back from Settings, a permission alert or another app.
                if !attemptedKeyboardActivation
                    && ((explicitKeyboardEntry && ProcessInfo.processInfo.systemUptime < explicitKeyboardDeadline)
                        || request.permitsKeyboardWithoutHover || request.pointerInside) {
                    attemptedKeyboardActivation = true
                    explicitKeyboardEntry = false
                    panel.islandKeyboardOwner = ownerID
                    panel.allowsIslandKeyboard = true
                    InteractionDiagnostics.record("focus.bridge", "make-key-before", InteractionDiagnostics.windowFields(panel))
                    if !panel.isKeyWindow { panel.makeKey() }
                    InteractionDiagnostics.record("focus.bridge", "make-key-after", InteractionDiagnostics.windowFields(panel))
                } else if !panel.isKeyWindow {
                    InteractionDiagnostics.record("focus.bridge", "admission-skipped", ["attempted": String(attemptedKeyboardActivation), "explicit": String(explicitKeyboardEntry), "allowed": String(request.permitsKeyboardWithoutHover), "current": String(request.pointerInside)])
                }
            } else if panel.islandKeyboardOwner == ownerID || panel.islandKeyboardOwner == nil {
                let previouslyOwnedFocus = panel.allowsIslandKeyboard
                panel.islandKeyboardOwner = nil
                panel.allowsIslandKeyboard = false
                if panel.isKeyWindow && !panel.wantsKeyForTextInput && (previouslyOwnedFocus || panel.isIslandScreenLocked) { panel.releaseIslandKeyboard() }
            }
        }

        func invalidate() {
            generation &+= 1
            pending?.cancel()
            pending = nil
            request = nil
            explicitKeyboardEntry = false
            if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
            if let competingKeyboardObserver { NotificationCenter.default.removeObserver(competingKeyboardObserver) }
            keyboardObserver = nil
            competingKeyboardObserver = nil
            if let window = window ?? previousWindow { releaseKeyboard(in: window) }
            previousWindow = nil
        }

        private func releaseKeyboard(in window: NSWindow) {
            let ownerID = ownerID
            DispatchQueue.main.async { [weak window] in
                guard let panel = window as? BoringNotchSkyLightWindow,
                      panel.islandKeyboardOwner == ownerID else { return }
                panel.islandKeyboardOwner = nil
                panel.allowsIslandKeyboard = false
                if panel.isKeyWindow && !panel.wantsKeyForTextInput { panel.releaseIslandKeyboard() }
            }
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.receive(size: size, wantsKeyboard: wantsKeyboard,
                     permitsKeyboardWithoutHover: permitsKeyboardWithoutHover,
                     keyboardActivation: keyboardActivation, keyboardReady: keyboardReady, pointerInside: pointerInside)
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.invalidate() }
}
