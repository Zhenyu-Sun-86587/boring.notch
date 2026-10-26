import Foundation

enum ClipboardFocusRestoration {
    enum Relation { case original, missing, ancestorContainer, differentControl }
    static func mayRestore(sameWindow: Bool, savedElementValid: Bool, relation: Relation) -> Bool {
        sameWindow && savedElementValid && relation != .differentControl
    }
    static func ready(sameWindow: Bool, relation: Relation, capturedElementFocused: Bool) -> Bool {
        sameWindow && (relation == .original || (relation != .differentControl && capturedElementFocused))
    }
}
