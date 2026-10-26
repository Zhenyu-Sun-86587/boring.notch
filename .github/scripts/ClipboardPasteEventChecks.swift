// Exercise production event construction and routing with an injected recording sink only.
// No app activation, windows, AX tree, pasteboard access, permission request or input posting.
import AppKit
import CoreGraphics

private struct EventFailure: Error { let message: String }
private func checkEvent(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw EventFailure(message: message) }
}

@main private enum ClipboardPasteEventChecks {
    static func main() throws {
        let target: Int32 = 42_001
        let marker: Int64 = 0x53455353494F4E
        var captured: [(CGEvent, CGEventTapLocation)] = []
        var focusReads = 0
        let environment = ClipboardPasteEvent.Environment(hasPostAccess: { true }, frontmostPID: {
            focusReads += 1
            return target
        }, post: { captured.append(($0, $1)) })
        try checkEvent(ClipboardPasteEvent.post(to: target, marker: marker, environment: environment), "Authorized foreground target was refused")
        try checkEvent(captured.count == 2 && focusReads == 2, "Must recheck foreground and produce exactly one down/up pair")
        try checkEvent(captured.allSatisfy { $0.1 == .cgSessionEventTap }, "Production must select one session tap, never two routes")
        try checkEvent(captured[0].0.type == .keyDown && captured[1].0.type == .keyUp, "Shortcut order")
        let command = CGEventFlags.maskCommand.rawValue | 0x000008
        for (event, _) in captured {
            try checkEvent(event.getIntegerValueField(.keyboardEventKeycode) == 9, "Shortcut keycode")
            try checkEvent(event.flags.rawValue == command, "Command flags must not inherit held Shift/Control/Option")
            try checkEvent(event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.combinedSessionState.rawValue), "Shortcut must use the combined session source")
            try checkEvent(event.getIntegerValueField(.eventSourceUserData) == marker, "Fixture marker")
        }

        var deniedFocusReads = 0
        let denied = ClipboardPasteEvent.Environment(hasPostAccess: { false }, frontmostPID: {
            deniedFocusReads += 1; return target
        }, post: { _, _ in throwUnexpectedPost() })
        try checkEvent(!ClipboardPasteEvent.post(to: target, environment: denied) && deniedFocusReads == 0,
                       "Denied permission must not continue to focus or delivery")

        var invalidAccessReads = 0
        let invalid = ClipboardPasteEvent.Environment(hasPostAccess: {
            invalidAccessReads += 1; return true
        }, frontmostPID: { target }, post: { _, _ in throwUnexpectedPost() })
        for pid: Int32 in [-1, 0] {
            try checkEvent(!ClipboardPasteEvent.post(to: pid, environment: invalid), "Invalid PID")
        }
        try checkEvent(invalidAccessReads == 0, "Invalid destination must stop before system probing")

        for foreground: Int32? in [nil, target + 1] {
            let other = ClipboardPasteEvent.Environment(hasPostAccess: { true }, frontmostPID: { foreground },
                                                       post: { _, _ in throwUnexpectedPost() })
            try checkEvent(!ClipboardPasteEvent.post(to: target, environment: other), "A missing/different foreground must never receive a paste")
        }

        for foregroundAfterConstruction: Int32? in [nil, target + 1] {
            var observations = 0
            let changed = ClipboardPasteEvent.Environment(hasPostAccess: { true }, frontmostPID: {
                observations += 1
                return observations == 1 ? target : foregroundAfterConstruction
            }, post: { _, _ in throwUnexpectedPost() })
            try checkEvent(!ClipboardPasteEvent.post(to: target, environment: changed) && observations == 2,
                           "App switching during construction must cancel the complete pair")
        }
        print("PASS production session-event policy: single session tap, combined source, Cmd+V down/up, denied/invalid/missing targets, foreground recheck and switching cancellation; recording sink only, zero events posted")
    }

    private static func throwUnexpectedPost() {
        fatalError("Guarded test unexpectedly reached event delivery; no event was posted")
    }
}
