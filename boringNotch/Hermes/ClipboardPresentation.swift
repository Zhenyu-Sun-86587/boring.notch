import AppKit
import Combine
import Defaults
import SwiftUI

/// One notch page serves pointer and keyboard entry; only the latter pins it open.
@MainActor
final class ClipboardPresentation: ObservableObject {
    static let shared = ClipboardPresentation()
    @Published private(set) var keyboardScreenUUID: String?
    private weak var windowManager: NotchWindowManager?
    private var observers: [NSObjectProtocol] = []
    private var sessionPresented = false
    private var previousView: NotchViews = .home
    private var pasteTask: Task<Void, Never>?

    func configure(windowManager: NotchWindowManager) {
        self.windowManager = windowManager
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("ClipboardPasteRequested"), object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?["targetPID"] as? NSNumber)?.int32Value
            let sessionID = note.userInfo?["sessionID"] as? String
            Task { @MainActor in self?.paste(to: pid, sessionID: sessionID) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("ClipboardDismissRequested"), object: nil, queue: .main) { [weak self] note in
            let sessionID = note.userInfo?["sessionID"] as? String
            Task { @MainActor in
                guard sessionID == ClipboardStore.shared.sessionID.uuidString else { return }
                self?.dismiss()
            }
        })
    }

    func toggle() {
        guard let manager = windowManager, !manager.isScreenLocked,
              !BoringViewCoordinator.shared.firstLaunch else { return }
        if ClipboardStore.shared.keyboardSessionActive {
            dismiss()
            return
        }
        pasteTask?.cancel()
        pasteTask = nil
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

    func captureMouseTarget() {
        guard !ClipboardStore.shared.keyboardSessionActive, !sessionPresented else { return }
        pasteTask?.cancel()
        pasteTask = nil
        sessionPresented = true
        ClipboardStore.shared.beginSession(target: NSWorkspace.shared.frontmostApplication)
    }

    func endKeepingWindow() {
        // SwiftUI delivers close/tab observations after dismiss-for-paste. They must
        // not cancel the new delayed paste task installed by that same action.
        guard sessionPresented else { return }
        sessionPresented = false
        pasteTask?.cancel()
        pasteTask = nil
        keyboardScreenUUID = nil
        ClipboardStore.shared.keyboardSessionActive = false
        ClipboardStore.shared.endSession()
    }

    func dismiss() {
        pasteTask?.cancel()
        pasteTask = nil
        guard let manager = windowManager else { return }
        endKeepingWindow()
        for panel in (Array(manager.windows.values) + [manager.primaryWindow].compactMap { $0 }).compactMap({ $0 as? BoringNotchSkyLightWindow }) {
            panel.allowsIslandKeyboard = false
            if panel.isKeyWindow && !panel.wantsKeyForTextInput { panel.resignKey() }
        }
        if BoringViewCoordinator.shared.currentView == .clipboard {
            manager.primaryViewModel.close()
            manager.viewModels.values.forEach { $0.close() }
            BoringViewCoordinator.shared.currentView = previousView
        }
    }

    private func paste(to pid: Int32?, sessionID: String?) {
        guard sessionPresented, sessionID == ClipboardStore.shared.sessionID.uuidString else { return }
        pasteTask?.cancel()
        guard let pid, let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated,
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
        pasteTask = Task { @MainActor in
            let trusted = await XPCHelperClient.shared.isAccessibilityAuthorized()
            guard !Task.isCancelled, self.windowManager?.isScreenLocked == false else { return }
            guard trusted else {
                ClipboardStore.shared.reportPasteError("已复制；请先在系统设置中授予当前版本控制权限，或按 ⌘V 手动粘贴。")
                return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid || NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                ClipboardStore.shared.reportPasteError("已复制；当前应用已切换，请手动粘贴。")
                return
            }
            // Dismiss before creating the delayed task: dismiss invalidates older actions.
            self.dismiss()
            target.activate(options: [])
            self.schedulePaste(to: pid)
        }
    }

    private func schedulePaste(to pid: Int32) {
        pasteTask = Task { @MainActor in
            // Wait for the Return/Command shortcut to be released, without blocking the UI.
            for _ in 0..<40 {
                if Task.isCancelled { return }
                if NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, self.windowManager?.isScreenLocked == false, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                ClipboardStore.shared.reportPasteError("已复制；焦点已改变，请手动粘贴。")
                return
            }
            guard await XPCHelperClient.shared.pasteClipboard(to: pid) else {
                ClipboardStore.shared.reportPasteError("已复制；自动粘贴未获授权或焦点已改变，请手动粘贴。")
                return
            }
        }
    }
}

@MainActor
enum ClipboardLayout {
    static func size(screenUUID: String?) -> CGSize {
        let screen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
        return CGSize(width: min(720, max(320, frame.width - 32)), height: min(420, max(240, frame.height - 80)))
    }
}
