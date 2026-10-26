//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import SwiftUI
import Defaults

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Hermes", icon: "sparkles", view: .hermes),
    TabModel(label: "剪贴板", icon: "clipboard", view: .clipboard)
]

struct TabSelectionView: View {
    @Default(.boringShelf) private var shelfEnabled
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation
    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs.filter { $0.view != .shelf || shelfEnabled }) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        HermesStore.shared.capturesNotchDrops = tab.view == .hermes
                        coordinator.selectTab(tab.view)
                    }
                    .frame(height: 26)
                    .accessibilityIdentifier("island-tab-\(tab.view.rawValue)")
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(Color(nsColor: .secondarySystemFill))
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        }
                    }
            }
        }
        .clipShape(Capsule())
        // Animate only the highlight. Animating selectTab itself also retains outgoing pages.
        .animation(.smooth, value: coordinator.currentView)
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel(camera: CameraModel()))
}
