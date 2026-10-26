import AppKit
import IslandCore

/// All permission entry points share one coordinator. Native alerts are ordinary, asynchronous
/// windows: no competing SwiftUI alert presenters and no modal session on a notch panel.
@MainActor
final class ClipboardPermissionController: NSObject, NSWindowDelegate {
    static let shared = ClipboardPermissionController()
    private var gate = ClipboardPermissionRequestGate()
    private var epoch = UUID()
    private var terminating = false
    private var alert: NSAlert?
    private var alertEpoch: UUID?
    private var alertAction: (() -> Void)?
    private var terminationObserver: NSObjectProtocol?
    private var authorizationCheck: Task<Void, Never>?
    private struct Waiter {
        let continuation: CheckedContinuation<Bool?, Never>
        let timeout: DispatchWorkItem
    }
    private var authorizationWaiters: [UUID: Waiter] = [:]
    private let requestedAXKey = "island.clipboardRequestedAccessibility"

    private override init() {
        super.init()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.terminating = true; self?.cancelRequests() }
            }
    }

    /// A permission dialog never resumes a previous paste. Only an already-authorized check
    /// returns true; callers must finish the current paste action on false and require a new click.
    func ensurePasteAccess() async -> Bool {
        guard !terminating, alert == nil, let token = gate.begin() else { return false }
        defer { gate.finish(token) }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let authorized = await checkAccessibility(), gate.contains(token), !Task.isCancelled else {
            if gate.contains(token), !Task.isCancelled { showUnavailable(ifForeground: foreground) }
            return false
        }
        guard gate.contains(token), !Task.isCancelled else { return false }
        if authorized { return ClipboardPermissionPolicy.mayPaste(wasAuthorized: true, requestedPermission: false) }
        requestAccessibility(ifForeground: foreground)
        return false
    }

    /// Read access is requested first. If it needs Settings, the user completes that step before
    /// the control-permission request; actual paste operations also independently request control.
    func requestOnEnable(readState: () -> ClipboardPermissionPolicy.State,
                         requestRead: () -> ClipboardPermissionPolicy.State) async {
        guard !terminating, alert == nil, let token = gate.begin() else { return }
        defer { gate.finish(token) }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // The system reports pasteboard ask/deny directly; unlike AX, no local request flag is
        // needed to infer whether a system request remains possible.
        switch ClipboardPermissionPolicy.decision(state: readState(), requestedBefore: false, trigger: .user) {
        case .proceed: break
        case .requestSystem:
            // Reading is an explicit user action, independent of any background capture in flight.
            let result = requestRead()
            guard gate.contains(token), !Task.isCancelled else { return }
            guard result == .authorized else {
                switch result {
                case .ask, .denied:
                    showReadSettings(ifForeground: foreground)
                case .undetermined:
                    showAlert(title: "允许读取剪贴板", message: "请先复制一段文字或图片，再重试授权。", primary: "好", ifForeground: foreground)
                case .unavailable:
                    showAlert(title: "无法读取剪贴板", message: "请稍后重试。", primary: "好", ifForeground: foreground)
                case .authorized: break
                }
                return
            }
        case .showSettings:
            showReadSettings(ifForeground: foreground)
            return
        case .showUnavailable, .skip: return
        }
        guard let authorized = await checkAccessibility(), gate.contains(token), !Task.isCancelled else {
            if gate.contains(token), !Task.isCancelled { showUnavailable(ifForeground: foreground) }
            return
        }
        if !authorized { requestAccessibility(ifForeground: foreground) }
    }

    func cancelRequests() {
        epoch = UUID()
        gate.cancel()
        closeAlert()
        let waiters = Array(authorizationWaiters.values)
        authorizationWaiters.removeAll()
        for waiter in waiters {
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: nil)
        }
    }

    private func requestAccessibility(ifForeground foreground: pid_t?) {
        guard mayPresent(ifForeground: foreground) else { return }
        let requested = UserDefaults.standard.bool(forKey: requestedAXKey)
        switch ClipboardPermissionPolicy.decision(state: .undetermined, requestedBefore: requested, trigger: .user) {
        case .requestSystem:
            UserDefaults.standard.set(true, forKey: requestedAXKey)
            XPCHelperClient.shared.requestAccessibilityAuthorization()
        case .showSettings:
            showAlert(title: "允许自动粘贴", message: "请在系统设置的“\(AccessibilityPermission.displayName)”中允许当前版本。授权后，请重新选择要粘贴的内容。",
                primary: "打开设置", ifForeground: foreground) {
                    self.openSettings("Privacy_Accessibility")
                }
        default: break
        }
    }
    private func showReadSettings(ifForeground foreground: pid_t?) {
        showAlert(title: "允许读取剪贴板", message: "请在系统设置中将 Boring Notch 的剪贴板访问设为“始终允许”。",
            primary: "打开设置", ifForeground: foreground) { self.openSettings("Privacy_Pasteboard") }
    }
    private func showUnavailable(ifForeground foreground: pid_t?) {
        showAlert(title: "无法检查控制权限", message: "辅助进程未响应，请稍后重试。", primary: "好", ifForeground: foreground)
    }
    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
    private func mayPresent(ifForeground foreground: pid_t?) -> Bool {
        guard !terminating else { return false }
        let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return current == foreground || current == ProcessInfo.processInfo.processIdentifier
    }

    private func showAlert(title: String, message: String, primary: String, ifForeground foreground: pid_t?, action: (() -> Void)? = nil) {
        guard alert == nil, mayPresent(ifForeground: foreground) else { return }
        let prompt = NSAlert()
        prompt.messageText = title
        prompt.informativeText = message
        prompt.alertStyle = .informational
        prompt.addButton(withTitle: primary)
        if action != nil { prompt.addButton(withTitle: "取消") }
        let window = prompt.window
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self
        // Override the alert buttons' modal-session actions; this alert never starts a modal loop.
        for (index, button) in prompt.buttons.enumerated() {
            button.target = self
            button.action = #selector(alertButtonPressed(_:))
            button.tag = index
            button.keyEquivalent = index == 0 ? "\r" : "\u{1b}"
        }
        alert = prompt
        alertEpoch = epoch
        alertAction = action
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    @objc private func alertButtonPressed(_ sender: NSButton) {
        let action = sender.tag == 0 && alertEpoch == epoch ? alertAction : nil
        closeAlert()
        action?()
    }
    private func closeAlert() {
        let old = alert
        alert = nil; alertEpoch = nil; alertAction = nil
        old?.window.delegate = nil
        old?.window.orderOut(nil)
        old?.window.close()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, alert?.window === window else { return }
        alert = nil; alertEpoch = nil; alertAction = nil
    }

    /// One XPC probe is shared; each caller has a bounded deadline. A hung helper cannot leave
    /// paste busy forever or create an unbounded stream of abandoned helper requests.
    private func checkAccessibility() async -> Bool? {
        await withCheckedContinuation { continuation in
            let id = UUID()
            let timeout = DispatchWorkItem { [weak self] in self?.resolveAuthorizationWaiter(id, result: nil) }
            authorizationWaiters[id] = Waiter(continuation: continuation, timeout: timeout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
            if authorizationCheck == nil {
                authorizationCheck = Task { @MainActor in
                    let value = await XPCHelperClient.shared.isAccessibilityAuthorized()
                    let result = XPCHelperClient.shared.helperAvailable ? value : nil
                    self.authorizationCheck = nil
                    let ids = Array(self.authorizationWaiters.keys)
                    for id in ids { self.resolveAuthorizationWaiter(id, result: result) }
                }
            }
        }
    }
    private func resolveAuthorizationWaiter(_ id: UUID, result: Bool?) {
        guard let waiter = authorizationWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: result)
    }
}
