// Windowless, explicitly PID-scoped event reception. Never reads/writes a clipboard or activates.
import AppKit
import ApplicationServices

@main enum ClipboardNativeEventChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let original = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let marker: Int64 = 0x434C4950464958
        var received = 0
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker else { return event }
            guard event.keyCode == 9, event.modifierFlags.contains(.command),
                  (received == 0 && event.type == .keyDown) || (received == 1 && event.type == .keyUp) else {
                print("FAIL native PID event contents/order"); exit(2)
            }
            received += 1
            if received == 2 {
                if let monitor { NSEvent.removeMonitor(monitor) }
                let unchanged = NSWorkspace.shared.frontmostApplication?.processIdentifier == original
                print("PASS isolated own-PID fixture transport: Cmd+V down/up received=2 unchangedForeground=\(unchanged) windows=\(app.windows.count); not production session-route acceptance")
                exit(unchanged && app.windows.isEmpty ? 0 : 2)
            }
            // Consume the fixture shortcut before any AppKit paste action can run.
            return nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let access = CGPreflightPostEventAccess()
            print("Native fixture access: AX=\(AXIsProcessTrusted()) postEvents=\(access)")
            guard access else { print("SKIP isolated own-PID fixture transport: no pre-existing event-post permission; never requested"); exit(0) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == original,
                  let events = ClipboardPasteEvent.makeEvents(marker: marker) else { print("FAIL fixture event construction"); exit(2) }
            // Explicit fixture-only delivery. The production default is a session event and
            // is disabled at compile time in this executable; never call that default here.
            for event in events { event.postToPid(ProcessInfo.processInfo.processIdentifier) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { print("FAIL native route deadline received=\(received)"); exit(2) }
        app.run()
    }
}
