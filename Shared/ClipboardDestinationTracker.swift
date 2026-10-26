import Foundation

/// An open picker keeps its destination, even if another app activates while it is open.
/// Closing ends that lease, but an accessory-app alert must not erase the previous editor.
struct ClipboardDestinationTracker {
    private(set) var rememberedPID: Int32?
    private(set) var activePID: Int32?

    mutating func observeActivation(_ pid: Int32?, hostPID: Int32) {
        guard let pid, pid > 0, pid != hostPID else { return }
        rememberedPID = pid
    }

    mutating func begin(frontmostPID: Int32?, hostPID: Int32, allowRemembered: Bool) -> Int32? {
        if let activePID { return activePID }
        observeActivation(frontmostPID, hostPID: hostPID)
        if let frontmostPID, frontmostPID > 0, frontmostPID != hostPID {
            activePID = frontmostPID
        } else if frontmostPID == hostPID && allowRemembered {
            activePID = rememberedPID
        }
        return activePID
    }

    mutating func end() { activePID = nil }

    mutating func forget(_ pid: Int32) {
        if activePID == pid { activePID = nil }
        if rememberedPID == pid { rememberedPID = nil }
    }
}
