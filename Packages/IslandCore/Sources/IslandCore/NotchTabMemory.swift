import Foundation

public enum IslandTab: String, CaseIterable, Sendable {
    case home, shelf, hermes, clipboard
}

/// Opening policy is independent of the currently rendered page: closing a surface must not
/// replace its content halfway through the close animation. Only a real open owner can save it.
public struct NotchTabMemory: Sendable {
    public private(set) var lastClosed: IslandTab
    private var openOwners = Set<UUID>()

    public init(saved: String?) { lastClosed = saved.flatMap(IslandTab.init(rawValue:)) ?? .home }

    public mutating func open(owner: UUID, current: IslandTab, requested: IslandTab? = nil,
                              remember: Bool, preferShelf: Bool, shelfEnabled: Bool,
                              shelfHasItems: Bool) -> IslandTab {
        let hadOpenSurface = !openOwners.isEmpty
        openOwners.insert(owner)
        let result: IslandTab
        if let requested { result = requested }
        else if hadOpenSurface { result = current }
        else if remember { result = lastClosed }
        else { result = preferShelf && shelfEnabled && shelfHasItems ? .shelf : .home }
        return result == .shelf && !shelfEnabled ? .home : result
    }

    /// Startup/layout refreshes call close() too. They must not overwrite the user's saved tab.
    @discardableResult public mutating func close(owner: UUID, current: IslandTab) -> Bool {
        guard openOwners.remove(owner) != nil else { return false }
        lastClosed = current
        return true
    }

    public mutating func discard(owner: UUID) { openOwners.remove(owner) }
}
