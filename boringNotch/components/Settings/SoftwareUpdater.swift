//
//  SoftwareUpdater.swift
//  boringNotch
//
//  Hermes packages are distributed independently of upstream Sparkle feeds.
//

import Sparkle
import SwiftUI

struct CheckForUpdatesView: View {
    init(updater _: SPUUpdater) {}

    var body: some View {
        Text("通过安装包更新")
            .foregroundStyle(.secondary)
    }
}

struct UpdaterSettingsView: View {
    init(updater _: SPUUpdater) {}

    var body: some View {
        Section("软件更新") {
            LabeledContent("更新方式", value: "安装包")
        }
    }
}
