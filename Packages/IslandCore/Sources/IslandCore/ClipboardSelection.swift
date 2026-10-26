import Foundation
import CoreGraphics

/// Selection and input decisions are independent of the AppKit pasteboard and can be checked with fixtures.
public enum ClipboardSelectionPolicy {
    public enum Key: Sendable { case up, down, enter, escape }
    public enum Action: Sendable, Equatable { case move(Int), activate(paste: Bool), dismiss, ignored }
    public enum ScrollEdge: Sendable, Equatable { case top, bottom }

    public static func action(for key: Key, repeating: Bool = false, command: Bool = false,
                              composing: Bool = false) -> Action {
        guard !composing else { return .ignored }
        switch key {
        case .up: return .move(-1)
        case .down: return .move(1)
        case .enter: return repeating ? .ignored : .activate(paste: !command)
        case .escape: return repeating ? .ignored : .dismiss
        }
    }

    public static func reconciledID(_ current: String?, in ids: [String], fallbackIndex: Int = 0,
                                    reset: Bool = false) -> String? {
        guard !ids.isEmpty else { return nil }
        if !reset, let current, ids.contains(current) { return current }
        return ids[min(max(0, fallbackIndex), ids.count - 1)]
    }

    public static func movedID(_ current: String?, in ids: [String], offset: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        // An absent selection starts at the first result; Down must not silently skip it.
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        let destination = offset >= 0 ? index + min(offset, ids.count - 1 - index) : index + max(offset, -index)
        return ids[destination]
    }

    /// Only keyboard navigation requests scrolling, and only when its row crosses a viewport edge.
    public static func scrollEdge(row: CGRect?, viewportHeight: CGFloat, direction: Int) -> ScrollEdge? {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return nil }
        guard let row else { return direction < 0 ? .top : .bottom }
        guard row.minY.isFinite, row.maxY.isFinite else { return nil }
        if row.minY >= -0.5, row.maxY <= viewportHeight + 0.5 { return nil }
        if row.height > viewportHeight, row.minY <= 0, row.maxY >= viewportHeight { return nil }
        return row.minY < 0 ? .top : .bottom
    }

    public static func hitID(at point: CGPoint, viewport: CGRect, rows: [String: CGRect]) -> String? {
        guard viewport.contains(point) else { return nil }
        return rows.first { $0.value.contains(point) }?.key
    }
}

/// Tracking-area refreshes and scrolling under a stationary pointer aren't mouse selection intent.
public struct ClipboardPointerSelectionGate: Sendable {
    private var keyboardAnchor: CGPoint?
    private var lastAcceptedPointer: CGPoint?
    public init() {}
    public mutating func keyboardNavigated(pointerAt point: CGPoint) { keyboardAnchor = point }
    public mutating func acceptsMovement(at point: CGPoint, delta: CGSize) -> Bool {
        guard point.x.isFinite, point.y.isFinite, delta.width.isFinite, delta.height.isFinite,
              delta.width != 0 || delta.height != 0 else { return false }
        guard keyboardAnchor != point, lastAcceptedPointer != point else { return false }
        keyboardAnchor = nil
        lastAcceptedPointer = point
        return true
    }
}
