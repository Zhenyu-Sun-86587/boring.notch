import AppKit
import Security
import SwiftUI
import IslandCore

extension Notification.Name {
    static let islandConfigurationChanged = Notification.Name("islandConfigurationChanged")
    static let islandLocked = Notification.Name("islandLocked")
}

enum IslandSettings {
    static let surfaceDefault = "/Users/sunzhenyu/Desktop/sync/HermesSurface"
    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: "island." + key) ?? "" }
    static func hermes() throws -> HermesConfiguration {
        HermesConfiguration(endpoint: try ServiceURL.parse(string("hermesURL")), model: string("model"), apiKey: try IslandKeychain.read("hermesKey"))
    }
    static func todo() throws -> TodoConfiguration {
        let excluded = Set(string("excludedProjects").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        return TodoConfiguration(baseURL: try ServiceURL.parse(string("todoURL")), token: try IslandKeychain.read("todoToken"),
                                 accessClientID: string("accessID"), accessClientSecret: try IslandKeychain.read("accessSecret"),
                                 excludedProjectIDs: excluded.union([3]))
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
    @State private var todoURL = IslandSettings.string("todoURL")
    @State private var excludedProjects = IslandSettings.string("excludedProjects").isEmpty ? "3" : IslandSettings.string("excludedProjects")
    @State private var accessID = IslandSettings.string("accessID")
    @State private var hermesKey = ""
    @State private var todoToken = ""
    @State private var accessSecret = ""
    @State private var message: String?
    @State private var secretsLoaded = false
    @ObservedObject private var surface = SurfaceAccess.shared

    var body: some View {
        Form {
            Section("Hermes") {
                TextField("Chat completions URL", text: $hermesURL, prompt: Text("http://host:port/v1/chat/completions"))
                TextField("Model", text: $model)
                SecureField("API Key", text: $hermesKey)
                Text("填写完整流式接口地址。配置留空时不发起网络连接。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Vikunja REST") {
                TextField("Instance URL", text: $todoURL, prompt: Text("https://todo.example.com"))
                SecureField("API Token", text: $todoToken)
                TextField("Excluded project IDs", text: $excludedProjects)
                Text("使用实例根地址，项目 ID 以逗号分隔。Project 3 始终排除。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Cloudflare Access Client ID (optional)", text: $accessID)
                SecureField("Cloudflare Access Client Secret", text: $accessSecret)
            }
            Section("HermesSurface") {
                Text(surface.directoryPath).textSelection(.enabled).font(.caption)
                Button("Choose notes folder…") { surface.chooseDirectory() }
                Text("授权目录后，@today / @inbox 读取 Today.md / Inbox.md；存入待办仅追加 Today.md。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Save configuration") { save() }.disabled(!secretsLoaded)
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .navigationTitle("Hermes & Todo")
        .onAppear {
            do {
                hermesKey = try IslandKeychain.read("hermesKey")
                todoToken = try IslandKeychain.read("todoToken")
                accessSecret = try IslandKeychain.read("accessSecret")
                secretsLoaded = true
            } catch { message = error.localizedDescription }
        }
    }
    private func save() {
        do {
            if !hermesURL.isEmpty { _ = try ServiceURL.parse(hermesURL) }
            if !todoURL.isEmpty { _ = try ServiceURL.parse(todoURL) }
            guard excludedProjects.split(separator: ",").allSatisfy({ Int($0.trimmingCharacters(in: .whitespaces)) != nil }) else {
                throw IslandError.configuration("排除项目必须填写逗号分隔的数字 ID。")
            }
            try IslandKeychain.write(hermesKey, account: "hermesKey")
            try IslandKeychain.write(todoToken, account: "todoToken")
            try IslandKeychain.write(accessSecret, account: "accessSecret")
            for (key, value) in ["hermesURL": hermesURL, "model": model, "todoURL": todoURL,
                                 "excludedProjects": excludedProjects, "accessID": accessID] {
                UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "island." + key)
            }
            NotificationCenter.default.post(name: .islandConfigurationChanged, object: nil)
            message = "配置已保存；密钥存放在钥匙串中。"
        } catch { message = error.localizedDescription }
    }
}
