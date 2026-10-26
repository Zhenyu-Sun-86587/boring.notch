// Fixture-only protocol. This method is never compiled into the shipping service.
import Foundation
import CoreGraphics

private final class FixtureService: NSObject, ClipboardNativeFixtureProtocol {
    private let clientPID: Int32
    private let production: BoringNotchXPCHelper
    init(_ connection: NSXPCConnection) {
        clientPID = connection.processIdentifier
        production = BoringNotchXPCHelper(connection: connection)
    }
    func access(with reply: @escaping (Data) -> Void) { production.clipboardPasteAccess(with: reply) }
    func validateGuards(with reply: @escaping (Bool) -> Void) {
        production.captureClipboardTarget(-1) { data in
            self.production.pasteClipboard(toProcessIdentifier: -1, hostProcessIdentifier: self.clientPID,
                pasteboardChangeCount: -1, targetToken: nil, requestID: UUID().uuidString) { result in
                    guard data == nil && result == ClipboardPasteResult.targetUnavailable.rawValue else { reply(false); return }
                    // Invalid PID guards stop before any AX input-tree or clipboard access.
                    reply(true)
                }
        }
    }
    func postFixture(_ marker: Int64, with reply: @escaping (Bool) -> Void) {
        // Only the connection's own client can receive this fixture event. No global session post.
        guard clientPID > 0, CGPreflightPostEventAccess(),
              let events = ClipboardPasteEvent.makeEvents(marker: marker) else { reply(false); return }
        for event in events { event.postToPid(clientPID) }
        reply(true)
    }
}
private final class FixtureDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ClipboardNativeFixtureProtocol.self)
        connection.exportedObject = FixtureService(connection)
        connection.resume()
        return true
    }
}
@main private enum ClipboardNativeXPCService {
    static func main() {
        let delegate = FixtureDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
    }
}
