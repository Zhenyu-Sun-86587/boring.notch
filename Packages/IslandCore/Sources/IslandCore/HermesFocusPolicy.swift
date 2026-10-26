import Foundation

public struct HermesFocusEligibility: Sendable {
    public var drawerOpen: Bool
    public var hermesSelected: Bool
    public var windowKey: Bool
    public var windowVisible: Bool
    public var windowLocked: Bool
    public var keyboardHandoff: Bool
    public var inputDisabled: Bool
    public var blockingUI: Bool

    public init(drawerOpen: Bool, hermesSelected: Bool, windowKey: Bool, windowVisible: Bool,
                windowLocked: Bool = false, keyboardHandoff: Bool = false,
                inputDisabled: Bool = false, blockingUI: Bool = false) {
        self.drawerOpen = drawerOpen; self.hermesSelected = hermesSelected
        self.windowKey = windowKey; self.windowVisible = windowVisible
        self.windowLocked = windowLocked; self.keyboardHandoff = keyboardHandoff
        self.inputDisabled = inputDisabled; self.blockingUI = blockingUI
    }
    public var permitsFocus: Bool {
        drawerOpen && hermesSelected && windowKey && windowVisible
            && !windowLocked && !keyboardHandoff && !inputDisabled && !blockingUI
    }
}

/// Every close, focus transfer, lock or new appearance invalidates queued work.
public struct HermesFocusGeneration: Sendable {
    public private(set) var value: UInt = 0
    public init() {}
    @discardableResult public mutating func invalidate() -> UInt { value &+= 1; return value }
    public func permits(_ ticket: UInt, eligibility: HermesFocusEligibility) -> Bool {
        ticket == value && eligibility.permitsFocus
    }
}
