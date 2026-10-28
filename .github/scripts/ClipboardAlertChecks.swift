import AppKit
import QuartzCore

private struct AlertFailure: Error, CustomStringConvertible { let description: String }
@MainActor private func requireAlert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AlertFailure(description: message) }
}

@MainActor private func visibleSubviews(_ view: NSView) -> [NSView] {
    guard !view.isHidden else { return [] }
    return [view] + view.subviews.flatMap { visibleSubviews($0) }
}

@MainActor private func unlaidOutAlert(title: String, message: String) -> NSAlert {
    // Exact prior construction order: asynchronous nonmodal presentation did not invoke the
    // runModal/beginSheet APIs which ordinarily prepare NSAlert's internal layout.
    let prompt = NSAlert()
    prompt.messageText = title
    prompt.informativeText = message
    prompt.alertStyle = .informational
    prompt.addButton(withTitle: "打开设置")
    prompt.addButton(withTitle: "取消")
    return prompt
}

@main private enum ClipboardAlertChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let beforeVisible = Set(app.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let title = "允许自动粘贴"
        let message = "尚未允许读取与恢复输入焦点。请在“辅助功能”中允许当前的 Boring Notch。\n\n开关已打开仍失败时，请移除旧项目，再添加当前应用。授权后，回到目标输入框并重新打开剪贴板。"
        let baseline = unlaidOutAlert(title: title, message: message)
        baseline.window.isReleasedWhenClosed = false
        let baselineViews = visibleSubviews(baseline.window.contentView!)
        let baselineButtons = baselineViews.compactMap { $0 as? NSButton }.map(\.title)
        let baselineBodyHeight = baselineViews.compactMap { $0 as? NSTextField }.first { $0.stringValue == message }?.bounds.height ?? 0
        let baselineBroken = baselineButtons.contains("") || baselineButtons.contains { $0.contains("<") }
        print("BASELINE nonmodal alert before layout: visible=\(baseline.window.isVisible), placeholderButtons=\(baselineButtons.filter { $0.isEmpty || $0.contains("<") }.count), bodyHeight=\(baselineBodyHeight)")
        try requireAlert(!baseline.window.isVisible, "Baseline alert was displayed")
        baseline.window.close()

        let cases: [(String, String, String, Bool)] = [
            (title, message, "打开设置", true),
            ("自动粘贴未完成", "键盘焦点未能返回原输入框。请重新打开剪贴板后再试。\n内容已复制，可按 ⌘V 手动粘贴。", "好", false),
            ("允许读取剪贴板", "请在系统设置中将 Boring Notch 的剪贴板访问设为“始终允许”。", "打开设置", true),
            ("无法检查控制权限", "辅助进程未响应，请稍后重试。", "好", false),
            ("允许发送粘贴按键", "请在“辅助功能”中允许当前的 Boring Notch。授权后，回到目标输入框并重新打开剪贴板。", "打开设置", true)
        ]
        var textChecks = 0, buttonChecks = 0
        for (title, message, primary, hasCancel) in cases {
            let prompt = ClipboardPermissionAlert.make(title: title, message: message, primary: primary, hasCancel: hasCancel)
            let window = prompt.window
            window.isReleasedWhenClosed = false
            defer { window.close() }
            try requireAlert(!window.isVisible && !window.isKeyWindow && !window.isMainWindow, "Production alert was shown or activated")
            try requireAlert(!prompt.showsSuppressionButton && !prompt.showsHelp, "Permission prompt exposed an unrelated option")
            let views = visibleSubviews(window.contentView!)
            let buttons = views.compactMap { $0 as? NSButton }
            let expectedButtons = hasCancel ? [primary, "取消"] : [primary]
            try requireAlert(prompt.buttons.map(\.title) == expectedButtons, "Incorrect alert action order")
            try requireAlert(buttons.map(\.title).sorted() == expectedButtons.sorted(), "Unlaid-out empty/placeholder button remains: \(buttons.map(\.title))")
            for button in buttons {
                try requireAlert(button.bounds.width > 40 && button.bounds.height >= 20, "Unlaid-out alert action")
                buttonChecks += 1
            }
            let fields = views.compactMap { $0 as? NSTextField }
            for text in [title, message] {
                guard let field = fields.first(where: { $0.stringValue == text }) else {
                    throw AlertFailure(description: "Alert does not contain the full configured Chinese text")
                }
                let natural = field.attributedStringValue.boundingRect(
                    with: CGSize(width: field.bounds.width, height: 10_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height
                try requireAlert(field.bounds.height >= natural - 2,
                    "Chinese text is clipped: laid-out height \(field.bounds.height), required \(natural)")
                textChecks += 1
            }
            print("ALERT \(title): hidden=true, buttons=\(expectedButtons), height=\(window.frame.height)")
        }
        try feedbackChecks()
        try requireAlert(Set(app.windows.filter(\.isVisible).map(ObjectIdentifier.init)) == beforeVisible,
                         "Alert checks displayed a window")
        try requireAlert(!app.isActive && app.activationPolicy() == .prohibited, "Alert fixture became active")
        if baselineBroken { print("BASELINE_ALERT_LAYOUT_REPRODUCED: no-layout NSAlert contains placeholder/empty controls; production layout removes them.") }
        else { print("BASELINE_ALERT_LAYOUT_INCONCLUSIVE: this OS did not expose placeholder controls before explicit layout.") }
        print("PASS production clipboard permission alert: \(cases.count) hidden native alerts, \(textChecks) complete Chinese text bounds, \(buttonChecks) correctly titled action buttons; no visible windows, activation, permissions, clipboard, or user input.")
    }

    @MainActor private static func feedbackChecks() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let panel = ClipboardFeedbackPanel.make(message: "输入位置已变化，自动粘贴已取消。 内容已复制，可按 ⌘V 手动粘贴。")
            defer { panel.close() }
            panel.appearance = NSAppearance(named: appearance)
            guard let clip = panel.contentView, let layer = clip.layer else {
                throw AlertFailure(description: "Feedback has no clipping container")
            }
            try requireAlert(!panel.isOpaque && panel.backgroundColor == .clear && panel.ignoresMouseEvents,
                             "Feedback must stay transparent and passive")
            try requireAlert(clip.subviews.first is NSVisualEffectView && layer.masksToBounds && layer.cornerRadius == 12,
                             "The complete material subtree must be clipped")
            // A behind-window backdrop cannot be rasterized while hidden. Add an opaque
            // backing inside the production effect to exercise the same subtree boundary.
            let backing = CALayer()
            backing.frame = clip.bounds
            backing.backgroundColor = NSColor.white.cgColor
            clip.subviews[0].wantsLayer = true
            clip.subviews[0].layer!.addSublayer(backing)
            let width = Int(clip.bounds.width), height = Int(clip.bounds.height)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
            layer.render(in: context)
            for (x, y) in [(0, 0), (width-1, 0), (0, height-1), (width-1, height-1)] {
                try requireAlert(bitmap.colorAt(x: x, y: y)!.alphaComponent < 0.01,
                                 "Feedback backdrop leaked beyond a rounded corner")
            }
            try requireAlert(bitmap.colorAt(x: width/2, y: height/2)!.alphaComponent > 0.99,
                             "Feedback raster test did not render its opaque backing")
            layer.masksToBounds = false
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            layer.render(in: context)
            try requireAlert(bitmap.colorAt(x: 0, y: 0)!.alphaComponent > 0.99,
                             "Unclipped negative control must reproduce the material corner leak")
            layer.masksToBounds = true
            try requireAlert(!panel.isVisible && !panel.isKeyWindow, "Feedback test showed a window")
        }
        print("PASS feedback rounded backdrop: four transparent corners in light/dark appearances, opaque center, hidden nonactivating panel")
    }
}
