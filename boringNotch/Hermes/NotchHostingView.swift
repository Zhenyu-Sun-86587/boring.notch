import AppKit
import SwiftUI

/// Keep the hosting view out of NSWindow's content-view slot. On macOS 27,
/// SwiftUI can still animate the containing window's size during a tab change
/// even when sizingOptions is empty. The plain container owns the window bounds;
/// its hosting child only follows those bounds.
@MainActor
final class NotchHostingContainer<Content: View>: NSView {
    let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = bounds
        addSubview(hostingView)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

@MainActor
func makeNotchHostingView<Content: View>(rootView: Content) -> NotchHostingContainer<Content> {
    NotchHostingContainer(rootView: rootView)
}
