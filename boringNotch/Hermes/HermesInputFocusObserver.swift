import AppKit
import IslandCore
import SwiftUI

/// Observe this drawer's actual panel; window activation remains the window bridge's responsibility.
struct HermesInputFocusObserver: NSViewRepresentable {
    let enabled: Bool
    var activation: UUID? = nil
    let isCurrent: () -> Bool
    let setFocused: (Bool) -> Void

    @MainActor
    final class Anchor: NSView {
        private var enabled = false
        private var activation: UUID?
        private var isCurrent: (() -> Bool)?
        private var setFocused: ((Bool) -> Void)?
        private var generation = HermesFocusGeneration()
        private var pending: DispatchWorkItem?
        private var observers: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?
        private var locked = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func receive(enabled: Bool, activation: UUID?, isCurrent: @escaping () -> Bool, setFocused: @escaping (Bool) -> Void) {
            let changed = self.enabled != enabled || self.activation != activation
            self.activation = activation
            self.enabled = enabled
            self.isCurrent = isCurrent
            self.setFocused = setFocused
            if observedWindow !== window { bindWindow() }
            // Ordinary text/answer rendering must not steal selection from rich content.
            if changed { schedule() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bindWindow()
        }

        private func bindWindow() {
            cancelPending()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            observedWindow = window
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                         NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] note in
                    MainActor.assumeIsolated {
                        guard let self, let window, self.window === window else { return }
                        if note.name == NSWindow.didBecomeKeyNotification,
                           (window as? BoringNotchSkyLightWindow)?.isIslandScreenLocked != true {
                            self.locked = false
                        }
                        self.schedule()
                    }
                })
            }
            // Settings/popovers can take key status before our panel's resignation is delivered.
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let other = note.object as? NSWindow, other !== self.window else { return }
                    self.schedule()
                }
            })
            observers.append(center.addObserver(forName: .islandLocked, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.locked = true; self?.schedule() }
            })
            schedule()
        }

        private func eligibility(for window: NSWindow) -> HermesFocusEligibility {
            let panel = window as? BoringNotchSkyLightWindow
            return HermesFocusEligibility(drawerOpen: enabled, hermesSelected: isCurrent?() == true,
                windowKey: window.isKeyWindow && NSApp.keyWindow === window,
                windowVisible: window.isVisible && !isHiddenOrHasHiddenAncestor,
                windowLocked: locked || panel?.isIslandScreenLocked == true,
                keyboardHandoff: panel?.isIslandKeyboardHandoffActive == true,
                blockingUI: NSApp.modalWindow != nil || window.attachedSheet != nil)
        }

        private func schedule() {
            cancelPending()
            guard let window else { return }
            let ticket = generation.value
            let work = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      self.generation.value == ticket else { return }
                self.pending = nil
                self.setFocused?(self.generation.permits(ticket, eligibility: self.eligibility(for: window)))
            }
            pending = work
            // Do not mutate SwiftUI focus while its representable is reconciling.
            DispatchQueue.main.async(execute: work)
        }

        private func cancelPending() {
            generation.invalidate()
            pending?.cancel()
            pending = nil
        }

        func invalidate() {
            cancelPending()
            enabled = false
            isCurrent = nil
            setFocused = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            observedWindow = nil
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor(frame: .zero) }
    func updateNSView(_ view: Anchor, context: Context) {
        view.receive(enabled: enabled, activation: activation, isCurrent: isCurrent, setFocused: setFocused)
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.invalidate() }
}
