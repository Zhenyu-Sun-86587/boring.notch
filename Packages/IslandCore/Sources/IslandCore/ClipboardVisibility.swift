import Foundation

/// Each rendered drawer has a stable identity, even when two windows use the same screen.
/// Visibility changes do not themselves discard another visible drawer's shared session.
public struct ClipboardVisibilityState: Sendable {
    public private(set) var visibleOwners: [UUID: String] = [:]
    public private(set) var mouseOwner: UUID?
    public init() {}
    public var hasVisibleDrawer: Bool { !visibleOwners.isEmpty }

    public mutating func setVisible(_ visible: Bool, owner: UUID, screen: String?) {
        if visible, let screen { visibleOwners[owner] = screen }
        else {
            visibleOwners.removeValue(forKey: owner)
            if mouseOwner == owner { mouseOwner = nil }
        }
    }

    /// A real pointer entrance can move ownership; unrelated screen updates cannot.
    public mutating func claimMouse(owner: UUID) -> Bool {
        guard visibleOwners[owner] != nil, mouseOwner != owner else { return false }
        mouseOwner = owner
        return true
    }

    public func contains(screen: String) -> Bool { visibleOwners.values.contains(screen) }
    public mutating func reset() { visibleOwners = [:]; mouseOwner = nil }
}
