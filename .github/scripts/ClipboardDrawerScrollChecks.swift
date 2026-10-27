// Render the production drawer offscreen, with synthetic records and no clipboard/focus access.
import AppKit
import Combine
import IslandCore
import SwiftUI

@MainActor enum DrawerMetrics {
    static var rows: [String: CGRect] = [:]
    static var viewport = CGRect.zero
}
extension Notification.Name { static let islandLocked = Notification.Name("fixture.locked") }
enum NotchViews { case clipboard }
@MainActor final class BoringViewCoordinator {
    static let shared = BoringViewCoordinator()
    var currentView = NotchViews.clipboard
}
class BoringNotchSkyLightWindow: NSPanel {
    var isIslandScreenLocked = false
    var isIslandKeyboardHandoffActive = false
}
@MainActor final class ClipboardPresentation: ObservableObject {
    static let shared = ClipboardPresentation()
    let sessionPresented = false
    let keyboardTargetReady = false
}
@MainActor final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()
    @Published var search = ""
    @Published var filteredRecords: [ClipboardHistoryRecord] = []
    @Published var selectedID: String?
    @Published var keyboardSelectionRevision: UInt = 0
    var keyboardSelectionDirection = 1
    let keyboardSessionActive = false
    let enabled = true, readDenied = false, needsReadAccess = false, needsPasteAccess = false
    let requestingPermissions = false, busy = false, pasting = false
    let message: String? = nil
    let sessionID = UUID()
    var selectedRecord: ClipboardHistoryRecord? { filteredRecords.first { $0.id == selectedID } }
    func start() {}
    func requestPermissions() { fatalError("No permission requests") }
    func favorite(_ record: ClipboardHistoryRecord) {}
    func delete(_ record: ClipboardHistoryRecord) {}
    func copy(_ record: ClipboardHistoryRecord, paste: Bool) { fatalError("No clipboard access") }
    func copySelected(paste: Bool) { fatalError("No clipboard access") }
    func clearMessage() {}
    func dismiss() {}
    func thumbnail(for record: ClipboardHistoryRecord) async -> NSImage? { nil }
    func select(_ id: String) { selectedID = id }
    func moveSelection(_ offset: Int) {
        keyboardSelectionDirection = offset
        selectedID = ClipboardSelectionPolicy.movedID(selectedID, in: filteredRecords.map(\.id), offset: offset)
        keyboardSelectionRevision &+= 1
    }
}

@main private enum DrawerScrollChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let store = ClipboardStore.shared
        let records = (0..<80).map { index -> [String: Any] in
            ["id": "row-\(index)", "kind": "text", "title": "Record \(index)", "searchableText": "fixture",
             "copiedAt": 0, "favorite": false, "byteCount": 7, "storedBytes": 7, "itemCount": 1]
        }
        store.filteredRecords = try JSONDecoder().decode([ClipboardHistoryRecord].self,
            from: JSONSerialization.data(withJSONObject: records))
        store.selectedID = store.filteredRecords.first!.id
        let window = NSPanel(contentRect: NSRect(x: 25000, y: 25000, width: 640, height: 420),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: ClipboardDrawer().padding(12).environment(\.colorScheme, .dark))
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { fatalError("Fixture must stay offscreen") }
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(350))
        var checked = 0
        for offset in Array(repeating: 1, count: 45) + Array(repeating: -1, count: 35) {
            store.moveSelection(offset)
            try await Task.sleep(for: .milliseconds(180))
            guard let id = store.selectedID, let row = DrawerMetrics.rows[id],
                  DrawerMetrics.viewport.height > 0,
                  row.minY >= DrawerMetrics.viewport.minY - 1,
                  row.maxY <= DrawerMetrics.viewport.maxY + 1 else {
                print("FAIL drawer scroll: selection=\(store.selectedID ?? "nil") viewport=\(DrawerMetrics.viewport) row=\(String(describing: store.selectedID.flatMap { DrawerMetrics.rows[$0] }))")
                exit(2)
            }
            guard !window.isKeyWindow, !window.isMainWindow,
                  foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier else { fatalError("Fixture changed user focus") }
            checked += 1
        }
        guard DrawerMetrics.viewport.minY > 0 else { fatalError("Fixture never scrolled") }
        print("PASS production clipboard drawer scrolling: \(checked) down/up selections revealed in actual SwiftUI viewport; offscreen, no clipboard/input/focus access")
    }
}
