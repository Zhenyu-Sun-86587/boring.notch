import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class InteractionDebugStore: ObservableObject {
    static let shared = InteractionDebugStore()
    @Published private(set) var enabled: Bool
    @Published var message: String?
    private var observers: [NSObjectProtocol] = []
    private init() {
        enabled = UserDefaults.standard.bool(forKey: InteractionDiagnostics.preferenceKey)
        configure()
    }
    func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: InteractionDiagnostics.preferenceKey)
        enabled = value
        message = nil
        configure()
    }
    private func configure() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        InteractionDiagnostics.setEnabled(enabled)
        guard enabled else { return }
        InteractionDiagnostics.record("capture", "started", ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "", "os": ProcessInfo.processInfo.operatingSystemVersionString])
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    InteractionDiagnostics.record("app", note.name.rawValue,
                        InteractionDiagnostics.windowFields(note.object as? NSWindow))
                }
            })
        }
    }
    func clear() { InteractionDiagnostics.clear(); configure(); message = "日志已清空。" }
    func reveal() {
        try? FileManager.default.createDirectory(at: InteractionDiagnostics.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(InteractionDiagnostics.directory)
    }
    func export() {
        let data = InteractionDiagnostics.exportData()
        guard !data.isEmpty else { message = "暂无日志，请先打开调试开关并复现问题。"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Boring-Notch-交互调试.txt"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self?.message = "日志已导出。"
            } catch { self?.message = "日志导出失败，请重试。" }
        }
    }
}

struct InteractionDebugSettings: View {
    @ObservedObject private var debug = InteractionDebugStore.shared
    var body: some View {
        Section("交互调试") {
            Toggle("记录详细调试日志", isOn: Binding(get: { debug.enabled }, set: { debug.setEnabled($0) }))
            Text("记录焦点、点击和粘贴流程，不记录输入正文、剪贴板内容或密钥。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("导出日志…") { debug.export() }
                Button("显示日志文件夹") { debug.reveal() }
                Button("清空日志") { debug.clear() }
            }
            if let message = debug.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
