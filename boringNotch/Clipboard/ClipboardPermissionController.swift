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
    private var alertReturnApplication: NSRunningApplication?
    private var terminationObserver: NSObjectProtocol?
    private var authorizationCheck: Task<Void, Never>?
    private var feedbackPanel: NSPanel?
    private var feedbackDismiss: DispatchWorkItem?
    private struct Waiter {
        let continuation: CheckedContinuation<ClipboardPasteAccess?, Never>
        let timeout: DispatchWorkItem
    }
    private var authorizationWaiters: [UUID: Waiter] = [:]
    private let requestedAXKey = "island.clipboardRequestedAccessibility"
    private let requestedPostKey = "island.clipboardRequestedPostEvents"

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
        guard let access = await checkPasteAccess(), gate.contains(token), !Task.isCancelled else {
            if gate.contains(token), !Task.isCancelled { showUnavailable(ifForeground: foreground) }
            return false
        }
        guard gate.contains(token), !Task.isCancelled else { return false }
        NSLog("[clipboard] access helper=%d ax=%d post=%d", access.processIdentifier, access.accessibility, access.postEvents)
        if access.canPaste { return ClipboardPermissionPolicy.mayPaste(wasAuthorized: true, requestedPermission: false) }
        requestPastePermission(access, ifForeground: foreground)
        return false
    }

    /// Copy/paste actions check existing authorization without opening a permission
    /// window. The already copied content stays ready for a manual Command-V.
    func pasteAccessWithoutPrompt() async -> ClipboardPasteAccess? {
        guard !terminating, !Task.isCancelled else { return nil }
        return await checkPasteAccess()
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
        guard let access = await checkPasteAccess(), gate.contains(token), !Task.isCancelled else {
            if gate.contains(token), !Task.isCancelled { showUnavailable(ifForeground: foreground) }
            return
        }
        ClipboardStore.shared.setPasteAccessNeeded(!access.canPaste)
        if !access.canPaste { requestPastePermission(access, ifForeground: foreground) }
    }

    func cancelRequests() {
        epoch = UUID()
        gate.cancel()
        closeAlert()
        feedbackDismiss?.cancel(); feedbackDismiss = nil
        feedbackPanel?.orderOut(nil); feedbackPanel = nil
        let waiters = Array(authorizationWaiters.values)
        authorizationWaiters.removeAll()
        for waiter in waiters {
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: nil)
        }
    }

    private func requestPastePermission(_ access: ClipboardPasteAccess, ifForeground foreground: pid_t?) {
        guard mayPresent(ifForeground: foreground) else { return }
        let permission: ClipboardPastePermission = access.accessibility ? .postEvents : .accessibility
        let key = permission == .accessibility ? requestedAXKey : requestedPostKey
        let requested = UserDefaults.standard.bool(forKey: key)
        switch ClipboardPermissionPolicy.decision(state: .undetermined, requestedBefore: requested, trigger: .user) {
        case .requestSystem:
            UserDefaults.standard.set(true, forKey: key)
            if permission == .postEvents {
                // CGRequestPostEventAccess may silently return false after a prior denial.
                // Keep this explicit operation visible even when no new system prompt is possible.
                showAlert(title: "允许发送粘贴按键", message: "请在“\(AccessibilityPermission.displayName)”中允许当前的 Boring Notch。授权后，回到目标输入框并重新打开剪贴板。",
                    primary: "打开设置", ifForeground: foreground) {
                        XPCHelperClient.shared.requestClipboardPasteAuthorization(.postEvents)
                        self.openSettings("Privacy_Accessibility")
                    }
            } else { XPCHelperClient.shared.requestClipboardPasteAuthorization(permission) }
        case .showSettings:
            let missing = permission == .accessibility ? "读取与恢复输入焦点" : "发送粘贴按键"
            showAlert(title: "允许自动粘贴", message: "尚未允许\(missing)。请在“\(AccessibilityPermission.displayName)”中允许当前的 Boring Notch。\n\n开关已打开仍失败时，请移除旧项目，再添加当前应用。授权后，回到目标输入框并重新打开剪贴板。",
                primary: "打开设置", ifForeground: foreground) {
                    XPCHelperClient.shared.requestClipboardPasteAuthorization(permission)
                    self.openSettings("Privacy_Accessibility")
                }
        default: break
        }
    }

    /// A failed automatic paste never makes the accessory app key or starts an alert.
    /// The user can immediately press Command-V in the restored destination.
    func explainPasteFailure(_ result: ClipboardPasteResult, copied: Bool = true) {
        let reason: String
        switch result {
        case .posted, .cancelled, .screenLocked: return
        case .unauthorized, .postEventUnauthorized:
            ClipboardStore.shared.setPasteAccessNeeded(true)
            reason = "自动粘贴需要辅助功能权限。请重新打开剪贴板，点击“允许自动粘贴”。"
        case .snapshotUnavailable: reason = "未能恢复原输入位置。"
        case .targetUnavailable: reason = "原应用已不可用。"
        case .focusChanged: reason = "输入位置已变化，自动粘贴已取消。"
        case .focusUnavailable: reason = "未能恢复键盘焦点。"
        case .inputHeld: reason = "按键或鼠标按钮尚未松开。"
        case .clipboardChanged: reason = "剪贴板已被其他复制操作更改。"
        case .eventFailure: reason = "系统未能完成自动粘贴。"
        }
        let message = reason + (copied && result != .clipboardChanged ? " 内容已复制，可按 ⌘V 手动粘贴。" : "")
        ClipboardStore.shared.reportPasteError(message)
        showFeedback(message)
    }

    func explainCopyFailure(_ message: String) {
        showFeedback(message)
    }

    private func showFeedback(_ message: String) {
        guard !terminating else { return }
        feedbackDismiss?.cancel()
        feedbackPanel?.orderOut(nil)
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 360
        let size = label.fittingSize
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 392, height: max(60, size.height + 28)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        label.frame = background.bounds.insetBy(dx: 16, dy: 14)
        background.addSubview(label)
        panel.contentView = background
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 50))
        }
        feedbackPanel = panel
        panel.orderFrontRegardless()
        let dismiss = DispatchWorkItem { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.feedbackPanel === panel { self?.feedbackPanel = nil; self?.feedbackDismiss = nil }
        }
        feedbackDismiss = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: dismiss)
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
        let prompt = ClipboardPermissionAlert.make(title: title, message: message,
            primary: primary, hasCancel: action != nil)
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
        if let foreground, foreground != ProcessInfo.processInfo.processIdentifier {
            alertReturnApplication = NSRunningApplication(processIdentifier: foreground)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    @objc private func alertButtonPressed(_ sender: NSButton) {
        let action = sender.tag == 0 && alertEpoch == epoch ? alertAction : nil
        closeAlert(restoreApplication: action == nil)
        action?()
    }
    private func closeAlert(restoreApplication: Bool = false) {
        let old = alert
        let returnApplication = alertReturnApplication
        alert = nil; alertEpoch = nil; alertAction = nil
        alertReturnApplication = nil
        old?.window.delegate = nil
        old?.window.orderOut(nil)
        old?.window.close()
        // Activating an accessory app for a permission/error dialog must not leave it as
        // the foreground destination of the next clipboard session. Never steal activation
        // back if the user already moved to a different app, or when opening Settings.
        if restoreApplication, !terminating,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let returnApplication, !returnApplication.isTerminated,
           NSApp.keyWindow == nil || NSApp.keyWindow is BoringNotchSkyLightWindow {
            BoringViewCoordinator.shared.releaseKeyboard()
            NSApp.yieldActivation(to: returnApplication)
            _ = returnApplication.activate(from: .current, options: [])
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, alert?.window === window else { return }
        alert = nil; alertEpoch = nil; alertAction = nil; alertReturnApplication = nil
    }

    /// One XPC probe is shared; each caller has a bounded deadline. A hung helper cannot leave
    /// paste busy forever or create an unbounded stream of abandoned helper requests.
    private func checkPasteAccess() async -> ClipboardPasteAccess? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                let timeout = DispatchWorkItem { [weak self] in self?.resolveAuthorizationWaiter(id, result: nil) }
                authorizationWaiters[id] = Waiter(continuation: continuation, timeout: timeout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
                if authorizationCheck == nil {
                    authorizationCheck = Task { @MainActor in
                        let result = await XPCHelperClient.shared.clipboardPasteAccess()
                        self.authorizationCheck = nil
                        let ids = Array(self.authorizationWaiters.keys)
                        for id in ids { self.resolveAuthorizationWaiter(id, result: result) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.resolveAuthorizationWaiter(id, result: nil) }
        }
    }
    private func resolveAuthorizationWaiter(_ id: UUID, result: ClipboardPasteAccess?) {
        guard let waiter = authorizationWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: result)
    }
}
