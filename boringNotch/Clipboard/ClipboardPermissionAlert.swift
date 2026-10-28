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

@MainActor
enum ClipboardFeedbackPanel {
    static func make(message: String) -> NSPanel {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 360
        let size = label.fittingSize
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 392, height: max(60, size.height + 28)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Clip the complete backdrop subtree. Rounding the effect layer alone
        // leaves its private material/backdrop children visible at the corners.
        let clip = NSView(frame: panel.contentView!.bounds)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.masksToBounds = true
        let background = NSVisualEffectView(frame: clip.bounds)
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        label.frame = background.bounds.insetBy(dx: 16, dy: 14)
        background.addSubview(label)
        clip.addSubview(background)
        panel.contentView = clip
        return panel
    }
}
