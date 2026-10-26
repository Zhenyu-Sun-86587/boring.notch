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
    @Published private(set) var keyboardTargetReady = false
    private weak var windowManager: NotchWindowManager?
    private var observers: [NSObjectProtocol] = []
    private var visibility = ClipboardVisibilityState()
    private var ownerWindows: [UUID: ObjectIdentifier] = [:]
    private var sessionPresented = false
    private var keyboardOwners = Set<UUID>()
    private var keyboardTargetApplication: NSRunningApplication?
    private var destinationTracker = ClipboardDestinationTracker()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var allowsRememberedDestination = true
    private var targetInvalidatedByOwnEditor = false
    private var keyboardTarget: ClipboardPasteTarget?
    private var targetGeneration = UUID()
    private var targetCaptureTask: Task<Void, Never>?
    private var targetCaptureTimeout: DispatchWorkItem?
    private var targetRelease: DispatchWorkItem?
    private var pasteTask: Task<Void, Never>?
    private var pasteActionID: UUID?
    private var suspendedPanels: [(BoringNotchSkyLightWindow, UUID)] = []

    func configure(windowManager: NotchWindowManager) {
        self.windowManager = windowManager
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared
        let hostPID = ProcessInfo.processInfo.processIdentifier
        destinationTracker.observeActivation(workspace.frontmostApplication?.processIdentifier, hostPID: hostPID)
        workspaceObservers.append(workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    self?.destinationTracker.observeActivation(application.processIdentifier, hostPID: hostPID)
                }
            })
        workspaceObservers.append(workspace.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.destinationTracker.forget(application.processIdentifier) }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow, !(window is BoringNotchSkyLightWindow) else { return }
                MainActor.assumeIsolated { self?.targetInvalidatedByOwnEditor = true }
            })
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("ClipboardPasteRequested"), object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?["targetPID"] as? NSNumber)?.int32Value
            let sessionID = note.userInfo?["sessionID"] as? String
            let changeCount = note.userInfo?["changeCount"] as? Int
            let targetToken = note.userInfo?["targetToken"] as? String
            Task { @MainActor in self?.paste(to: pid, sessionID: sessionID, changeCount: changeCount, targetToken: targetToken) }
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

    /// Called before either workspace acquires keyboard focus. Hermes -> Clipboard shares this
    /// snapshot, so the main app is never mistaken for the external editor after switching tabs.
    func prepareKeyboardTarget() {
        guard windowManager?.isScreenLocked != true, targetCaptureTask == nil else { return }
        let foreground = NSWorkspace.shared.frontmostApplication
        if keyboardTargetReady, keyboardTargetApplication != nil { return }
        // A previous attempt with no destination is not a completed snapshot. A new opening
        // can recover after a permission dialog without freezing the next session at nil.
        if keyboardTargetReady, notchPanels.contains(where: \.isKeyWindow),
           foreground == nil || foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        let ownEditorIsKey = NSApp.keyWindow.map { !($0 is BoringNotchSkyLightWindow) } ?? false
        if ownEditorIsKey { allowsRememberedDestination = false }
        let pid = destinationTracker.begin(frontmostPID: foreground?.processIdentifier,
            hostPID: ProcessInfo.processInfo.processIdentifier, allowRemembered: allowsRememberedDestination && !ownEditorIsKey)
        if let pid, let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated {
            keyboardTargetApplication = application
        } else if let pid {
            destinationTracker.forget(pid)
        }
        guard let application = keyboardTargetApplication, !application.isTerminated else {
            keyboardTargetReady = true
            return
        }
        keyboardTargetReady = false
        let generation = targetGeneration
        let targetPID = application.processIdentifier
        targetCaptureTask = Task { @MainActor in
            let snapshot = await XPCHelperClient.shared.captureClipboardTarget(targetPID)
            guard !Task.isCancelled, self.targetGeneration == generation else {
                if let snapshot { XPCHelperClient.shared.releaseClipboardTarget(snapshot.token) }
                return
            }
            self.targetCaptureTimeout?.cancel(); self.targetCaptureTimeout = nil
            self.keyboardTarget = snapshot
            self.keyboardTargetReady = true
            self.targetCaptureTask = nil
            NSLog("[clipboard] target ready pid=%d snapshot=%d window=%d element=%d", targetPID, snapshot != nil,
                snapshot?.hasWindow == true, snapshot?.hasElement == true)
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.targetGeneration == generation, !self.keyboardTargetReady else { return }
            self.targetCaptureTask?.cancel(); self.targetCaptureTask = nil
            self.targetCaptureTimeout = nil
            self.keyboardTargetReady = true
            NSLog("[clipboard] target snapshot timeout pid=%d", targetPID)
        }
        targetCaptureTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
    }

    func updateKeyboardTargetVisibility(owner: UUID, visible: Bool) {
        if visible {
            targetRelease?.cancel(); targetRelease = nil
            keyboardOwners.insert(owner)
            prepareKeyboardTarget()
        } else {
            guard keyboardOwners.remove(owner) != nil, keyboardOwners.isEmpty, pasteActionID == nil else { return }
            let generation = targetGeneration
            let release = DispatchWorkItem { [weak self] in
                guard let self, self.targetGeneration == generation,
                      self.keyboardOwners.isEmpty, self.pasteActionID == nil else { return }
                self.endKeyboardTarget()
            }
            targetRelease?.cancel(); targetRelease = release
            DispatchQueue.main.async(execute: release)
        }
    }

    private func endKeyboardTarget() {
        targetRelease?.cancel(); targetRelease = nil
        targetGeneration = UUID()
        targetCaptureTask?.cancel(); targetCaptureTask = nil
        targetCaptureTimeout?.cancel(); targetCaptureTimeout = nil
        if let keyboardTarget { XPCHelperClient.shared.releaseClipboardTarget(keyboardTarget.token) }
        keyboardTarget = nil
        keyboardTargetApplication = nil
        destinationTracker.end()
        allowsRememberedDestination = true
        targetInvalidatedByOwnEditor = false
        keyboardTargetReady = false
    }

    /// Recover only a still-current session that was opened before a destination was known.
    /// A captured destination remains fixed; activation notifications never redirect a paste.
    func applicationForPaste(sessionID: UUID) -> NSRunningApplication? {
        guard sessionPresented, ClipboardStore.shared.sessionID == sessionID else { return nil }
        if targetInvalidatedByOwnEditor {
            // The user has explicitly returned to an external editor after a permission dialog.
            // Only this fresh action may replace the invalidated input snapshot.
            guard let foreground = NSWorkspace.shared.frontmostApplication,
                  foreground.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            endKeyboardTarget()
        }
        if keyboardTargetApplication == nil { prepareKeyboardTarget() }
        return keyboardTargetApplication
    }

    func targetToken(for pid: Int32) async -> String? {
        guard !targetInvalidatedByOwnEditor else { return nil }
        // A newly granted permission can be retried without closing only when the external
        // editor truly owns focus again. Never recapture while the notch still owns key input.
        if keyboardTargetReady, keyboardTarget == nil,
           keyboardTargetApplication?.processIdentifier == pid,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
           !notchPanels.contains(where: \.isKeyWindow) {
            keyboardTargetReady = false
        }
        prepareKeyboardTarget()
        let generation = targetGeneration
        let started = ProcessInfo.processInfo.systemUptime
        while !keyboardTargetReady && ProcessInfo.processInfo.systemUptime - started < 2.1 {
            guard !Task.isCancelled, targetGeneration == generation else { return nil }
            do { try await Task.sleep(for: .milliseconds(15)) } catch { return nil }
        }
        guard !Task.isCancelled, !targetInvalidatedByOwnEditor, targetGeneration == generation, keyboardTargetReady,
              keyboardTargetApplication?.processIdentifier == pid,
              keyboardTarget?.processIdentifier == pid else { return nil }
        return keyboardTarget?.token
    }

    func toggle() {
        guard let manager = windowManager, !manager.isScreenLocked,
              !BoringViewCoordinator.shared.firstLaunch else { return }
        if ClipboardStore.shared.keyboardSessionActive {
            dismiss()
            return
        }
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let screenID = pointerScreen?.displayUUID
        let viewModel: BoringViewModel
        if Defaults[.displayMode] == .allDisplays, let id = screenID, let context = manager.contexts[id] {
            viewModel = context.viewModel
        } else {
            viewModel = manager.primaryViewModel
        }
        beginKeyboardSession(on: viewModel)
    }

    /// The generic notch shortcut can restore Clipboard on its already-selected display.
    func beginKeyboardSession(on viewModel: BoringViewModel) {
        guard windowManager?.isScreenLocked == false, !BoringViewCoordinator.shared.firstLaunch else { return }
        cancelPendingPaste()
        // A fresh explicit shortcut after switching to another editor is a new destination.
        // A Hermes -> Clipboard switch while our panel owns key retains the original snapshot.
        let ownEditorIsKey = NSApp.keyWindow.map { !($0 is BoringNotchSkyLightWindow) } ?? false
        if ownEditorIsKey {
            endKeyboardTarget()
            allowsRememberedDestination = false
        } else if let foreground = NSWorkspace.shared.frontmostApplication,
                  foreground.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !notchPanels.contains(where: \.isKeyWindow) {
            endKeyboardTarget()
        }
        prepareKeyboardTarget()
        sessionPresented = true
        ClipboardStore.shared.beginSession()
        keyboardScreenUUID = viewModel.screenUUID
        ClipboardStore.shared.keyboardSessionActive = true
        viewModel.open(tab: .clipboard)
        if let screen = viewModel.screenUUID, let panel = window(on: screen) as? BoringNotchSkyLightWindow {
            panel.orderFrontRegardless()
            if keyboardTargetReady { panel.allowsIslandKeyboard = true; panel.makeKey() }
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
        prepareKeyboardTarget()
        sessionPresented = true
        ClipboardStore.shared.beginSession()
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
        endKeyboardTarget()
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
        }
    }

    private func paste(to pid: Int32?, sessionID: String?, changeCount: Int?, targetToken: String?) {
        guard sessionPresented, keyboardScreenUUID != nil || visibility.mouseOwner != nil,
              sessionID == ClipboardStore.shared.sessionID.uuidString else { return }
        guard pasteActionID == nil else { return }
        guard let pid, let changeCount, let sessionID,
              let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            ClipboardStore.shared.reportPasteError("已复制；原应用已不可用，请手动粘贴。")
            dismiss()
            ClipboardPermissionController.shared.explainPasteFailure(.targetUnavailable)
            return
        }
        // Never move a paste into an application the user switched to meanwhile.
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard foregroundPID == pid || foregroundPID == ProcessInfo.processInfo.processIdentifier else {
            ClipboardStore.shared.reportPasteError("已复制；当前应用已切换，请手动粘贴。")
            dismiss()
            ClipboardPermissionController.shared.explainPasteFailure(.focusChanged)
            return
        }
        let actionID = UUID()
        pasteActionID = actionID
        pasteTask = Task { @MainActor in
            defer {
                ClipboardStore.shared.finishPaste(sessionID: sessionID)
                self.finishPasteAction(actionID)
            }
            let trusted = await ClipboardPermissionController.shared.ensurePasteAccess()
            guard !Task.isCancelled, self.pasteActionID == actionID,
                  self.windowManager?.isScreenLocked == false else { return }
            guard trusted else {
                ClipboardStore.shared.reportPasteError("已复制；请先在系统设置中授予当前版本控制权限，或按 ⌘V 手动粘贴。")
                return
            }
            guard !self.targetInvalidatedByOwnEditor else {
                ClipboardPermissionController.shared.explainPasteFailure(.focusChanged)
                return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid || NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                ClipboardStore.shared.reportPasteError("已复制；当前应用已切换，请手动粘贴。")
                ClipboardPermissionController.shared.explainPasteFailure(.focusChanged)
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
                ClipboardPermissionController.shared.explainPasteFailure(.focusUnavailable)
                return
            }
            let result = await XPCHelperClient.shared.pasteClipboard(to: pid, changeCount: changeCount, targetToken: targetToken, requestID: actionID)
            guard self.pasteActionID == actionID, !Task.isCancelled else { return }
            NSLog("[clipboard] host request=%@ result=%@ target=%d", actionID.uuidString, result.rawValue, pid)
            ClipboardPermissionController.shared.explainPasteFailure(result)
            switch result {
            case .posted, .cancelled: break
            case .unauthorized, .postEventUnauthorized:
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
            case .focusUnavailable, .snapshotUnavailable, .eventFailure:
                ClipboardStore.shared.reportPasteError("已复制；键盘焦点未能返回原应用，请手动粘贴。")
            }
        }
    }

    private func cancelPendingPaste() {
        pasteActionID = nil
        pasteTask?.cancel()
        pasteTask = nil
        restorePanels()
        if keyboardOwners.isEmpty { endKeyboardTarget() }
    }

    private func finishPasteAction(_ actionID: UUID) {
        guard pasteActionID == actionID else { return }
        pasteActionID = nil
        pasteTask = nil
        restorePanels()
        if keyboardOwners.isEmpty { endKeyboardTarget() }
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
