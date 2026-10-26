import AppKit

@MainActor
enum ClipboardPermissionAlert {
    static func make(title: String, message: String, primary: String, hasCancel: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.showsSuppressionButton = false
        alert.showsHelp = false
        alert.addButton(withTitle: primary)
        if hasCancel { alert.addButton(withTitle: "取消") }
        // This is a nonmodal alert: runModal/beginSheet won't perform the lazy layout for us.
        // Lay out before accessing the window or rebinding button actions to avoid nib placeholders.
        alert.layout()
        return alert
    }
}
