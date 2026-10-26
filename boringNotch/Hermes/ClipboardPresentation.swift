import AppKit
import Combine
import Defaults
import IslandCore
import SwiftUI

/// One notch page serves pointer and keyboard entry; only the latter pins it open.
@MainActor
final class ClipboardPresentation: ObservableObject {
    static let shared = ClipboardPresentation()
    @Published private(set) var keyboardScreenUUID: String?
    private weak var windowManager: NotchWindowManager?
    private var observers: [NSObjectProtocol] = []
    private var visibility = ClipboardVisibilityState()
    private var ownerWindows: [UUID: ObjectIdentifier] = [:]
    private var sessionPresented = false
    private var previousView: NotchViews = .home
    private var pasteTask: Task<Void, Never>?
    private var pasteActionID: UUID?
    private var suspendedPanels: [(BoringNotchSkyLightWindow, UUID)] = []

    func configure(windowManager: NotchWindowManager) {
        self.windowManager = windowManager
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("ClipboardPasteRequested"), object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?["targetPID"] as? NSNumber)?.int32Value
            let sessionID = note.userInfo?["sessionID"] as? String
            let changeCount = note.userInfo?["changeCount"] as? Int
            Task { @MainActor in self?.paste(to: pid, sessionID: sessionID, changeCount: changeCount) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("ClipboardDismissRequested"), object: nil, queue: .main) { [weak self] note in
            let sessionID = note.userInfo?["sessionID"] as? String
            Task { @MainActor in
                guard sessionID == ClipboardStore.shared.sessionID.uuidString else { return }
                self?.dismiss()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.windowWillClose(window) }
        })
    }

    func toggle() {
        guard let manager = windowManager, !manager.isScreenLocked,
              !BoringViewCoordinator.shared.firstLaunch else { return }
        if ClipboardStore.shared.keyboardSessionActive {
            dismiss()
            return
        }
        cancelPendingPaste()
        sessionPresented = true
        let target = NSWorkspace.shared.frontmostApplication
        ClipboardStore.shared.beginSession(target: target)
        previousView = BoringViewCoordinator.shared.currentView == .clipboard ? .home : BoringViewCoordinator.shared.currentView
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let screenID = pointerScreen?.displayUUID
        let viewModel: BoringViewModel
        let panel: NSWindow?
        if Defaults[.displayMode] == .allDisplays, let id = screenID, let context = manager.contexts[id] {
            viewModel = context.viewModel
            panel = context.window
        } else {
            viewModel = manager.primaryViewModel
            panel = manager.primaryWindow
        }
        keyboardScreenUUID = viewModel.screenUUID
        ClipboardStore.shared.keyboardSessionActive = true
        BoringViewCoordinator.shared.currentView = .clipboard
        viewModel.open()
        if let panel = panel as? BoringNotchSkyLightWindow {
            panel.allowsIslandKeyboard = true
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    /// Called with the view's current state, not a queued transition's old value.
    func updateVisibility(owner: UUID, screenUUID: String?, visible: Bool) {
        let isVisible = visible && windowManager?.isScreenLocked == false
            && BoringViewCoordinator.shared.currentView == .clipboard
        let ownedMouse = visibility.mouseOwner == owner
        let previousScreen = visibility.visibleOwners[owner]
        visibility.setVisible(isVisible, owner: owner, screen: screenUUID)
        if isVisible, let previousScreen, keyboardScreenUUID == previousScreen, let screenUUID {
            keyboardScreenUUID = screenUUID
        }
        if isVisible, let screenUUID, let window = window(on: screenUUID) {
            ownerWindows[owner] = ObjectIdentifier(window)
        } else { ownerWindows.removeValue(forKey: owner) }

        if !isVisible && ownedMouse { cancelPendingPaste() }
        if !isVisible, let previousScreen, keyboardScreenUUID == previousScreen,
           !visibility.contains(screen: previousScreen) {
            cancelPendingPaste()
            keyboardScreenUUID = nil
            ClipboardStore.shared.keyboardSessionActive = false
        }
        if !visibility.hasVisibleDrawer && keyboardScreenUUID == nil { endKeepingWindow() }
        if isVisible { captureMouseTarget(owner: owner) }
    }

    private func window(on screenUUID: String) -> NSWindow? {
        guard let manager = windowManager else { return nil }
        if Defaults[.displayMode] == .allDisplays { return manager.contexts[screenUUID]?.window }
        return manager.primaryViewModel.screenUUID == screenUUID ? manager.primaryWindow : nil
    }

    private func windowWillClose(_ window: NSWindow) {
        let owners = ownerWindows.filter { $0.value == ObjectIdentifier(window) }.map(\.key)
        for owner in owners { updateVisibility(owner: owner, screenUUID: nil, visible: false) }
    }

    private func captureMouseTarget(owner: UUID) {
        guard !ClipboardStore.shared.keyboardSessionActive,
              let screen = visibility.visibleOwners[owner],
              NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.displayUUID == screen,
              visibility.claimMouse(owner: owner) else { return }
        cancelPendingPaste()
        sessionPresented = true
        ClipboardStore.shared.beginSession(target: NSWorkspace.shared.frontmostApplication)
    }

    func endKeepingWindow() {
        // SwiftUI delivers close/tab observations after dismiss-for-paste. They must
        // not cancel the new delayed paste task installed by that same action.
        guard sessionPresented else { return }
        cancelPendingPaste()
        clearSession()
    }

    private func clearSession() {
        guard sessionPresented else { return }
        sessionPresented = false
        visibility.reset()
        ownerWindows = [:]
        keyboardScreenUUID = nil
        ClipboardStore.shared.keyboardSessionActive = false
        ClipboardStore.shared.endSession()
    }

    func dismiss() {
        cancelPendingPaste()
        clearSession()
        closeDrawers()
    }

    private var notchPanels: [BoringNotchSkyLightWindow] {
        guard let manager = windowManager else { return [] }
        var seen = Set<ObjectIdentifier>()
        return (Array(manager.windows.values) + [manager.primaryWindow].compactMap { $0 })
            .compactMap { $0 as? BoringNotchSkyLightWindow }
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func closeDrawers() {
        guard let manager = windowManager else { return }
        for panel in notchPanels where !panel.isIslandKeyboardHandoffActive {
            panel.releaseIslandKeyboard()
        }
        if BoringViewCoordinator.shared.currentView == .clipboard {
            manager.primaryViewModel.close()
            manager.viewModels.values.forEach { $0.close() }
            BoringViewCoordinator.shared.currentView = previousView
        }
    }

    private func paste(to pid: Int32?, sessionID: String?, changeCount: Int?) {
        guard sessionPresented, keyboardScreenUUID != nil || visibility.mouseOwner != nil,
              sessionID == ClipboardStore.shared.sessionID.uuidString else { return }
        guard pasteActionID == nil else { return }
        guard let pid, let changeCount, let sessionID,
              let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            ClipboardStore.shared.reportPasteError("已复制；原应用已不可用，请手动粘贴。")
            dismiss()
            return
        }
        // Never move a paste into an application the user switched to meanwhile.
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard foregroundPID == pid || foregroundPID == ProcessInfo.processInfo.processIdentifier else {
            ClipboardStore.shared.reportPasteError("已复制；当前应用已切换，请手动粘贴。")
            dismiss()
            return
        }
        let actionID = UUID()
        pasteActionID = actionID
        pasteTask = Task { @MainActor in
            defer {
                ClipboardStore.shared.finishPaste(sessionID: sessionID)
                self.finishPasteAction(actionID)
            }
            let trusted = await XPCHelperClient.shared.isAccessibilityAuthorized()
            guard !Task.isCancelled, self.pasteActionID == actionID,
                  self.windowManager?.isScreenLocked == false else { return }
            guard trusted else {
                ClipboardStore.shared.reportPasteError("已复制；请先在系统设置中授予当前版本控制权限，或按 ⌘V 手动粘贴。")
                return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid || NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                ClipboardStore.shared.reportPasteError("已复制；当前应用已切换，请手动粘贴。")
                return
            }
            // A nonactivating panel can own keyboard focus while the original app
            // remains frontmost. Order it out; resignKey() is only a notification.
            let panels = self.notchPanels
            self.clearSession()
            self.suspendedPanels = panels.map { ($0, $0.beginIslandKeyboardHandoff()) }
            self.closeDrawers()
            NSApp.yieldActivation(to: target)
            _ = target.activate(from: .current, options: [])
            for _ in 0..<30 {
                guard !Task.isCancelled, self.pasteActionID == actionID,
                      self.windowManager?.isScreenLocked == false else { return }
                if !self.notchPanels.contains(where: \.isKeyWindow) { break }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            guard !self.notchPanels.contains(where: \.isKeyWindow) else {
                ClipboardStore.shared.reportPasteError("已复制；键盘焦点未能返回原应用，请手动粘贴。")
                return
            }
            let result = await XPCHelperClient.shared.pasteClipboard(to: pid, changeCount: changeCount, requestID: actionID)
            guard self.pasteActionID == actionID, !Task.isCancelled else { return }
            switch result {
            case .posted, .cancelled: break
            case .unauthorized:
                ClipboardStore.shared.reportPasteError("已复制；请在系统设置中授予当前版本辅助功能权限。")
            case .inputHeld:
                ClipboardStore.shared.reportPasteError("已复制；请松开按键后重试。")
            case .clipboardChanged:
                ClipboardStore.shared.reportPasteError("剪贴板已更改，已取消自动粘贴。")
            case .screenLocked: break
            case .targetUnavailable:
                ClipboardStore.shared.reportPasteError("已复制；原应用已不可用，请手动粘贴。")
            case .focusChanged:
                ClipboardStore.shared.reportPasteError("已复制；当前应用已切换，请手动粘贴。")
            case .focusUnavailable, .eventFailure:
                ClipboardStore.shared.reportPasteError("已复制；键盘焦点未能返回原应用，请手动粘贴。")
            }
        }
    }

    private func cancelPendingPaste() {
        pasteActionID = nil
        pasteTask?.cancel()
        pasteTask = nil
        restorePanels()
    }

    private func finishPasteAction(_ actionID: UUID) {
        guard pasteActionID == actionID else { return }
        pasteActionID = nil
        pasteTask = nil
        restorePanels()
    }

    private func restorePanels() {
        let current = Set(notchPanels.map(ObjectIdentifier.init))
        for (panel, token) in suspendedPanels {
            panel.endIslandKeyboardHandoff(token, restoreVisible: current.contains(ObjectIdentifier(panel))
                && windowManager?.isScreenLocked == false)
        }
        suspendedPanels = []
    }
}

@MainActor
enum ClipboardLayout {
    static func size(screenUUID: String?) -> CGSize {
        let screen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
        return CGSize(width: min(openNotchSize.width, max(320, frame.width - 32)), height: min(420, max(240, frame.height - 80)))
    }
}
