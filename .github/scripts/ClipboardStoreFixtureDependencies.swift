// Passive compile-time dependencies for the actual ClipboardStore. None may open
// a permission prompt, read an AX tree, activate an app or render a thumbnail.
import AppKit
import IslandCore

@MainActor final class ClipboardPermissionController {
    static let shared = ClipboardPermissionController()
    func cancelRequests() {}
    func requestOnEnable(readState: () -> ClipboardPermissionPolicy.State,
                         requestRead: () -> ClipboardPermissionPolicy.State) async {
        fatalError("Store copy must not request permission")
    }
}
actor ClipboardThumbnailRenderer {
    static let shared = ClipboardThumbnailRenderer()
    func render(history: ClipboardHistory, id: String) async -> Data? {
        fatalError("Store copy must preserve original bytes without rendering")
    }
}
