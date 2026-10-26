import AppKit
import SwiftUI

/// Marks only the visible shell or an intentional native drag/chin target as interactive.
@MainActor protocol IslandInteractionRegionProviding: AnyObject {}

struct IslandInteractionRegionMarker: NSViewRepresentable {
    final class Marker: NSView, IslandInteractionRegionProviding {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Marker { Marker(frame: .zero) }
    func updateNSView(_ view: Marker, context: Context) {}
}

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        var regions: [NSView] = []
        func collect(_ view: NSView) {
            guard !view.isHidden else { return }
            if view is IslandInteractionRegionProviding { regions.append(view) }
            view.subviews.forEach(collect)
        }
        collect(hostingView)
        // Generic harnesses/early unattached hosts have no shell yet. Once installed,
        // transparent viewport padding must not become a large mouse/drop target.
        if !regions.isEmpty {
            let local = convert(point, from: superview)
            guard regions.contains(where: { $0.bounds.contains($0.convert(local, from: self)) }) else { return nil }
        }
        return super.hitTest(point)
    }
}

@MainActor
func makeNotchHostingView<Content: View>(rootView: Content) -> NotchHostingContainer<Content> {
    NotchHostingContainer(rootView: rootView)
}
