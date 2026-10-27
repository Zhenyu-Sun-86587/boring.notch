import AppKit

@main enum ClipboardNativeXPCChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let marker: Int64 = 0x584350434C4950
        let service = Bundle.main.bundleIdentifier! + ".Helper"
        let connection = NSXPCConnection(serviceName: service)
        connection.remoteObjectInterface = NSXPCInterface(with: ClipboardNativeFixtureProtocol.self)
        connection.resume()
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in
            print("FAIL native XPC transport: \(error)"); exit(2)
        }) as? ClipboardNativeFixtureProtocol else { print("FAIL native XPC proxy"); exit(2) }
        var received = 0
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker else { return event }
            guard event.keyCode == 9, event.modifierFlags.contains(.command),
                  (received == 0 && event.type == .keyDown) || (received == 1 && event.type == .keyUp) else {
                print("FAIL native XPC event"); exit(2)
            }
            received += 1
            if received == 2 {
                if let monitor { NSEvent.removeMonitor(monitor) }
                let unchanged = foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier
                print("PASS isolated sandbox-host/XPC-helper PID fixture: Cmd+V received=2 unchangedForeground=\(unchanged) windows=\(app.windows.count); not production session-route acceptance")
                connection.invalidate()
                exit(unchanged && app.windows.isEmpty ? 0 : 2)
            }
            return nil
        }
        remote.validateGuards { valid in
            guard valid else { print("FAIL production helper invalid-PID guards"); exit(2) }
            print("PASS production helper early guards: no clipboard/focus/event access")
            remote.access { data in
                guard let access = try? JSONDecoder().decode(ClipboardPasteAccess.self, from: data) else { print("FAIL helper access decoding"); exit(2) }
                guard access.guiSessionAvailable == true else { print("FAIL shipping helper did not join GUI session"); exit(2) }
                print("PASS production helper GUI session available")
                print("Native XPC helper access: AX=\(access.accessibility) postEvents=\(access.postEvents) helperPID=\(access.processIdentifier)")
                guard access.postEvents else { print("SKIP isolated XPC/PID fixture: no pre-existing event-post permission; never requested"); exit(0) }
                remote.postFixture(marker) { success in
                    guard success else { print("FAIL native XPC posting"); exit(2) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { print("FAIL native XPC deadline received=\(received)"); exit(2) }
        app.run()
    }
}
