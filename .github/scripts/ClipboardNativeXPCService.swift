// Fixture-only protocol. This method is never compiled into the shipping service.
import Foundation

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
                    self.production.clipboardPasteAccess { accessData in
                        guard let access = try? JSONDecoder().decode(ClipboardPasteAccess.self, from: accessData) else { reply(false); return }
                        guard access.accessibility else { reply(true); return }
                        // AX is queried only for this windowless fixture client, never a user app.
                        self.production.captureClipboardTarget(self.clientPID) { captured in
                            guard let captured, let target = try? JSONDecoder().decode(ClipboardPasteTarget.self, from: captured),
                                  target.processIdentifier == self.clientPID, !target.hasWindow, !target.hasElement else { reply(false); return }
                            self.production.releaseClipboardTarget(target.token)
                            reply(true)
                        }
                    }
                }
        }
    }
    func postFixture(_ marker: Int64, with reply: @escaping (Bool) -> Void) {
        // Only the connection's own client can receive this fixture event. No global session post.
        reply(ClipboardPasteEvent.post(to: clientPID, marker: marker))
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
