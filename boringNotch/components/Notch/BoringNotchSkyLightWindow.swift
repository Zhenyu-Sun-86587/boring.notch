//
//  BoringNotchSkyLightWindow.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32

        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }

        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class BoringNotchSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false
    let islandKeyboardHandoffState = IslandKeyboardHandoffState()
    var allowsIslandKeyboard = false {
        didSet {
            if allowsIslandKeyboard && isIslandKeyboardHandoffActive { allowsIslandKeyboard = false }
        }
    }
    var islandKeyboardOwner: UUID?
    var isIslandScreenLocked = false {
        didSet { if isIslandScreenLocked { invalidateIslandKeyboardHandoff() } }
    }

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )

        configureWindow()
        setupObservers()
    }

    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        // This panel renders its own opening/closing shell inside a fixed viewport.
        // Releasing nonactivating keyboard focus orders it out and back in; AppKit's
        // automatic window animation would also transform that viewport, separating
        // the visible notch from the screen's top edge.
        animationBehavior = .none
        isReleasedWhenClosed = false

        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)

        updateCollectionBehavior()

        // Apply initial sharing type setting
        updateSharingType()
    }

    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)

        Defaults.publisher(.hideNonNotchedFromMissionControl)
            .sink { [weak self] _ in
                self?.updateCollectionBehavior()
            }
            .store(in: &observers)

        NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification, object: self)
            .sink { [weak self] _ in
                self?.updateCollectionBehavior()
            }
            .store(in: &observers)

        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: self)
            .sink { [weak self] _ in
                self?.cleanupObservers()
            }
            .store(in: &observers)
    }

    private func updateCollectionBehavior() {
        var newBehavior: NSWindow.CollectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        let hasNotch = (self.screen?.safeAreaInsets.top ?? 0) > 0

        if Defaults[.hideNonNotchedFromMissionControl] && !hasNotch {
            newBehavior.insert(.transient)
        }

        collectionBehavior = newBehavior
    }

    private func updateSharingType() {
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readWrite
        }
    }

    func enableSkyLight() {
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
    }

    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }

    private var observers: Set<AnyCancellable> = []

    private func cleanupObservers() {
        Task { @MainActor in
            self.observers.forEach { $0.cancel() }
            self.observers.removeAll()
        }
    }

    /// False by default so a click on the notch never activates the app or
    /// steals focus from whatever is frontmost — load-bearing for every
    /// normal interaction (hover-to-open, music controls, OSD). A text field
    /// needs this flipped on for the moment it's actually being typed into,
    /// and back off the instant it isn't — never left permanently true.
    ///
    /// This is the window class actually instantiated for the notch
    /// (createBoringNotchWindow uses BoringNotchSkyLightWindow, not the
    /// separate, unused BoringNotchWindow class) — an earlier fix targeted
    /// that unused class and silently did nothing.
    var wantsKeyForTextInput = false {
        didSet {
            guard wantsKeyForTextInput != oldValue else { return }
            if wantsKeyForTextInput && isIslandKeyboardHandoffActive {
                wantsKeyForTextInput = false
                return
            }
            if wantsKeyForTextInput && canBecomeKey { makeKey() }
        }
    }

    override func orderOut(_ sender: Any?) {
        if !islandKeyboardHandoffState.performsInternalOrderOut { invalidateIslandKeyboardHandoff() }
        super.orderOut(sender)
    }

    override func close() {
        invalidateIslandKeyboardHandoff(closing: true)
        super.close()
    }

    override func orderFront(_ sender: Any?) {
        guard !isIslandKeyboardHandoffActive, !islandKeyboardHandoffState.isClosed else { return }
        super.orderFront(sender)
    }

    override func orderFrontRegardless() {
        guard !isIslandKeyboardHandoffActive, !islandKeyboardHandoffState.isClosed else { return }
        super.orderFrontRegardless()
    }

    override func makeKey() {
        InteractionDiagnostics.record("window", "make-key-before", InteractionDiagnostics.windowFields(self))
        super.makeKey()
        InteractionDiagnostics.record("window", "make-key-after", InteractionDiagnostics.windowFields(self))
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if InteractionDiagnostics.enabled {
            var fields = InteractionDiagnostics.windowFields(self)
            fields["requestedResponder"] = responder.map { NSStringFromClass(type(of: $0)) } ?? "nil"
            fields["result"] = String(accepted)
            InteractionDiagnostics.record("window", "first-responder", fields)
        }
        return accepted
    }

    override func sendEvent(_ event: NSEvent) {
        if InteractionDiagnostics.enabled,
           event.type == .leftMouseDown || event.type == .leftMouseUp
            || ((event.type == .keyDown || event.type == .keyUp) && [36, 76, 125, 126, 53].contains(event.keyCode)) {
            var fields = InteractionDiagnostics.windowFields(self)
            fields["event"] = String(event.type.rawValue)
            if event.type == .leftMouseDown || event.type == .leftMouseUp {
                fields["eventNumber"] = String(event.eventNumber)
                fields["x"] = String(describing: event.locationInWindow.x); fields["y"] = String(describing: event.locationInWindow.y)
            }
            if event.type == .keyDown || event.type == .keyUp { fields["key"] = String(event.keyCode) }
            InteractionDiagnostics.record("window", "input-delivered", fields)
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool {
        isVisible && !isIslandKeyboardHandoffActive && !islandKeyboardHandoffState.isClosed
            && (wantsKeyForTextInput || allowsIslandKeyboard) && !isIslandScreenLocked
    }
    override var canBecomeMain: Bool { false }
}
