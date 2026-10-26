import SwiftUI

/// Change the page immediately while the surrounding notch keeps animating its size.
/// A transition on the outer opened body does not cover conditional views inside it:
/// without this boundary SwiftUI retains the outgoing page for an implicit crossfade.
struct IslandPageContainer<Selection: Hashable, Content: View>: View {
    let selection: Selection
    @ViewBuilder var content: (Selection) -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            content(selection)
                .id(selection)
                .transition(.identity)
        }
        .transaction(value: selection) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}
