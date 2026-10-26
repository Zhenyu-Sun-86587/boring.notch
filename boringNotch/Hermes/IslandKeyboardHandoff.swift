import AppKit

/// Kept separate from AppKit ordering so hidden native fixtures exercise production token rules.
@MainActor
final class IslandKeyboardHandoffState {
    private struct Lease { let token: UUID; let wasVisible: Bool }
    private var lease: Lease?
    private(set) var isClosed = false
    var performsInternalOrderOut = false
    var isActive: Bool { lease != nil }
    var wasVisibleBeforeHandoff: Bool { lease?.wasVisible == true }

    func begin(wasVisible: Bool) -> UUID {
        let token = UUID()
        // A replacement lease inherits the original visibility of this uninterrupted handoff.
        lease = Lease(token: token, wasVisible: lease?.wasVisible ?? wasVisible)
        return token
    }
    func matches(_ token: UUID) -> Bool { lease?.token == token }
    func finish(_ token: UUID) -> Bool? {
        guard let lease, lease.token == token else { return nil }
        self.lease = nil
        return lease.wasVisible
    }
    func invalidate(closing: Bool = false) {
        lease = nil
        if closing { isClosed = true }
    }
}

extension BoringNotchSkyLightWindow {
    var isIslandKeyboardHandoffActive: Bool { islandKeyboardHandoffState.isActive }
    var wasVisibleBeforeHandoff: Bool { islandKeyboardHandoffState.wasVisibleBeforeHandoff }

    /// A key-window resignation notification is not a release API. Ordering the panel out
    /// actually removes it from WindowServer's key-window selection while focus is transferred.
    @discardableResult
    func beginIslandKeyboardHandoff() -> UUID {
        let token = islandKeyboardHandoffState.begin(wasVisible: isVisible)
        islandKeyboardOwner = nil
        allowsIslandKeyboard = false
        wantsKeyForTextInput = false
        _ = makeFirstResponder(nil)
        islandKeyboardHandoffState.performsInternalOrderOut = true
        orderOut(nil)
        islandKeyboardHandoffState.performsInternalOrderOut = false
        return token
    }

    func endIslandKeyboardHandoff(_ token: UUID, restoreVisible: Bool) {
        guard islandKeyboardHandoffState.matches(token) else { return }
        // Pending SwiftUI focus requests must not survive the suspended interval.
        islandKeyboardOwner = nil
        allowsIslandKeyboard = false
        wantsKeyForTextInput = false
        _ = makeFirstResponder(nil)
        guard let wasVisible = islandKeyboardHandoffState.finish(token), wasVisible,
              restoreVisible, !isIslandScreenLocked, !islandKeyboardHandoffState.isClosed else { return }
        // This is visibility restoration only. It must never make the notch key again.
        orderFrontRegardless()
    }

    func releaseIslandKeyboard() {
        let token = beginIslandKeyboardHandoff()
        // Ordinary tab/close release has no external paste work between these calls. Complete
        // visibility restoration in this run-loop turn so WindowServer never presents a hidden
        // frame. Explicit paste handoffs still keep their token until the target is ready.
        endIslandKeyboardHandoff(token, restoreVisible: true)
    }

    /// External orderOut/close/lock invalidates queued restorations before they can reopen a panel.
    func invalidateIslandKeyboardHandoff(closing: Bool = false) {
        islandKeyboardHandoffState.invalidate(closing: closing)
        islandKeyboardOwner = nil
        allowsIslandKeyboard = false
        wantsKeyForTextInput = false
        _ = makeFirstResponder(nil)
    }
}
