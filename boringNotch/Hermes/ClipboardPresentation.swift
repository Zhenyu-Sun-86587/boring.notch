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
    private var keyboardPointerEntered = false
    private var pointerScreens = Set<String>()
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    /// Opt-in launch diagnostics. Never log clipboard bytes, AX values or window titles.
    /// stderr also works when unified logging discards an accessory application's NSLog.
    private func tracePaste(_ stage: String, _ detail: String = "") {
        guard CommandLine.arguments.contains("--clipboard-diagnostics") else { return }
        let line = "CLIPBOARD_TRACE \(ProcessInfo.processInfo.systemUptime) \(stage) \(detail)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

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
                    guard let self else { return }
                    self.destinationTracker.observeActivation(application.processIdentifier, hostPID: hostPID)
                    if self.sessionPresented || self.pasteActionID != nil, application.processIdentifier != hostPID,
                       application.processIdentifier != self.keyboardTargetApplication?.processIdentifier {
                        self.targetInvalidatedByOwnEditor = true
                        self.dismiss()
                    }
                }
            })
        workspaceObservers.append(workspace.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.destinationTracker.forget(application.processIdentifier)
                    if self.sessionPresented || self.pasteActionID != nil,
                       self.keyboardTargetApplication?.processIdentifier == application.processIdentifier {
                        self.targetInvalidatedByOwnEditor = true
                        self.dismiss()
                    }
                }
            })
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissAfterOutsideClick() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if !(event.window is BoringNotchSkyLightWindow) {
                MainActor.assumeIsolated { self?.dismissAfterOutsideClick() }
            }
            return event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.sessionPresented else { return }
                    let sessionID = ClipboardStore.shared.sessionID
                    Task { @MainActor in
                        await Task.yield()
                        guard self.sessionPresented, ClipboardStore.shared.sessionID == sessionID,
                              BoringViewCoordinator.shared.currentView == .clipboard,
                              !self.notchPanels.contains(where: \.isIslandKeyboardHandoffActive) else { return }
                        self.targetInvalidatedByOwnEditor = true
                        self.dismiss()
                    }
                }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow, !(window is BoringNotchSkyLightWindow) else { return }
                MainActor.assumeIsolated { self?.targetInvalidatedByOwnEditor = true }
            })
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("ClipboardPasteRequested"), object: nil, queue: .main) { [weak self] note in
            let sessionID = note.userInfo?["sessionID"] as? String
            let changeCount = note.userInfo?["changeCount"] as? Int
            Task { @MainActor in self?.paste(sessionID: sessionID, changeCount: changeCount) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("ClipboardDismissRequested"), object: nil, queue: .main) { [weak self] note in
            let sessionID = note.userInfo?["sessionID"] as? String
            Task { @MainActor in
                guard sessionID == ClipboardStore.shared.sessionID.uuidString else { return }
                self?.tracePaste("copy-only")
                self?.dismiss()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .clipboardCopyFailed, object: nil, queue: .main) { [weak self] note in
            let sessionID = note.userInfo?["sessionID"] as? String
            let message = note.userInfo?["message"] as? String ?? "无法复制这条记录。"
            Task { @MainActor in
                guard sessionID == ClipboardStore.shared.sessionID.uuidString else { return }
                self?.dismiss()
                ClipboardPermissionController.shared.explainCopyFailure(message)
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
            self.tracePaste("target", "pid=\(targetPID) snapshot=\(snapshot != nil) window=\(snapshot?.hasWindow == true) element=\(snapshot?.hasElement == true)")
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

    /// Keyboard opening is pinned only until the pointer has entered it once.
    /// The normal hover grace period can then close this display on pointer exit.
    func shouldKeepOpen(on screenUUID: String?) -> Bool {
        ClipboardStore.shared.keyboardSessionActive && keyboardScreenUUID == screenUUID && !keyboardPointerEntered
    }

    func pointerChanged(_ hovering: Bool, on screenUUID: String?) {
        if let screenUUID {
            if hovering { pointerScreens.insert(screenUUID) }
            else { pointerScreens.remove(screenUUID) }
        }
        if hovering, ClipboardStore.shared.keyboardSessionActive, keyboardScreenUUID == screenUUID {
            keyboardPointerEntered = true
        }
    }

    private func dismissAfterOutsideClick() {
        // Global events belong to another app; local callers already excluded notch
        // windows. The fixed transparent panel envelope is not a hit-test region.
        guard sessionPresented || pasteActionID != nil else { return }
        // This click is a new input intention. Close without reactivating the old editor.
        targetInvalidatedByOwnEditor = true
        dismiss()
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
        keyboardPointerEntered = viewModel.screenUUID.map { pointerScreens.contains($0) } ?? false
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
        if BoringViewCoordinator.shared.currentView == .clipboard { dismiss() }
        else {
            // Switching to Hermes shares the same target lease until that workspace closes.
            cancelPendingPaste()
            clearSession()
        }
    }

    private func clearSession() {
        guard sessionPresented else { return }
        sessionPresented = false
        visibility.reset()
        ownerWindows = [:]
        keyboardScreenUUID = nil
        keyboardPointerEntered = false
        ClipboardStore.shared.keyboardSessionActive = false
        ClipboardStore.shared.endSession()
    }

    func dismiss() {
        let target = keyboardTargetApplication
        let mayReturnFocus = !targetInvalidatedByOwnEditor && windowManager?.isScreenLocked == false
            && (NSWorkspace.shared.frontmostApplication?.processIdentifier == target?.processIdentifier
                || NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier)
        cancelPendingPaste()
        clearSession()
        closeDrawers()
        if mayReturnFocus, let target, !target.isTerminated {
            NSApp.yieldActivation(to: target)
            _ = target.activate(from: .current, options: [])
        }
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

    private func paste(sessionID: String?, changeCount: Int?) {
        tracePaste("selection", "presented=\(sessionPresented) currentSession=\(sessionID == ClipboardStore.shared.sessionID.uuidString) pending=\(pasteActionID != nil) payloadReady=\(changeCount != nil)")
        guard sessionPresented, sessionID == ClipboardStore.shared.sessionID.uuidString,
              pasteActionID == nil, let sessionID, let changeCount else { return }
        // The pasteboard is already populated. A missing/expired helper snapshot only
        // removes AX restoration; the original application is still a valid destination.
        let target = keyboardTargetApplication
        let targetToken = keyboardTarget?.token
        let invalidated = targetInvalidatedByOwnEditor
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let hostPID = ProcessInfo.processInfo.processIdentifier
        let actionID = UUID()
        pasteActionID = actionID
        let panels = notchPanels
        suspendedPanels = panels.map { ($0, $0.beginIslandKeyboardHandoff()) }
        clearSession()
        closeDrawers()
        pasteTask = Task { @MainActor in
            var stage = "handoff"
            defer {
                self.tracePaste("finish", "request=\(actionID) stage=\(stage) cancelled=\(Task.isCancelled) current=\(self.pasteActionID == actionID)")
                ClipboardStore.shared.finishPaste(sessionID: sessionID)
                self.finishPasteAction(actionID)
            }
            guard !Task.isCancelled, self.pasteActionID == actionID,
                  self.windowManager?.isScreenLocked == false else { return }
            guard !invalidated else {
                stage = "invalidated-target"
                ClipboardPermissionController.shared.explainPasteFailure(.focusChanged)
                return
            }
            guard let target, !target.isTerminated, target.processIdentifier != hostPID else {
                stage = "unavailable-target"
                ClipboardPermissionController.shared.explainPasteFailure(.targetUnavailable)
                return
            }
            let pid = target.processIdentifier
            // A user-selected app is never replaced by the saved destination.
            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard (foregroundPID == pid || foregroundPID == hostPID),
                  (currentPID == pid || currentPID == hostPID) else {
                stage = "foreground-changed"
                ClipboardPermissionController.shared.explainPasteFailure(.focusChanged)
                return
            }
            guard !Task.isCancelled, self.pasteActionID == actionID,
                  self.windowManager?.isScreenLocked == false else { return }
            NSApp.yieldActivation(to: target)
            let activated = target.activate(from: .current, options: [])
            self.tracePaste("activation", "request=\(actionID) target=\(pid) accepted=\(activated)")
            // Authorization is read-only here. Permission requests belong to explicit
            // settings actions and must never interrupt copied-content fallback.
            stage = "permission"
            let access = await ClipboardPermissionController.shared.pasteAccessWithoutPrompt()
            self.tracePaste("permission", "request=\(actionID) helper=\(access?.processIdentifier ?? -1) ax=\(access?.accessibility == true) post=\(access?.postEvents == true)")
            guard !Task.isCancelled, self.pasteActionID == actionID,
                  self.windowManager?.isScreenLocked == false else { return }
            guard let access else {
                ClipboardPermissionController.shared.explainPasteFailure(.eventFailure)
                return
            }
            guard access.canPaste else {
                ClipboardPermissionController.shared.explainPasteFailure(access.accessibility ? .postEventUnauthorized : .unauthorized)
                return
            }
            ClipboardStore.shared.setPasteAccessNeeded(false)
            stage = "panel-release"
            for _ in 0..<30 {
                guard !Task.isCancelled, self.pasteActionID == actionID,
                      self.windowManager?.isScreenLocked == false else { return }
                if !self.notchPanels.contains(where: \.isKeyWindow) { break }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            guard !self.notchPanels.contains(where: \.isKeyWindow) else {
                ClipboardPermissionController.shared.explainPasteFailure(.focusUnavailable)
                return
            }
            stage = "helper"
            let result = await XPCHelperClient.shared.pasteClipboard(to: pid, changeCount: changeCount,
                targetToken: targetToken, requestID: actionID)
            stage = "result-\(result.rawValue)"
            self.tracePaste("helper-result", "request=\(actionID) result=\(result.rawValue) target=\(pid)")
            guard self.pasteActionID == actionID, !Task.isCancelled else { return }
            NSLog("[clipboard] host request=%@ result=%@ target=%d", actionID.uuidString, result.rawValue, pid)
            ClipboardPermissionController.shared.explainPasteFailure(result)
        }
    }

    private func cancelPendingPaste(cause: StaticString = #function) {
        if let pasteActionID { tracePaste("cancel", "request=\(pasteActionID) cause=\(cause)") }
        pasteActionID = nil
        pasteTask?.cancel()
        pasteTask = nil
        restorePanels()
        // A visibility update can arrive before endKeepingWindow(). Keep its
        // destination until that unified close has had a chance to return focus.
        if keyboardOwners.isEmpty && !sessionPresented { endKeyboardTarget() }
    }

    private func finishPasteAction(_ actionID: UUID) {
        guard pasteActionID == actionID else { return }
        pasteActionID = nil
        pasteTask = nil
        restorePanels()
        endKeyboardTarget()
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
