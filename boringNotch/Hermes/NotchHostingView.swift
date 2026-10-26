import AppKit
import SwiftUI

/// The notch's window manager owns its frame. A root NSHostingView must not
/// derive competing window min/max/preferred sizes from the animated content.
@MainActor
func makeNotchHostingView<Content: View>(rootView: Content) -> NSHostingView<Content> {
    let view = NSHostingView(rootView: rootView)
    view.sizingOptions = []
    view.safeAreaRegions = []
    view.autoresizingMask = [.width, .height]
    return view
}
