import AppKit
import Security
import SwiftUI
import IslandCore

extension Notification.Name {
    static let islandConfigurationChanged = Notification.Name("islandConfigurationChanged")
    static let islandLocked = Notification.Name("islandLocked")
}

enum IslandSettings {
    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: "island." + key) ?? "" }
    static func hermes() throws -> HermesConfiguration {
        let endpoint = try ServiceURL.parse(string("hermesURL"))
        let model = string("model").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw IslandError.configuration("请先在设置中填写 Hermes 模型名称。") }
        return HermesConfiguration(endpoint: endpoint, model: model, apiKey: try IslandKeychain.read("hermesKey"))
    }
}

enum IslandKeychain {
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "boringNotch") + ".island",
         kSecAttrAccount as String: account]
    }
    static func read(_ account: String) throws -> String {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw IslandError.configuration("无法读取钥匙串：\(status)") }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    static func write(_ value: String, account: String) throws {
        let query = query(account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw IslandError.configuration("无法删除钥匙串条目：\(status)") }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw IslandError.configuration("无法保存钥匙串：\(status)") }
    }
}

struct IslandSettingsView: View {
    @State private var hermesURL = IslandSettings.string("hermesURL")
    @State private var model = IslandSettings.string("model")
    @State private var hermesKey = ""
    @State private var message: String?
    @State private var secretsLoaded = false
    @ObservedObject private var surface = SurfaceAccess.shared

    var body: some View {
        Form {
            Section("连接") {
                TextField("接口地址", text: $hermesURL, prompt: Text("https://host/v1/chat/completions"))
                TextField("模型", text: $model)
                SecureField("API 密钥", text: $hermesKey)
                Button("保存配置") { save() }.disabled(!secretsLoaded)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Section("本地便签") {
                LabeledContent("Markdown 文件") {
                    HStack(spacing: 8) {
                        if surface.hasFile {
                            Text(surface.fileName).lineLimit(1).truncationMode(.middle).help(surface.filePath)
                            Button { surface.clearSelection() } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).help("移除文件")
                        }
                        Button(surface.hasFile ? "更换…" : "选择文件…") { surface.chooseFile() }
                    }
                }
                if let error = surface.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("展开尺寸") {
                HermesWidthControls()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Hermes")
        .onAppear {
            do {
                hermesKey = try IslandKeychain.read("hermesKey")
                secretsLoaded = true
            } catch { message = error.localizedDescription }
        }
    }
    private func save() {
        do {
            if !hermesURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { _ = try ServiceURL.parse(hermesURL) }
            try IslandKeychain.write(hermesKey, account: "hermesKey")
            for (key, value) in ["hermesURL": hermesURL, "model": model] {
                UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "island." + key)
            }
            NotificationCenter.default.post(name: .islandConfigurationChanged, object: nil)
            message = "已保存"
        } catch { message = error.localizedDescription }
    }
}

struct HermesWidthControls: View {
    @AppStorage("island.hermesWidth") private var width = 640.0
    @AppStorage("island.hermesWideWidth") private var wideWidth = 920.0

    var body: some View {
        VStack(spacing: 12) {
            widthRow("标准宽度", value: $width, range: 480...1_600)
            widthRow("展宽宽度", value: $wideWidth, range: min(1_600, max(640, width))...1_920)
        }
        .onChange(of: width) { _, value in if wideWidth < value { wideWidth = value } }
    }

    private func widthRow(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range, step: 20)
            Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }
}
