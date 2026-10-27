import SwiftUI

struct ClipboardSettingsView: View {
    @ObservedObject private var store = ClipboardStore.shared
    @State private var confirmsClear = false
    var body: some View {
        Form {
            Section {
                Toggle("剪贴板历史", isOn: Binding(get: { store.enabled }, set: { store.setEnabledByUser($0) }))
                if store.enabled && store.needsReadAccess {
                    Button("允许读取剪贴板") { store.requestPermissions() }.disabled(store.requestingPermissions)
                }
                if store.enabled {
                    Button("检查自动粘贴权限") { store.requestPermissions() }.disabled(store.requestingPermissions)
                }
                if store.enabled && store.readDenied {
                    Button("打开剪贴板权限设置") { store.requestPermissions() }.disabled(store.requestingPermissions)
                }
            }
            Section("保留记录") {
                Picker("保留时间", selection: $store.retentionDays) {
                    Text("1 天").tag(1)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                }
                Picker("记录上限", selection: $store.maximumCount) {
                    Text("100 条").tag(100)
                    Text("200 条").tag(200)
                    Text("500 条").tag(500)
                    Text("1000 条").tag(1_000)
                }
                Picker("存储上限", selection: $store.diskMegabytes) {
                    Text("64 MB").tag(64)
                    Text("256 MB").tag(256)
                    Text("512 MB").tag(512)
                    Text("1 GB").tag(1_024)
                }
            }
            Section("排除应用") {
                TextField("应用标识符", text: $store.excludedApps, prompt: Text("com.example.app"), axis: .vertical)
                    .lineLimit(1...4)
            }
            Section {
                Button("清空历史", role: .destructive) { confirmsClear = true }
            }
            InteractionDebugSettings()
            if let message = store.message { Text(message).foregroundStyle(.secondary).font(.caption) }
        }
        .formStyle(.grouped)
        .navigationTitle("剪贴板")
        .onAppear { store.start() }
        .confirmationDialog("清空全部剪贴板历史？", isPresented: $confirmsClear) {
            Button("清空", role: .destructive) { store.clear() }
            Button("取消", role: .cancel) {}
        }
    }
}
