//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import AppKit
import ApplicationServices
import IOKit

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    private weak var connection: NSXPCConnection?

    private let lunarStateQueue = DispatchQueue(label: "BoringNotchXPCHelper.lunar.state")
    private let lunarExecutableURL = URL(fileURLWithPath: "/Applications/Lunar.app/Contents/MacOS/Lunar")
    private var lunarProcess: Process?
    private var lunarPipeHandler: JSONLinesPipeHandler?
    private var lunarStreamTask: Task<Void, Never>?
    private var lunarListener: BoringNotchXPCHelperLunarListener?

    init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    override init() {
        super.init()
    }

    deinit {
        var processToTerminate: Process?
        var taskToCancel: Task<Void, Never>?
        var pipeHandlerToClose: JSONLinesPipeHandler?

        lunarStateQueue.sync {
            processToTerminate = self.lunarProcess
            self.lunarProcess = nil

            taskToCancel = self.lunarStreamTask
            self.lunarStreamTask = nil

            pipeHandlerToClose = self.lunarPipeHandler
            self.lunarPipeHandler = nil

            self.lunarListener = nil
        }

        taskToCancel?.cancel()
        if let p = processToTerminate, p.isRunning { p.terminate() }
        if let ph = pipeHandlerToClose {
            Task { await ph.close() }
        }
    }

    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @MainActor private static let clipboardPaster = ClipboardPasteCoordinator()
    @MainActor private static let clipboardTargets = ClipboardPasteTargets()

    @objc func clipboardPasteAccess(with reply: @escaping (Data) -> Void) {
        let access = ClipboardPasteAccess(accessibility: AXIsProcessTrusted(), postEvents: CGPreflightPostEventAccess(),
            processIdentifier: ProcessInfo.processInfo.processIdentifier, bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            guiSessionAvailable: CGSessionCopyCurrentDictionary() != nil)
        reply((try? JSONEncoder().encode(access)) ?? Data())
    }

    @objc func requestClipboardPasteAuthorization(_ permission: String) {
        DispatchQueue.main.async {
            switch ClipboardPastePermission(rawValue: permission) {
            case .accessibility: self.requestAccessibilityAuthorization()
            case .postEvents: _ = CGRequestPostEventAccess()
            case nil: break
            }
        }
    }

    @objc func captureClipboardTarget(_ targetPID: Int32, with reply: @escaping (Data?) -> Void) {
        DispatchQueue.main.async {
            let target = Self.clipboardTargets.capture(targetPID)
            reply(target.flatMap { try? JSONEncoder().encode($0) })
        }
    }

    @objc func releaseClipboardTarget(_ token: String) {
        DispatchQueue.main.async { Self.clipboardTargets.release(token) }
    }

    /// The host first orders its panel out. Verify the actual keyboard owner,
    /// physical key/button release and unchanged pasteboard before posting once.
    @objc func pasteClipboard(toProcessIdentifier targetPID: Int32, hostProcessIdentifier hostPID: Int32,
                              pasteboardChangeCount: Int, targetToken: String?, requestID: String, with reply: @escaping (String) -> Void) {
        // A noninteractive transport probe uses an invalid PID. It must not read
        // the pasteboard, inspect focus, prompt for access or post any event.
        guard targetPID > 0 else { reply(ClipboardPasteResult.targetUnavailable.rawValue); return }
        DispatchQueue.main.async {
            Task { @MainActor in
                let access = ClipboardPasteAccess(accessibility: AXIsProcessTrusted(), postEvents: CGPreflightPostEventAccess(),
                    processIdentifier: ProcessInfo.processInfo.processIdentifier, bundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                guard access.accessibility else { reply(ClipboardPasteResult.unauthorized.rawValue); return }
                guard access.postEvents else { reply(ClipboardPasteResult.postEventUnauthorized.rawValue); return }
                // Tokens are optional AX enhancements. XPC restarts discard their in-memory
                // records; native app activation remains a usable clipboard destination.
                let original = Self.clipboardTargets.record(targetToken, pid: targetPID)
                defer { if let original { Self.clipboardTargets.release(original.descriptor.token) } }
                let systemWide = AXUIElementCreateSystemWide()
                AXUIElementSetMessagingTimeout(systemWide, 0.05)
                var restoreAttempts = 0
                var focusLease = ClipboardFocusRestoration.Lease()
                var restorationAvailable = true
                var nativeFallbackSeen = false
                @MainActor func observe() -> ClipboardPasteObservation {
                    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    var assessment = focusLease.assess(original.map {
                        Self.clipboardTargets.evidence($0, restorationAvailable: restorationAvailable)
                    } ?? .init())
                    if foreground == targetPID, let original, assessment.mayRestore, restoreAttempts < 3,
                       restoreAttempts == 0 || !assessment.inputReady {
                        restorationAvailable = Self.clipboardTargets.restore(original, assessment: assessment)
                        restoreAttempts += 1
                        assessment = focusLease.assess(Self.clipboardTargets.evidence(original,
                            restorationAvailable: restorationAvailable))
                    }
                    if restoreAttempts >= 3, assessment.match == .matched, !assessment.inputReady, let original {
                        restorationAvailable = false
                        assessment = focusLease.assess(Self.clipboardTargets.evidence(original, restorationAvailable: false))
                    }
                    var focused: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focused)
                    var focusedPID: pid_t?
                    if error == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                        var pid: pid_t = 0
                        if AXUIElementGetPid(focused as! AXUIElement, &pid) == .success { focusedPID = pid }
                    }
                    nativeFallbackSeen = nativeFallbackSeen || assessment.match == .unknown || focusedPID == nil
                    let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
                    let released = CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty
                        && ![CGKeyCode(36), 76, 9].contains { CGEventSource.keyState(.hidSystemState, key: $0) }
                        && !CGEventSource.buttonState(.hidSystemState, button: .left)
                    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
                    return ClipboardPasteObservation(authorized: access.accessibility, postEventAuthorized: access.postEvents,
                        // A missing GUI session is not evidence of a locked display.
                        // Both states block input, but only a real lock is silently cancelled.
                        unlocked: session?["CGSSessionScreenIsLocked"] as? Bool != true,
                        sessionAvailable: session != nil,
                        targetAlive: targetPID > 0 && NSRunningApplication(processIdentifier: targetPID)?.isTerminated == false,
                        clipboardUnchanged: NSPasteboard.general.changeCount == pasteboardChangeCount,
                        foregroundPID: foreground,
                        focusedPID: focusedPID,
                        // Some Qt/custom applications expose no usable focus tree,
                        // including noValue/cannotComplete or a missing PID. An
                        // explicit different PID remains a firm focus mismatch.
                        focusProbeAvailable: focusedPID != nil,
                        inputReleased: released).withFocusAssessment(assessment)
                }
                let result = await Self.clipboardPaster.perform(requestID: requestID, targetPID: targetPID, hostPID: hostPID,
                    environment: .init(observe: observe, post: {
                        let fallbackWasAlreadyObserved = nativeFallbackSeen
                        let current = observe()
                        // No event has been sent. A first unknown final probe returns to
                        // the same request's longer native settling before its single pair.
                        guard !(current.requiresNativeStability || !current.focusProbeAvailable) || fallbackWasAlreadyObserved else { return .requiresNativeStability }
                        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), current.unlocked, current.targetAlive,
                              current.clipboardUnchanged, current.inputReleased, current.foregroundPID == targetPID,
                              current.originalTargetUnchanged, current.originalInputReady,
                              current.focusedPID == targetPID || !current.focusProbeAvailable else { return .failed }
                        return ClipboardPasteEvent.post(to: targetPID) ? .posted : .failed
                    }))
                NSLog("[clipboard] helper request=%@ result=%@ target=%d ax=%d post=%d window=%d element=%d restoreAttempts=%d", requestID, result.rawValue,
                    targetPID, access.accessibility, access.postEvents, original?.descriptor.hasWindow == true, original?.descriptor.hasElement == true, restoreAttempts)
                reply(result.rawValue)
            }
        }
    }

    @objc func cancelClipboardPaste(_ requestID: String) {
        DispatchQueue.main.async { Self.clipboardPaster.cancel(requestID) }
    }

    @objc func migrateLegacyAppBundle(
        from sourcePath: String,
        to destinationPath: String,
        with reply: @escaping (Bool) -> Void
    ) {
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
        let fileManager = FileManager.default

        guard sourceURL.lastPathComponent == BoringNotchAppBundleNames.legacy,
              destinationURL.lastPathComponent == BoringNotchAppBundleNames.current,
              sourceURL.deletingLastPathComponent() == destinationURL.deletingLastPathComponent(),
              fileManager.fileExists(atPath: sourceURL.path),
              !fileManager.fileExists(atPath: destinationURL.path)
        else {
            NSLog("[boringNotch] refused legacy bundle migration for %@ -> %@", sourcePath, destinationPath)
            reply(false)
            return
        }

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            NSWorkspace.shared.noteFileSystemChanged(destinationURL.deletingLastPathComponent().path)
            reply(true)
        } catch {
            NSLog("[boringNotch] legacy bundle migration failed for %@: %@", sourcePath, error.localizedDescription)
            reply(false)
        }
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        guard promptIfNeeded else {
            reply(false)
            return
        }

        requestAccessibilityAuthorization()

        let deadline = DispatchTime.now() + .seconds(15)
        func waitForAuthorization() {
            if AXIsProcessTrusted() {
                reply(true)
            } else if DispatchTime.now() >= deadline {
                reply(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    waitForAuthorization()
                }
            }
        }
        waitForAuthorization()
    }

    // MARK: - Notification Center banners

    private static let watcher = NotificationWatcher()

    @objc func startNotificationWatching(with reply: @escaping (Bool) -> Void) {
        // Capture the delegate for this connection before hopping queues —
        // NSXPCConnection.current() is only valid inside the incoming call.
        //
        // Cast to BoringNotchXPCAppDelegate, not its parent protocol: the
        // proxy's conformance is built from the exact interface the
        // connection was configured with, so casting to the parent can
        // return nil and silently swallow every callback.
        let connection = NSXPCConnection.current()
        let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
            NSLog("[boringNotch] notification callback failed: \(error.localizedDescription)")
        }
        let delegate = proxy as? BoringNotchXPCAppDelegate

        if delegate == nil {
            NSLog("[boringNotch] could not obtain notification delegate proxy — banners will not reach the app")
        }

        DispatchQueue.main.async {
            let watcher = Self.watcher
            watcher.onBanner = { notification in
                delegate?.notificationDidAppear([
                    "token": notification.token,
                    "appName": notification.appName ?? "",
                    "bundleID": notification.bundleID ?? "",
                    "title": notification.title ?? "",
                    "subtitle": notification.subtitle ?? "",
                    "body": notification.body ?? ""
                ])
            }
            let started = watcher.start()
            NSLog("[boringNotch] notification watcher start -> \(started), AX trusted: \(AXIsProcessTrusted())")
            reply(started)
        }
    }

    @objc func stopNotificationWatching() {
        DispatchQueue.main.async { Self.watcher.stop() }
    }

    @objc func setNotificationFilter(_ bundleIDs: [String], allApps: Bool) {
        DispatchQueue.main.async {
            Self.watcher.configureFilter(bundleIDs: Set(bundleIDs), allApps: allApps)
        }
    }
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    private func brightnessDisplayID() -> CGDirectDisplayID {
        let mainDisplayID = CGMainDisplayID()
        var tmp: Float = 0

        if displayServicesGetBrightness(displayID: mainDisplayID, out: &tmp) || ioServiceFor(displayID: mainDisplayID) != nil {
            return mainDisplayID
        }

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        let allocated = Int(count)
        var ids = [CGDirectDisplayID](repeating: 0, count: allocated)
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids {
            if CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }

        return mainDisplayID
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        let displayID = brightnessDisplayID()
        var b: Float = 0
        if displayServicesGetBrightness(displayID: displayID, out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        let displayID = brightnessDisplayID()
        if displayServicesSetBrightness(displayID: displayID, value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    @objc func adjustScreenBrightness(by value: Float, with reply: @escaping (NSNumber?) -> Void) {
        let displayID = brightnessDisplayID()
        if displayServicesSetBrightnessSmooth(displayID: displayID, value: value) {
            // Read back inside the helper so the client pays for one RPC
            // instead of two (adjust + currentScreenBrightness).
            var b: Float = 0
            if displayServicesGetBrightness(displayID: displayID, out: &b) {
                reply(NSNumber(value: b))
                return
            }
            reply(nil)
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            var ioCurrent: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &ioCurrent) == kIOReturnSuccess {
                let target = max(0, min(1, ioCurrent + value))
                let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, target) == kIOReturnSuccess
                IOObjectRelease(io)
                reply(ok ? NSNumber(value: target) : nil)
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    // MARK: - Lunar Events

    @objc func displayIDForBrightness(with reply: @escaping (NSNumber?) -> Void) {
        let id = brightnessDisplayID()
        reply(NSNumber(value: id))
    }

    @objc func isLunarAvailable(with reply: @escaping (Bool) -> Void) {
        reply(FileManager.default.isExecutableFile(atPath: lunarExecutableURL.path))
    }

    @objc func startLunarEventStream(with reply: @escaping (Bool) -> Void) {
        lunarStateQueue.async { [weak self] in
            guard let self else {
                reply(false)
                return
            }

            if let lunarProcess = self.lunarProcess, lunarProcess.isRunning {
                reply(true)
                return
            }

            guard FileManager.default.isExecutableFile(atPath: self.lunarExecutableURL.path) else {
                reply(false)
                return
            }

            guard let connection = self.connection else {
                reply(false)
                return
            }

            let listenerProxy = connection.remoteObjectProxyWithErrorHandler { _ in
                self.stopLunarEventStream()
            } as? BoringNotchXPCHelperLunarListener

            guard let listenerProxy else {
                reply(false)
                return
            }

            let process = Process()
            process.executableURL = self.lunarExecutableURL
            process.arguments = ["@", "listen", "--only-user-adjustments", "-j"]

            let pipeHandler = JSONLinesPipeHandler()
            process.standardOutput = pipeHandler.outputPipe
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { [weak self] _ in
                self?.stopLunarEventStream(reason: "Lunar stream ended")
            }

            do {
                try process.run()
            } catch {
                reply(false)
                return
            }

            self.lunarProcess = process
            self.lunarPipeHandler = pipeHandler
            self.lunarListener = listenerProxy

            let currentPipeHandler = pipeHandler
            self.lunarStreamTask = Task { [weak self] in
                await self?.readLunarEvents(pipeHandler: currentPipeHandler)
            }

            reply(true)
        }
    }

    @objc func stopLunarEventStream() {
        stopLunarEventStream(reason: nil)
    }

    private func stopLunarEventStream(reason: String?) {
        lunarStateQueue.async { [weak self] in
            guard let self else { return }

            self.lunarStreamTask?.cancel()
            self.lunarStreamTask = nil

            if let lunarProcess = self.lunarProcess, lunarProcess.isRunning {
                lunarProcess.terminate()
            }

            self.lunarProcess = nil

            if let pipeHandler = self.lunarPipeHandler {
                pipeHandler.close()
            }

            self.lunarPipeHandler = nil

            if let reason {
                self.lunarListener?.lunarStreamDidStop(reason)
            }

            self.lunarListener = nil
        }
    }

    private func readLunarEvents(pipeHandler: JSONLinesPipeHandler) async {
        await pipeHandler.readJSONLines(as: LunarBrightnessEvent.self) { [weak self] event in
            self?.emitLunarEvent(event)
        }
    }

    private func emitLunarEvent(_ event: LunarBrightnessEvent) {
        let payload = BNLunarBrightnessEvent(
            brightness: event.brightness,
            display: event.display
        )
        lunarStateQueue.async { [weak self] in
            self?.lunarListener?.lunarEventDidUpdate(payload)
        }
    }

    // MARK: - Lunar OSD preference (hideOSD)

    private static let lunarBundleID = "fyi.lunar.Lunar"
    private static let lunarHideOSDKey = "hideOSD"

    @objc func setLunarOSDHidden(_ hide: Bool, with reply: @escaping (Bool) -> Void) {
        let appID = Self.lunarBundleID as CFString
        let key = Self.lunarHideOSDKey as CFString
        let value = hide as CFBoolean
        NSLog("Hide OSD in Lunar: \(hide)")
        CFPreferencesSetValue(key, value, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let ok = CFPreferencesSynchronize(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        reply(ok)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func displayServicesSetBrightnessSmooth(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightnessSmooth") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}

// MARK: - Lunar Parsing

private struct LunarBrightnessEvent: Decodable, Sendable {
    let brightness: Double
    let display: Int
}
