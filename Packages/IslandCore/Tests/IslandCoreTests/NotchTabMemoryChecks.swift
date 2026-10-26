import Foundation
import IslandCore

func runNotchTabMemoryChecks() throws {
    let primary = UUID(), secondary = UUID()
    var state = NotchTabMemory(saved: "clipboard")
    func open(_ owner: UUID, current: IslandTab = .home, requested: IslandTab? = nil,
              remember: Bool = true, shelfEnabled: Bool = true) -> IslandTab {
        state.open(owner: owner, current: current, requested: requested, remember: remember,
                   preferShelf: true, shelfEnabled: shelfEnabled, shelfHasItems: true)
    }
    // A window refresh/startup close cannot erase the persisted selection; remember wins over Shelf.
    try expect(!state.close(owner: primary, current: .home))
    try expect(open(primary) == .clipboard)
    try expect(state.close(owner: primary, current: .hermes))
    try expect(open(primary) == .hermes)
    // Another display follows the live shared tab; closing an unrelated closed window is inert.
    try expect(open(secondary, current: .clipboard) == .clipboard)
    try expect(state.close(owner: primary, current: .clipboard))
    try expect(!state.close(owner: primary, current: .home))
    try expect(open(primary, current: .hermes) == .hermes)
    try expect(state.close(owner: secondary, current: .hermes))
    try expect(state.close(owner: primary, current: .hermes))
    // Explicit clipboard shortcut / attachment drag wins even when a different tab is remembered.
    try expect(open(primary, requested: .clipboard) == .clipboard)
    try expect(state.close(owner: primary, current: .clipboard))
    try expect(open(primary, requested: .shelf) == .shelf)
    try expect(state.close(owner: primary, current: .shelf))
    try expect(open(primary, shelfEnabled: false) == .home)
    try expect(state.close(owner: primary, current: .home))
    try expect(open(primary, remember: false) == .shelf)
    state.discard(owner: primary)
    try expect(!state.close(owner: primary, current: .shelf))
    // The persisted raw value round-trips across process restarts, and future/invalid keys are safe.
    let restored = NotchTabMemory(saved: state.lastClosed.rawValue)
    try expect(restored.lastClosed == .home)
    try expect(NotchTabMemory(saved: "removed-tab").lastClosed == .home)
    for tab in IslandTab.allCases {
        var roundTrip = NotchTabMemory(saved: tab.rawValue)
        try expect(roundTrip.open(owner: UUID(), current: .home, remember: true,
                                  preferShelf: true, shelfEnabled: true, shelfHasItems: true) == tab)
    }
    print("PASS: persisted tab, explicit entries, Shelf precedence, repeat closes and multiple displays")
}
