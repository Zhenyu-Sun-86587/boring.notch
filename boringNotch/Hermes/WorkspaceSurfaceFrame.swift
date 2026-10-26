import Foundation
import SwiftUI

/// All tabs use a single presentation rectangle inside a stable window viewport.
/// Its content proposal, clipping path, opaque background and shadow advance together.
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
    var topCornerRadius: CGFloat = 6
    var bottomCornerRadius: CGFloat = 14
    var shadowOpacity: CGFloat = 0
    @ViewBuilder var windowBridge: (CGSize) -> WindowBridge

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { .init(.init(presentationSize.width, presentationSize.height),
                    .init(.init(topCornerRadius, bottomCornerRadius), shadowOpacity)) }
        set {
            presentationSize = CGSize(width: newValue.first.first, height: newValue.first.second)
            topCornerRadius = newValue.second.first.first
            bottomCornerRadius = newValue.second.first.second
            shadowOpacity = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        let geometry = WorkspaceSurfaceGeometry(
            visibleSize: CGSize(width: max(1, presentationSize.width), height: max(1, presentationSize.height)),
            contentSize: contentSize, shadowPadding: shadowPadding, minimumCanvasSize: windowEnvelopeSize)
        Group {
            if enabled {
                content
                    .frame(width: geometry.visibleSize.width, height: geometry.visibleSize.height, alignment: .top)
                    .clipShape(NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius))
                    .background {
                        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
                            .fill(.black)
                            .shadow(color: .black.opacity(Double(max(0, min(1, shadowOpacity)))), radius: 6)
                    }
                    // Resolve the shell's changing geometry once before forwarding it to
                    // the background, clip and replaced page. A compositingGroup groups
                    // rendering effects without establishing this geometry boundary.
                    .geometryGroup()
            } else {
                content
            }
        }
        // The representable keeps its identity. Production supplies the same prepared viewport
        // for every tab and closed state; no timed canvas release or second window animation.
        .background { windowBridge(enabled ? geometry.canvasSize : nativeWindowSize) }
    }
}

struct WorkspaceClosedSizePreference: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct WorkspaceSurfaceAnimationKey: Equatable {
    let size: CGSize
    let open: Bool
    let shadow: Bool
}

struct WorkspaceSurfaceMeasurement: Equatable {
    enum Kind { case closed, compact, inactive }
    let kind: Kind
    let size: CGSize
}

struct WorkspaceSurfaceMeasurementPreference: PreferenceKey {
    static var defaultValue: WorkspaceSurfaceMeasurement { .init(kind: .inactive, size: .zero) }
    static func reduce(value: inout WorkspaceSurfaceMeasurement, nextValue: () -> WorkspaceSurfaceMeasurement) { value = nextValue() }
}
