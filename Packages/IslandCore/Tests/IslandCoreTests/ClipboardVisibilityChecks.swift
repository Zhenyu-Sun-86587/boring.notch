import Foundation
import IslandCore

func clipboardVisibilityChecks() throws {
    var state = ClipboardVisibilityState()
    let first = UUID(), second = UUID(), replacement = UUID()
    state.setVisible(true, owner: first, screen: "display-a")
    try expect(state.claimMouse(owner: first))
    try expect(!state.claimMouse(owner: first))
    state.setVisible(false, owner: first, screen: "display-a")
    try expect(!state.hasVisibleDrawer && state.mouseOwner == nil)
    state.setVisible(true, owner: first, screen: "display-a")
    try expect(state.claimMouse(owner: first)) // Closing and reopening must capture again.

    state.setVisible(true, owner: second, screen: "display-b")
    state.setVisible(false, owner: first, screen: "display-a")
    try expect(state.hasVisibleDrawer && state.contains(screen: "display-b"))
    try expect(state.mouseOwner == nil)
    try expect(state.claimMouse(owner: second))
    state.setVisible(false, owner: first, screen: "display-a") // Duplicate old screen notification.
    try expect(state.mouseOwner == second)

    state.setVisible(true, owner: replacement, screen: "display-b")
    try expect(state.claimMouse(owner: replacement))
    state.setVisible(false, owner: second, screen: "display-b") // Old window closes after replacement.
    try expect(state.mouseOwner == replacement && state.contains(screen: "display-b"))

    state.reset() // Own dismiss-for-paste relinquishes all visibility ownership first.
    state.setVisible(false, owner: replacement, screen: "display-b")
    try expect(!state.hasVisibleDrawer && state.mouseOwner == nil)
    state.setVisible(true, owner: replacement, screen: "display-b") // Fresh session opens.
    try expect(state.claimMouse(owner: replacement))
    state.setVisible(false, owner: second, screen: "display-b") // Delayed callback from the old view.
    try expect(state.hasVisibleDrawer && state.mouseOwner == replacement)
}
