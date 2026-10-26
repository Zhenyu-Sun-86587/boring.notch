import Foundation

/// AX can confirm an input, prove that it changed, or fail to describe it. Only
/// positive evidence of a changed destination is a conflict; unknown uses native focus.
enum ClipboardFocusRestoration {
    enum Match: Sendable { case matched, unknown, conflict }
    enum Relation: Sendable { case original, missing, ancestorContainer, differentControl, unavailable }
    struct Evidence: Sendable {
        var window: Match = .unknown
        var savedElementAvailable = false
        var relation: Relation = .unavailable
        var capturedElementFocused = false
        var restorationAvailable = true
    }
    struct Assessment: Sendable {
        let match: Match
        let mayRestore: Bool
        let inputReady: Bool
    }
    struct Lease {
        private(set) var conflicted = false
        mutating func assess(_ evidence: Evidence) -> Assessment {
            let result = ClipboardFocusRestoration.assess(evidence)
            conflicted = conflicted || result.match == .conflict
            return conflicted ? Assessment(match: .conflict, mayRestore: false, inputReady: false) : result
        }
    }

    /// A readable unfamiliar role/container is not proof of a different input.
    static func relation(sameElement: Bool, currentRole: String?, knownAncestor: Bool) -> Relation {
        guard let currentRole else { return .unavailable }
        if sameElement { return .original }
        let containers = Set(["AXWebArea", "AXGroup", "AXScrollArea", "AXWindow", "AXApplication", "AXSplitGroup", "AXLayoutArea"])
        if containers.contains(currentRole) { return knownAncestor ? .ancestorContainer : .unavailable }
        let controls = Set(["AXTextField", "AXTextArea", "AXComboBox", "AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton", "AXMenuButton", "AXLink", "AXSearchField", "AXSecureTextField", "AXIncrementor"])
        return controls.contains(currentRole) ? .differentControl : .unavailable
    }

    static func assess(_ evidence: Evidence) -> Assessment {
        if evidence.window == .conflict || (evidence.savedElementAvailable && evidence.relation == .differentControl) {
            return .init(match: .conflict, mayRestore: false, inputReady: false)
        }
        guard evidence.window == .matched, evidence.savedElementAvailable, evidence.restorationAvailable,
              evidence.relation == .original || evidence.relation == .ancestorContainer else {
            return .init(match: .unknown, mayRestore: false, inputReady: true)
        }
        return .init(match: .matched, mayRestore: true,
                     inputReady: evidence.relation == .original || evidence.capturedElementFocused)
    }
}
