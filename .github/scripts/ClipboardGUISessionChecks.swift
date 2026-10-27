// Windowless XPC session probe. No clipboard, AX tree, event posting or permission request.
import AppKit
import CoreGraphics

@objc protocol ClipboardGUISessionProtocol {
    func state(with reply: @escaping (Bool, Bool, Bool) -> Void)
}

#if SESSION_HELPER
private final class SessionService: NSObject, ClipboardGUISessionProtocol {
    func state(with reply: @escaping (Bool, Bool, Bool) -> Void) {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        reply(session != nil, session?[kCGSessionOnConsoleKey as String] as? Bool == true,
              session?["CGSSessionScreenIsLocked"] as? Bool == true)
    }
}
private final class SessionDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ClipboardGUISessionProtocol.self)
        connection.exportedObject = SessionService()
        connection.resume()
        return true
    }
}
@main private enum SessionHelper {
    static func main() {
        let delegate = SessionDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
    }
}
#else
@main private enum SessionHost {
    static func main() {
        guard CommandLine.arguments.count == 3,
              CGSessionCopyCurrentDictionary() != nil else {
            print("FAIL GUI session fixture: host is not in a Quartz GUI session")
            exit(2)
        }
        let expected = CommandLine.arguments[2] == "true"
        let connection = NSXPCConnection(serviceName: CommandLine.arguments[1])
        connection.remoteObjectInterface = NSXPCInterface(with: ClipboardGUISessionProtocol.self)
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            print("FAIL GUI session fixture transport:", error.localizedDescription)
            exit(2)
        } as! ClipboardGUISessionProtocol
        proxy.state { available, onConsole, locked in
            print("GUI_SESSION expected=\(expected) available=\(available) onConsole=\(onConsole) locked=\(locked)")
            connection.invalidate()
            exit(available == expected ? 0 : 2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            print("FAIL GUI session fixture: XPC timeout")
            exit(2)
        }
        RunLoop.main.run()
    }
}
#endif
