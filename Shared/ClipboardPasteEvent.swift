import AppKit
import CoreGraphics

/// Send one normal session shortcut after the helper has restored the original input.
/// A directed process event can be received without being handled like a normal menu shortcut
/// by the target editor. Posting is not an acknowledgement that an editor accepted the paste.
enum ClipboardPasteEvent {
    struct Environment {
        let hasPostAccess: () -> Bool
        let frontmostPID: () -> Int32?
        let post: (CGEvent, CGEventTapLocation) -> Void

        static var system: Self {
            .init(hasPostAccess: { CGPreflightPostEventAccess() },
                  frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                  post: { event, tap in
                    #if CLIPBOARD_EVENT_FIXTURE
                    // Test executables must inject a recording sink or use their explicit
                    // own-PID fixture sender. No accidental default call may send global input.
                    preconditionFailure("Session event posting is disabled in clipboard fixtures")
                    #else
                    event.post(tap: tap)
                    #endif
                  })
        }
    }

    static func post(to pid: Int32, marker: Int64 = 0, environment: Environment = .system) -> Bool {
        guard pid > 0, environment.hasPostAccess(), environment.frontmostPID() == pid,
              let events = makeEvents(marker: marker),
              environment.frontmostPID() == pid else { return false }
        // Keep the pair synchronous, without any suspension or fallback between down/up.
        // The caller also checks AX ownership, physical key release and clipboard generation.
        for event in events { environment.post(event, .cgSessionEventTap) }
        return true
    }

    /// Construction is separated from delivery so safe fixtures can inspect the real events.
    static func makeEvents(marker: Int64 = 0) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return nil }
        let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
        for event in [down, up] {
            event.flags = command
            event.setIntegerValueField(.eventSourceUserData, value: marker)
        }
        return [down, up]
    }
}
