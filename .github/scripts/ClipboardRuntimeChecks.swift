// Real, joined-session XPC A/B. Only process IDs, API error codes and runtime
// booleans cross the connection. No input elements, titles, clipboard or events.
import AppKit
import ApplicationServices

@objc private protocol RuntimeProtocol {
    func snapshot(_ initialize: Bool, with reply: @escaping (Data) -> Void)
}

private struct Snapshot: Codable {
    let initialized: Bool
    let prohibited: Bool
    let windowCount: Int
    let trusted: Bool
    let session: Bool
    let focusError: Int32
    let focusedPID: Int32?
    let productionPID: Int32?
}

#if RUNTIME_HELPER
private final class RuntimeService: NSObject, RuntimeProtocol {
    func snapshot(_ initialize: Bool, with reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            if initialize { ClipboardHelperRuntime.prepare() }
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.05)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value)
            var focusedPID: Int32?
            if error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                var pid: pid_t = 0
                if AXUIElementGetPid(value as! AXUIElement, &pid) == .success { focusedPID = pid }
            }
            let snapshot = Snapshot(initialized: NSApp != nil,
                prohibited: NSApp?.activationPolicy() == .prohibited, windowCount: NSApp?.windows.count ?? 0,
                trusted: AXIsProcessTrusted(), session: CGSessionCopyCurrentDictionary() != nil,
                focusError: error.rawValue, focusedPID: focusedPID,
                productionPID: ClipboardForeground.processIdentifier())
            reply(try! JSONEncoder().encode(snapshot))
        }
    }
}
private final class RuntimeDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RuntimeProtocol.self)
        connection.exportedObject = RuntimeService()
        connection.resume()
        return true
    }
}
@main private enum RuntimeHelper {
    static func main() {
        #if RUNTIME_COLD_START
        MainActor.assumeIsolated { ClipboardHelperRuntime.prepare() }
        #endif
        let delegate = RuntimeDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
    }
}
#else
@main private enum RuntimeHost {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let coldStart = CommandLine.arguments.dropFirst().first == "cold"
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let connection = NSXPCConnection(serviceName: Bundle.main.bundleIdentifier! + (coldStart ? ".ColdHelper" : ".Helper"))
        connection.remoteObjectInterface = NSXPCInterface(with: RuntimeProtocol.self)
        connection.resume()
        let remote = connection.remoteObjectProxyWithErrorHandler { error in
            print("FAIL runtime XPC transport:", error.localizedDescription); exit(2)
        } as! RuntimeProtocol
        remote.snapshot(false) { data in
            let baseline = try! JSONDecoder().decode(Snapshot.self, from: data)
            print("BASELINE XPC runtime: initialized=\(baseline.initialized) trusted=\(baseline.trusted) session=\(baseline.session) focusError=\(baseline.focusError) pid=\(baseline.focusedPID ?? 0)")
            guard baseline.initialized == coldStart && baseline.windowCount == 0,
                  !coldStart || baseline.prohibited else {
                print("FAIL helper initialization did not match its entry point"); exit(2)
            }
            remote.snapshot(true) { data in
                let ready = try! JSONDecoder().decode(Snapshot.self, from: data)
                print("PRODUCTION XPC runtime: initialized=\(ready.initialized) prohibited=\(ready.prohibited) windows=\(ready.windowCount) trusted=\(ready.trusted) session=\(ready.session) focusError=\(ready.focusError) pid=\(ready.focusedPID ?? 0)")
                guard ready.initialized && ready.prohibited && ready.windowCount == 0 && ready.session,
                      foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier,
                      !app.isActive && app.windows.isEmpty else {
                    print("FAIL runtime initialization changed foreground or opened a window"); exit(2)
                }
                if ready.trusted && baseline.focusError == AXError.cannotComplete.rawValue && ready.focusError == 0,
                   ready.focusedPID != nil && ready.focusedPID == ready.productionPID {
                    print("REPRODUCED XPC focus root: bare trusted helper returns -25204; production AppKit initialization restores live keyboard PID without activation")
                } else if !ready.trusted {
                    print("SKIP real focus query acceptance: no existing AX permission; never requested")
                } else if ready.focusError != 0 || ready.focusedPID == nil {
                    print("INCONCLUSIVE real focus query: current GUI exposes no system-wide focused application")
                } else {
                    guard ready.productionPID == ready.focusedPID else { print("FAIL production foreground differs from native AX"); exit(2) }
                    print(coldStart ? "PASS cold-start helper focus matches production query" : "PASS native runtime focus matches production query; negative control differs by OS")
                }
                remote.snapshot(true) { data in
                    let repeated = try! JSONDecoder().decode(Snapshot.self, from: data)
                    guard repeated.initialized && repeated.prohibited && repeated.windowCount == 0,
                          foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier,
                          !app.isActive && app.windows.isEmpty else {
                        print("FAIL repeat initialization changed runtime or foreground"); exit(2)
                    }
                    print("PASS production helper runtime: joined GUI session, initialized AppKit, prohibited activation, zero windows and unchanged foreground; zero clipboard or input events")
                    print("PASS runtime entry mode: \(coldStart ? "cold" : "baseline")")
                    connection.invalidate()
                    exit(0)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { print("FAIL runtime XPC timeout"); exit(2) }
        app.run()
    }
}
#endif
