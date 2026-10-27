import AppKit

extension InteractionDiagnostics {
    @MainActor static func windowFields(_ window: NSWindow?) -> [String: String] {
        ["window": window.map { String($0.windowNumber) } ?? "nil",
         "keyWindow": NSApp.keyWindow.map { String($0.windowNumber) } ?? "nil",
         "windowKey": String(window?.isKeyWindow == true), "visible": String(window?.isVisible == true),
         "canKey": String(window?.canBecomeKey == true), "active": String(NSApp.isActive),
         "responder": window?.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "nil",
         "foreground": NSWorkspace.shared.frontmostApplication.map { String($0.processIdentifier) } ?? "nil"]
    }
}
