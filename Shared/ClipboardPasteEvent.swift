import CoreGraphics

/// The PID route prevents a last-moment app switch from sending Command-V elsewhere.
/// CGEventPostToPid has no delivery acknowledgement; success here means constructed/posted,
/// never that a receiving editor accepted a paste. Native fixtures verify the receiving route.
enum ClipboardPasteEvent {
    static func post(to pid: Int32, marker: Int64 = 0) -> Bool {
        guard pid > 0, CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
        for event in [down, up] {
            event.flags = command
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.postToPid(pid)
        }
        return true
    }
}
