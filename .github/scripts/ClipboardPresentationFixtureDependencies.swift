// Used for compile-only verification of the actual clipboard store/presentation/
// permission controller. Every external service remains passive or traps if run.
import AppKit
import Combine
import IslandCore

enum NotchViews { case home, hermes, clipboard }
@MainActor final class BoringViewModel {
    var screenUUID: String?
    func open(tab: NotchViews) {}
    func close() {}
}
@MainActor final class BoringViewCoordinator {
    static let shared = BoringViewCoordinator()
    var firstLaunch = false
    var currentView = NotchViews.clipboard
    func releaseKeyboard() {}
}
@MainActor final class NotchWindowManager {
    struct Context { let viewModel: BoringViewModel; var window: NSWindow? }
    var isScreenLocked = false
    var contexts: [String: Context] = [:]
    var windows: [String: NSWindow] = [:]
    var viewModels: [String: BoringViewModel] = [:]
    var primaryViewModel = BoringViewModel()
    var primaryWindow: NSWindow?
}
class BoringNotchSkyLightWindow: NSPanel {
    var allowsIslandKeyboard = false
    var isIslandKeyboardHandoffActive = false
    func beginIslandKeyboardHandoff() -> UUID { fatalError("compile-only") }
    func endIslandKeyboardHandoff(_ token: UUID, restoreVisible: Bool) { fatalError("compile-only") }
    func releaseIslandKeyboard() { fatalError("compile-only") }
}
@MainActor final class XPCHelperClient {
    static let shared = XPCHelperClient()
    func captureClipboardTarget(_ pid: Int32) async -> ClipboardPasteTarget? { fatalError("compile-only") }
    func releaseClipboardTarget(_ token: String) { fatalError("compile-only") }
    func clipboardPasteAccess() async -> ClipboardPasteAccess? { fatalError("compile-only") }
    func requestClipboardPasteAuthorization(_ permission: ClipboardPastePermission) { fatalError("compile-only") }
    func pasteClipboard(to pid: Int32, changeCount: Int, targetToken: String?, requestID: UUID) async -> ClipboardPasteResult { fatalError("compile-only") }
}
actor ClipboardThumbnailRenderer {
    static let shared = ClipboardThumbnailRenderer()
    func render(history: ClipboardHistory, id: String) async -> Data? { fatalError("compile-only") }
}
enum AccessibilityPermission { static let displayName = "辅助功能" }
extension NSScreen {
    var displayUUID: String? { nil }
    static func screen(withUUID: String) -> NSScreen? { nil }
}
let openNotchSize = CGSize(width: 640, height: 420)
