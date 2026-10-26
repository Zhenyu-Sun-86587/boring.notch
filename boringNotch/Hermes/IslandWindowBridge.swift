import AppKit
import SwiftUI

/// Diagnostic data only. This never participates in a layout or keyboard decision.
struct IslandGeometryTraceContext: Equatable {
    let targetSize: CGSize
    let selection: String
    let open: Bool
    let gestureProgress: CGFloat
    var measuredClosedSize: CGSize = .zero
    var measuredCompactSize: CGSize = .zero
}

/// Opt-in geometry JSONL, shared by the existing bridge anchor and keyboard handoff.
/// No text, titles, URLs, clipboard data, input events, or owner/session IDs are read.
@MainActor
enum IslandGeometryTrace {
    private static let byteLimit = 2 * 1_024 * 1_024
    private static var handle: FileHandle?
    private static var bytesWritten = 0
    private static var unavailable = false
    private static let startedAt = ProcessInfo.processInfo.systemUptime

    static let enabled: Bool = {
        ProcessInfo.processInfo.environment["BORING_GEOMETRY_TRACE"] == "1"
            || ProcessInfo.processInfo.arguments.contains("--island-geometry-trace")
            || UserDefaults.standard.bool(forKey: "island.geometryTraceEnabled")
    }()

    static var canRecord: Bool { enabled && !unavailable && bytesWritten < byteLimit }

    static var outputURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("boring-notch-geometry-\(ProcessInfo.processInfo.processIdentifier).jsonl")
    }

    @discardableResult
    static func record(_ event: String, window: NSWindow?, anchor: NSView? = nil,
                       generation: UInt? = nil, requestSize: CGSize? = nil,
                       wantsKeyboard: Bool? = nil, keyboardReady: Bool? = nil,
                       context: IslandGeometryTraceContext? = nil,
                       requestedWindowFrame: CGRect? = nil, flags: [String: Bool] = [:]) -> Bool {
        guard canRecord else { return false }
        var entry: [String: Any] = [
            "event": event,
            "elapsedMs": (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
        ]
        if let generation { entry["generation"] = generation }
        if let requestSize { entry["requestedViewport"] = size(requestSize) }
        if let wantsKeyboard { entry["wantsKeyboard"] = wantsKeyboard }
        if let keyboardReady { entry["keyboardReady"] = keyboardReady }
        if let requestedWindowFrame { entry["requestedWindowFrame"] = rect(requestedWindowFrame) }
        if !flags.isEmpty { entry["flags"] = flags }
        if let context {
            let knownSelections = ["home", "shelf", "hermes", "clipboard"]
            entry["surface"] = ["target": size(context.targetSize),
                "selection": knownSelections.contains(context.selection) ? context.selection : "other",
                "open": context.open, "gestureProgress": Double(context.gestureProgress),
                "measuredClosed": size(context.measuredClosedSize), "measuredCompact": size(context.measuredCompactSize)]
        }
        if let window {
            var geometry: [String: Any] = ["number": window.windowNumber,
                "frame": rect(window.frame), "contentLayoutRect": rect(window.contentLayoutRect),
                "visible": window.isVisible, "key": window.isKeyWindow,
                "level": window.level.rawValue, "collectionBehavior": window.collectionBehavior.rawValue]
            geometry["windowServer"] = windowServerTransform(window)
            if let responder = window.firstResponder {
                geometry["firstResponderClass"] = String(describing: type(of: responder))
            }
            if let screen = window.screen {
                geometry["screenFrame"] = rect(screen.frame)
                geometry["screenVisibleFrame"] = rect(screen.visibleFrame)
                geometry["screenSafeAreaTop"] = Double(screen.safeAreaInsets.top)
            }
            if let panel = window as? BoringNotchSkyLightWindow {
                geometry["handoffActive"] = panel.isIslandKeyboardHandoffActive
                geometry["allowsKeyboard"] = panel.allowsIslandKeyboard
                geometry["wantsTextInput"] = panel.wantsKeyForTextInput
            }
            entry["window"] = geometry
            if let content = window.contentView {
                entry["contentView"] = view(content, window: window)
                if anchor == nil,
                   let host = content.subviews.first(where: { String(describing: type(of: $0)).contains("NSHostingView") }) {
                    entry["hostingView"] = view(host, window: window)
                }
            }
        }
        if let anchor {
            entry["anchor"] = view(anchor, window: window)
            var ancestor = anchor.superview
            while let current = ancestor {
                if String(describing: type(of: current)).contains("NSHostingView") {
                    entry["hostingView"] = view(current, window: window)
                    break
                }
                ancestor = current.superview
            }
        }
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return false }
        data.append(0x0A)
        guard bytesWritten + data.count <= byteLimit else {
            unavailable = true
            try? handle?.close()
            handle = nil
            return false
        }
        do {
            if handle == nil {
                guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
                    unavailable = true
                    return false
                }
                handle = try FileHandle(forWritingTo: outputURL)
            }
            try handle?.write(contentsOf: data)
            bytesWritten += data.count
            return true
        } catch {
            unavailable = true
            try? handle?.close()
            handle = nil
            return false
        }
    }

    private static func size(_ value: CGSize) -> [Double] { [Double(value.width), Double(value.height)] }
    private static func rect(_ value: CGRect) -> [Double] {
        [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
    }
    private static func view(_ view: NSView, window: NSWindow?) -> [String: Any] {
        var geometry: [String: Any] = ["frame": rect(view.frame), "bounds": rect(view.bounds),
                                       "flipped": view.isFlipped]
        if let window, view.window === window {
            let windowRect = view.convert(view.bounds, to: nil)
            geometry["windowRect"] = rect(windowRect)
            geometry["screenRect"] = rect(window.convertToScreen(windowRect))
        }
        if let layer = view.layer {
            geometry["layerFrame"] = rect(layer.frame)
            geometry["layerBounds"] = rect(layer.bounds)
            if let presentation = layer.presentation() {
                geometry["presentationFrame"] = rect(presentation.frame)
                geometry["presentationBounds"] = rect(presentation.bounds)
            }
        }
        return geometry
    }

    private typealias Connection = @convention(c) () -> Int32
    private typealias ReadTransform = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGAffineTransform>) -> Int32
    // Resolved only after the opt-in guard in record. Missing private APIs must never
    // prevent ordinary geometry logging or change production window behavior.
    private static let windowServerReader: (UnsafeMutableRawPointer, Connection, ReadTransform)? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let connection = dlsym(library, "CGSMainConnectionID") ?? dlsym(library, "_CGSDefaultConnection"),
              let transform = dlsym(library, "CGSGetWindowTransform") else {
            dlclose(library)
            return nil
        }
        return (library, unsafeBitCast(connection, to: Connection.self), unsafeBitCast(transform, to: ReadTransform.self))
    }()

    private static func windowServerTransform(_ window: NSWindow) -> [String: Any] {
        guard window.windowNumber >= 0, let reader = windowServerReader else { return ["status": "unavailable"] }
        var transform = CGAffineTransform.identity
        let result = reader.2(reader.1(), UInt32(window.windowNumber), &transform)
        guard result == 0 else { return ["status": "error", "code": result] }
        return ["status": "available", "matrix": [Double(transform.a), Double(transform.b), Double(transform.c),
            Double(transform.d), Double(transform.tx), Double(transform.ty)]]
    }
}

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
        NotificationCenter.default.post(name: keyboardRequest, object: window)
    }

    let size: CGSize
    let wantsKeyboard: Bool
    var permitsKeyboardWithoutHover = false
    var keyboardActivation: String?
    var keyboardReady = true
    var traceContext: IslandGeometryTraceContext?

    @MainActor
    final class Anchor: NSView, IslandInteractionRegionProviding {
        private struct Request {
            let size: CGSize
            let wantsKeyboard: Bool
            let permitsKeyboardWithoutHover: Bool
            let keyboardActivation: String?
            let keyboardReady: Bool
            let traceContext: IslandGeometryTraceContext?
        }
        private let ownerID = UUID()
        private var request: Request?
        private var generation: UInt = 0
        private var pending: DispatchWorkItem?
        private weak var previousWindow: NSWindow?
        private var attemptedKeyboardActivation = false
        private var explicitKeyboardEntry = false
        private var explicitKeyboardDeadline: TimeInterval = 0
        private var keyboardObserver: NSObjectProtocol?
        private var competingKeyboardObserver: NSObjectProtocol?
        private var traceTimer: DispatchSourceTimer?
        private var traceDeadline: TimeInterval = 0
        private var tracePendingApply = false

        deinit { traceTimer?.cancel() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func receive(size: CGSize, wantsKeyboard: Bool, permitsKeyboardWithoutHover: Bool,
                     keyboardActivation: String? = nil, keyboardReady: Bool = true,
                     traceContext: IslandGeometryTraceContext? = nil) {
            let traceChanged = request?.size != size || request?.wantsKeyboard != wantsKeyboard
                || request?.keyboardActivation != keyboardActivation || request?.traceContext != traceContext
            if !wantsKeyboard, request?.wantsKeyboard == true { explicitKeyboardEntry = false }
            if !wantsKeyboard || request?.wantsKeyboard != true
                || request?.keyboardActivation != keyboardActivation {
                attemptedKeyboardActivation = false
            }
            request = Request(size: size, wantsKeyboard: wantsKeyboard,
                              permitsKeyboardWithoutHover: permitsKeyboardWithoutHover,
                              keyboardActivation: keyboardActivation, keyboardReady: keyboardReady,
                              traceContext: traceContext)
            schedule()
            if traceChanged {
                tracePendingApply = IslandGeometryTrace.enabled
                startTraceSampling()
                trace("receive")
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
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
                        self.startTraceSampling()
                        self.trace("keyboard.request")
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
                        self.attemptedKeyboardActivation = true
                        self.explicitKeyboardEntry = false
                        self.explicitKeyboardDeadline = 0
                        self.startTraceSampling()
                        self.trace("keyboard.competitor")
                    }
                }
            }
            previousWindow = window
            schedule()
            trace("movedToWindow")
            if window == nil { stopTraceSampling() }
            else if request != nil { startTraceSampling() }
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
            var traceApply = tracePendingApply
            tracePendingApply = false
            if traceApply { trace("apply.begin", request: request, window: window) }
            defer { if traceApply { trace("apply.end", request: request, window: window) } }
            guard let screen = window.screen,
                  request.size.width.isFinite, request.size.height.isFinite,
                  request.size.width > 0, request.size.height > 0 else { return }
            let scale = max(1, screen.backingScaleFactor)
            func pixelAligned(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
            let frame = NSRect(x: pixelAligned(screen.frame.midX - request.size.width / 2),
                               y: pixelAligned(screen.frame.maxY - request.size.height),
                               width: pixelAligned(request.size.width), height: pixelAligned(request.size.height))
            if traceApply { trace("frame.request", request: request, window: window, requestedWindowFrame: frame) }
            // WindowServer may round an origin to whole points even on Retina.
            // Accept that half-point difference instead of repeatedly correcting it.
            let tolerance: CGFloat = 0.5
            let current = window.frame
            if abs(current.minX - frame.minX) > tolerance || abs(current.minY - frame.minY) > tolerance
                || abs(current.width - frame.width) > tolerance || abs(current.height - frame.height) > tolerance {
                startTraceSampling()
                traceApply = IslandGeometryTrace.enabled
                trace("frame.write", request: request, window: window, requestedWindowFrame: frame)
                // AppKit will schedule its normal display/layout pass. Never force a
                // synchronous display while SwiftUI is updating its view hierarchy.
                window.setFrame(frame, display: false)
            }
            guard let panel = window as? BoringNotchSkyLightWindow,
                  !panel.isIslandKeyboardHandoffActive else { return }
            if request.wantsKeyboard && !panel.isIslandScreenLocked && panel.isVisible {
                guard request.keyboardReady else { return }
                // Admission happens once per explicit opening/tab/session. A
                // streamed answer or layout update must not steal key status
                // back from Settings, a permission alert or another app.
                if !attemptedKeyboardActivation
                    && ((explicitKeyboardEntry && ProcessInfo.processInfo.systemUptime < explicitKeyboardDeadline)
                        || request.permitsKeyboardWithoutHover || frame.contains(NSEvent.mouseLocation)) {
                    startTraceSampling()
                    traceApply = IslandGeometryTrace.enabled
                    trace("keyboard.admit", request: request, window: window)
                    attemptedKeyboardActivation = true
                    explicitKeyboardEntry = false
                    panel.islandKeyboardOwner = ownerID
                    panel.allowsIslandKeyboard = true
                    if !panel.isKeyWindow { panel.makeKey() }
                }
            } else if panel.islandKeyboardOwner == ownerID || panel.islandKeyboardOwner == nil {
                let previouslyOwnedFocus = panel.allowsIslandKeyboard
                if previouslyOwnedFocus || panel.isKeyWindow {
                    startTraceSampling()
                    traceApply = IslandGeometryTrace.enabled
                    trace("keyboard.release", request: request, window: window)
                }
                panel.islandKeyboardOwner = nil
                panel.allowsIslandKeyboard = false
                if panel.isKeyWindow && !panel.wantsKeyForTextInput && (previouslyOwnedFocus || panel.isIslandScreenLocked) { panel.releaseIslandKeyboard() }
            }
        }

        func invalidate() {
            trace("invalidate")
            stopTraceSampling()
            generation &+= 1
            pending?.cancel()
            pending = nil
            request = nil
            tracePendingApply = false
            explicitKeyboardEntry = false
            if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
            if let competingKeyboardObserver { NotificationCenter.default.removeObserver(competingKeyboardObserver) }
            keyboardObserver = nil
            competingKeyboardObserver = nil
            if let window = window ?? previousWindow { releaseKeyboard(in: window) }
            previousWindow = nil
        }

        private func trace(_ event: String, request tracedRequest: Request? = nil,
                           window tracedWindow: NSWindow? = nil, requestedWindowFrame: CGRect? = nil) {
            guard IslandGeometryTrace.canRecord,
                  ProcessInfo.processInfo.systemUptime < traceDeadline
                    || ["sampling.begin", "sampling.end", "movedToWindow", "invalidate"].contains(event) else { return }
            let request = tracedRequest ?? self.request
            IslandGeometryTrace.record(event, window: tracedWindow ?? window, anchor: self,
                generation: generation, requestSize: request?.size, wantsKeyboard: request?.wantsKeyboard,
                keyboardReady: request?.keyboardReady, context: request?.traceContext,
                requestedWindowFrame: requestedWindowFrame)
        }

        private func startTraceSampling() {
            guard IslandGeometryTrace.canRecord, window != nil else { return }
            traceDeadline = ProcessInfo.processInfo.systemUptime + 0.8
            guard traceTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard IslandGeometryTrace.canRecord, self.window != nil,
                          ProcessInfo.processInfo.systemUptime < self.traceDeadline else {
                        self.stopTraceSampling()
                        return
                    }
                    self.trace("sample")
                }
            }
            traceTimer = timer
            trace("sampling.begin")
            timer.resume()
        }

        private func stopTraceSampling() {
            guard let traceTimer else { return }
            traceTimer.cancel()
            self.traceTimer = nil
            trace("sampling.end")
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
                     keyboardActivation: keyboardActivation, keyboardReady: keyboardReady,
                     traceContext: traceContext)
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.invalidate() }
}
