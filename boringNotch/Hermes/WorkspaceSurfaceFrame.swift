import Foundation
import SwiftUI

/// Content has its final layout while the shell reveals it from top-center. A prepared, stable
/// window viewport contains the entire spring, avoiding a second AppKit resize animation.
struct WorkspaceSurfaceGeometry: Equatable {
    let visibleSize: CGSize
    let contentSize: CGSize
    let shadowPadding: CGFloat
    let minimumCanvasSize: CGSize

    static func preparedEnvelope(current: CGSize, target: CGSize, native: CGSize,
                                 shadowPadding: CGFloat) -> CGSize {
        // StandardAnimations.open has damping 0.8; 32 points also contains its maximum
        // overshoot across Hermes' supported widths. Retain larger previous bounds when reversing.
        let springRoom: CGFloat = 32
        return CGSize(width: max(native.width, current.width, target.width + springRoom),
                      height: max(native.height, current.height, target.height + shadowPadding + springRoom))
    }

    var canvasSize: CGSize {
        CGSize(width: max(minimumCanvasSize.width, visibleSize.width),
               height: max(minimumCanvasSize.height, visibleSize.height + shadowPadding))
    }
    var contentOrigin: CGPoint { CGPoint(x: (visibleSize.width - contentSize.width) / 2, y: 0) }
}

struct WorkspaceSurfaceFrame<WindowBridge: View>: AnimatableModifier {
    var presentationSize: CGSize
    let contentSize: CGSize
    let enabled: Bool
    let nativeWindowSize: CGSize
    let windowEnvelopeSize: CGSize
    let shadowPadding: CGFloat
    @ViewBuilder var windowBridge: (CGSize) -> WindowBridge

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(presentationSize.width, presentationSize.height) }
        set { presentationSize = CGSize(width: newValue.first, height: newValue.second) }
    }

    func body(content: Content) -> some View {
        let geometry = WorkspaceSurfaceGeometry(
            visibleSize: CGSize(width: max(1, presentationSize.width), height: max(1, presentationSize.height)),
            contentSize: contentSize, shadowPadding: shadowPadding, minimumCanvasSize: windowEnvelopeSize)
        Group {
            if enabled {
                content
                    .frame(width: geometry.contentSize.width, height: geometry.contentSize.height, alignment: .top)
                    .frame(width: geometry.visibleSize.width, height: geometry.visibleSize.height, alignment: .top)
                    .clipped()
            } else {
                content
            }
        }
        // This representable remains at the same identity through opening, closing and tab changes.
        // The transparent viewport expands before content needs it and remains stable through the
        // morph. It is released by the caller only after closing/native-tab animation has settled.
        .background { windowBridge(enabled ? geometry.canvasSize : nativeWindowSize) }
    }
}

struct WorkspaceClosedSizePreference: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
