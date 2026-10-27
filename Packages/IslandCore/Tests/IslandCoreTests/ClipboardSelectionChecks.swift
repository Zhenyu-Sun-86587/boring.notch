import Foundation
import CoreGraphics
import IslandCore

private struct ClipboardSelectionCheckFailure: Error { let message: String }
private func selectionCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ClipboardSelectionCheckFailure(message: message) }
}

/// Pure fixtures: no NSApplication, window, real clipboard or permission access.
func runClipboardSelectionChecks() throws {
    let ids = ["first", "middle", "last"]
    try selectionCheck(ClipboardSelectionPolicy.reconciledID(nil, in: ids) == "first", "empty selection explicitly chooses first")
    try selectionCheck(ClipboardSelectionPolicy.reconciledID("middle", in: ["last", "middle", "first"]) == "middle", "reordering preserves the selected item")
    try selectionCheck(ClipboardSelectionPolicy.reconciledID("deleted", in: ["first", "last"], fallbackIndex: 1) == "last", "deletion selects the nearest remaining row")
    try selectionCheck(ClipboardSelectionPolicy.reconciledID("last", in: [], fallbackIndex: 2) == nil, "no filtered results means no selection")
    try selectionCheck(ClipboardSelectionPolicy.reconciledID("last", in: ids, reset: true) == "first", "a new search explicitly resets to the first result")
    try selectionCheck(ClipboardSelectionPolicy.movedID(nil, in: ids, offset: 1) == "first", "Down from no selection must not skip the first result")
    try selectionCheck(ClipboardSelectionPolicy.movedID("middle", in: ids, offset: 1) == "last", "Down moves exactly one row")
    try selectionCheck(ClipboardSelectionPolicy.movedID("first", in: ids, offset: -1) == "first", "Up clamps without wrapping")
    try selectionCheck(ClipboardSelectionPolicy.movedID("last", in: ids, offset: Int.max) == "last", "large positive offset cannot overflow")
    try selectionCheck(ClipboardSelectionPolicy.movedID("first", in: ids, offset: Int.min) == "first", "large negative offset cannot overflow")
    for key in [ClipboardSelectionPolicy.Key.up, .down, .enter, .escape] {
        try selectionCheck(ClipboardSelectionPolicy.action(for: key, composing: true) == .ignored, "IME composition retains its navigation and confirmation keys")
    }
    try selectionCheck(ClipboardSelectionPolicy.action(for: .down, repeating: true) == .move(1), "held Down keeps native autorepeat")
    try selectionCheck(ClipboardSelectionPolicy.action(for: .up, repeating: true) == .move(-1), "held Up keeps native autorepeat")
    try selectionCheck(ClipboardSelectionPolicy.action(for: .enter) == .activate(paste: true), "Return pastes")
    try selectionCheck(ClipboardSelectionPolicy.action(for: .enter, command: true) == .activate(paste: false), "Command Return only copies")
    try selectionCheck(ClipboardSelectionPolicy.action(for: .enter, repeating: true) == .ignored, "held Return cannot repeatedly paste")
    try selectionCheck(ClipboardSelectionPolicy.action(for: .escape) == .dismiss, "Escape requests dismissal")
    let visible = CGRect(x: 0, y: 40, width: 500, height: 56)
    try selectionCheck(ClipboardSelectionPolicy.scrollEdge(row: visible, viewportHeight: 300, direction: 1) == nil, "visible keyboard selection does not recenter")
    try selectionCheck(ClipboardSelectionPolicy.scrollEdge(row: visible.offsetBy(dx: 0, dy: -60), viewportHeight: 300, direction: -1) == .top, "reveal only the clipped top edge")
    try selectionCheck(ClipboardSelectionPolicy.scrollEdge(row: visible.offsetBy(dx: 0, dy: 240), viewportHeight: 300, direction: 1) == .bottom, "reveal only the clipped bottom edge")
    try selectionCheck(ClipboardSelectionPolicy.scrollEdge(row: nil, viewportHeight: 300, direction: 1) == .bottom, "unrealized lazy rows can scroll into view")
    try selectionCheck(ClipboardSelectionPolicy.scrollEdge(row: visible, viewportHeight: 0, direction: 1) == nil, "a pending viewport layout cannot trigger scrolling")
    let scrolledViewport = CGRect(x: 0, y: 1000, width: 500, height: 300)
    try selectionCheck(ClipboardSelectionPolicy.scrollEdge(row: CGRect(x: 0, y: 1100, width: 500, height: 56), viewport: scrolledViewport, direction: 1) == nil, "already scrolled visible selection stays in place")
    try selectionCheck(ClipboardSelectionPolicy.scrollEdge(row: CGRect(x: 0, y: 1270, width: 500, height: 56), viewport: scrolledViewport, direction: 1) == .bottom, "down follows the current content offset")
    try selectionCheck(ClipboardSelectionPolicy.scrollEdge(row: CGRect(x: 0, y: 980, width: 500, height: 56), viewport: scrolledViewport, direction: -1) == .top, "up follows the current content offset")
    let viewport = CGRect(x: 0, y: 0, width: 500, height: 300)
    let frames = ["first": visible, "partially-clipped": CGRect(x: 0, y: 280, width: 500, height: 56)]
    try selectionCheck(ClipboardSelectionPolicy.hitID(at: CGPoint(x: 100, y: 60), viewport: viewport, rows: frames) == "first", "click hits a visible row immediately")
    try selectionCheck(ClipboardSelectionPolicy.hitID(at: CGPoint(x: 100, y: 310), viewport: viewport, rows: frames) == nil, "footer clicks cannot select clipped rows")
    try selectionCheck(ClipboardSelectionPolicy.hitID(at: CGPoint(x: 100, y: -5), viewport: viewport, rows: frames) == nil, "header clicks cannot select a list row")
    var pointer = ClipboardPointerSelectionGate()
    let stationary = CGPoint(x: 200, y: 200)
    pointer.keyboardNavigated(pointerAt: stationary)
    try selectionCheck(!pointer.acceptsMovement(at: stationary, delta: .zero), "scrolling under a stationary pointer cannot override the keyboard")
    try selectionCheck(!pointer.acceptsMovement(at: stationary, delta: CGSize(width: 1, height: 0)), "tracking refresh at the keyboard anchor cannot override selection")
    try selectionCheck(pointer.acceptsMovement(at: CGPoint(x: 202, y: 200), delta: CGSize(width: 2, height: 0)), "actual mouse movement resumes hover selection")
    try selectionCheck(!pointer.acceptsMovement(at: CGPoint(x: 202, y: 200), delta: CGSize(width: 2, height: 0)), "replayed motion at the same screen position cannot select another scrolled-under row")
    try selectionCheck(pointer.acceptsMovement(at: CGPoint(x: 204, y: 200), delta: CGSize(width: 2, height: 0)), "subsequent real movement still updates pointer selection")
    var click = ClipboardPointerActivation()
    let pressedAt = CGPoint(x: 100, y: 60)
    try selectionCheck(click.mouseDown(rowID: "first", at: pressedAt).consumesEvent, "a row's primary press is consumed before AppKit can change focus")
    let release = click.mouseUp(rowID: "first", at: pressedAt)
    try selectionCheck(release == .init(consumesEvent: true, activatedID: "first"), "single matching mouseUp pastes once and is consumed")
    try selectionCheck(click.mouseUp(rowID: "first", at: pressedAt).activatedID == nil, "replayed mouseUp cannot paste twice")
    try selectionCheck(click.mouseDown(rowID: "first", at: pressedAt, clickCount: 2).consumesEvent, "a double-click's extra press does not re-focus the closing panel")
    try selectionCheck(click.mouseUp(rowID: "first", at: pressedAt) == .init(consumesEvent: true), "double-click continuation is consumed without another paste")
    _ = click.mouseDown(rowID: "first", at: pressedAt)
    try selectionCheck(click.mouseUp(rowID: "last", at: pressedAt).activatedID == nil, "press and release must name the same row")
    _ = click.mouseDown(rowID: "first", at: pressedAt)
    click.mouseDragged(to: CGPoint(x: 110, y: 60))
    click.mouseDragged(to: pressedAt)
    try selectionCheck(click.mouseUp(rowID: "first", at: pressedAt).activatedID == nil, "dragging away then returning is not a click")
    _ = click.mouseDown(rowID: "first", at: pressedAt)
    click.cancelActivation()
    try selectionCheck(click.mouseUp(rowID: "first", at: pressedAt) == .init(consumesEvent: true), "wheel/right-button activity cancels paste but still consumes the captured primary release")
    try selectionCheck(!click.mouseDown(rowID: nil, at: pressedAt).consumesEvent, "scrollbars and blank/header/footer areas keep their native mouse press")
    try selectionCheck(!click.mouseUp(rowID: nil, at: pressedAt).consumesEvent, "a non-row gesture keeps its native mouse release")
    _ = click.mouseDown(rowID: "first", at: pressedAt)
    click.cancel()
    try selectionCheck(click.mouseUp(rowID: "first", at: pressedAt).activatedID == nil, "dismantled observer cannot complete a stale paste click")
    _ = click.mouseDown(rowID: "last", at: pressedAt)
    try selectionCheck(click.mouseUp(rowID: "last", at: pressedAt).activatedID == "last", "a fresh separate single click still pastes normally")
    print("PASS clipboard selection: search/reorder/delete, key autorepeat/IME, edge scrolling and pointer intent")
}
