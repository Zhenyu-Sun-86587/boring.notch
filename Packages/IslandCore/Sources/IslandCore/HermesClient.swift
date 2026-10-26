import Foundation

/// Incremental UTF-8 SSE decoder. Limits bound both unterminated lines and multi-line events.
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var lines: [String] = []
    private var eventBytes = 0
    public init() {}

    public mutating func feed(_ data: Data) throws -> [String] {
        buffer.append(data)
        var events: [String] = []
        while let end = buffer.firstIndex(of: 10) {
            var line = buffer.prefix(upTo: end)
            if line.last == 13 { line = line.dropLast() }
            guard line.count <= 262_144, let text = String(data: line, encoding: .utf8) else {
                throw IslandError.invalidResponse
            }
            buffer.removeSubrange(...end)
            if text.isEmpty {
                if !lines.isEmpty { events.append(lines.joined(separator: "\n")) }
                lines.removeAll(keepingCapacity: true); eventBytes = 0
            } else if text.hasPrefix("data:") {
                let value = String(text.dropFirst(5).drop(while: { $0 == " " }).prefix(262_145))
                eventBytes += value.utf8.count
                guard eventBytes <= 262_144 else { throw IslandError.limit("流式事件过大。") }
                lines.append(value)
            }
        }
        guard buffer.count <= 262_144 else { throw IslandError.limit("流式事件过大。") }
        return events
    }

    public mutating func finish() throws -> [String] {
        var result = try feed(Data([10, 10]))
        if !lines.isEmpty { result.append(lines.joined(separator: "\n")); lines.removeAll() }
        return result
    }
}

public struct ChatPart: Encodable, Sendable {
    public let text: String?
    public let imageURL: String?
    public static func text(_ text: String) -> Self { .init(text: text, imageURL: nil) }
    public static func image(_ url: String) -> Self { .init(text: nil, imageURL: url) }
    enum CodingKeys: String, CodingKey { case type, text; case imageURL = "image_url" }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(imageURL == nil ? "text" : "image_url", forKey: .type)
        if let text { try values.encode(text, forKey: .text) }
        if let imageURL { try values.encode(["url": imageURL], forKey: .imageURL) }
    }
}

public struct ChatMessage: Encodable, Sendable {
    public let role: String
    public let parts: [ChatPart]
    public init(role: String, text: String) { self.role = role; parts = [.text(text)] }
    public init(role: String, parts: [ChatPart]) { self.role = role; self.parts = parts }
    enum CodingKeys: String, CodingKey { case role, content }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(role, forKey: .role)
        if parts.allSatisfy({ $0.imageURL == nil }) {
            try values.encode(parts.compactMap(\.text).joined(separator: "\n"), forKey: .content)
        } else { try values.encode(parts, forKey: .content) }
    }
}

public struct HermesHeader: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

/// Validate once before URLRequest canonicalizes names or discards duplicate fields.
/// Error descriptions contain no credential values.
public enum HermesRequestHeaders {
    private static let token = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
    private static let reserved: Set<String> = [
        "host", "connection", "keep-alive", "http2-settings", "proxy-connection", "proxy-authenticate", "proxy-authorization",
        "content-length", "transfer-encoding", "content-encoding", "accept-encoding", "te", "trailer",
        "upgrade", "expect", "content-type", "accept", "cf-access-client-id", "cf-access-client-secret"
    ]

    public static func validated(apiKey: String, accessClientID: String, accessClientSecret: String,
                                 extra: [HermesHeader]) throws -> [String: String] {
        func validateValue(_ value: String) throws {
            guard value.utf8.count <= 8_192 else { throw IslandError.configuration("请求头的值超过 8 KB。") }
            guard !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
            }) else { throw IslandError.configuration("请求头的值不能包含换行或控制字符。") }
        }
        try validateValue(apiKey)
        try validateValue(accessClientID)
        try validateValue(accessClientSecret)
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        let accessID = accessClientID.trimmingCharacters(in: .whitespaces)
        let secret = accessClientSecret.trimmingCharacters(in: .whitespaces)
        guard accessID.isEmpty == secret.isEmpty else {
            throw IslandError.configuration("Cloudflare Access 客户端 ID 与密钥必须同时填写。")
        }
        guard extra.count <= 32 else { throw IslandError.configuration("最多配置 32 个自定义请求头。") }
        var result = ["Content-Type": "application/json", "Accept": "text/event-stream"]
        if !key.isEmpty { result["Authorization"] = "Bearer " + key }
        if !accessID.isEmpty {
            result["CF-Access-Client-Id"] = accessID
            result["CF-Access-Client-Secret"] = secret
        }
        var names = Set<String>()
        for header in extra {
            guard !header.name.isEmpty, header.name.utf8.count <= 128,
                  header.name.utf8.allSatisfy({ token.contains($0) }) else {
                throw IslandError.configuration("请求头名称只能包含 ASCII 字母、数字及有效符号，不能包含空格。")
            }
            try validateValue(header.value)
            let lower = header.name.lowercased()
            guard names.insert(lower).inserted else {
                throw IslandError.configuration("请求头名称重复，名称不区分大小写。")
            }
            guard !reserved.contains(lower) else {
                throw IslandError.configuration("该请求头由应用或传输层管理；Cloudflare Access 请使用专用字段。")
            }
            guard lower != "authorization" || key.isEmpty else {
                throw IslandError.configuration("Authorization 请求头与 API 密钥不能同时配置。")
            }
            result[header.name] = header.value
        }
        guard result.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 32_768 else {
            throw IslandError.configuration("请求头总大小超过 32 KB。")
        }
        return result
    }
}

public struct HermesConfiguration: Sendable {
    public let endpoint: URL
    public let model: String
    public let apiKey: String
    public let accessClientID: String
    public let accessClientSecret: String
    public let extraHeaders: [HermesHeader]
    public init(endpoint: URL, model: String, apiKey: String = "", accessClientID: String = "",
                accessClientSecret: String = "", extraHeaders: [HermesHeader] = []) {
        self.endpoint = endpoint; self.model = model; self.apiKey = apiKey
        self.accessClientID = accessClientID; self.accessClientSecret = accessClientSecret
        self.extraHeaders = extraHeaders
    }
}

public protocol HermesStreaming: Sendable {
    func stream(configuration: HermesConfiguration, messages: [ChatMessage],
                onDelta: @Sendable (String) async throws -> Void) async throws
}

public struct HermesClient: HermesStreaming {
    public init() {}
    public static func makeRequest(configuration: HermesConfiguration, messages: [ChatMessage]) throws -> URLRequest {
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IslandError.configuration("请先在设置中填写 Hermes 模型名称。")
        }
        struct Body: Encodable { let model: String; let messages: [ChatMessage]; let stream = true }
        let headers = try HermesRequestHeaders.validated(apiKey: configuration.apiKey,
            accessClientID: configuration.accessClientID, accessClientSecret: configuration.accessClientSecret,
            extra: configuration.extraHeaders)
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONEncoder().encode(Body(model: configuration.model, messages: messages))
        guard (request.httpBody?.count ?? 0) <= 12 * 1_024 * 1_024 else { throw IslandError.limit("请求超过 12 MB，请减少附件。") }
        return request
    }

    public func stream(configuration: HermesConfiguration, messages: [ChatMessage],
                       onDelta: @Sendable (String) async throws -> Void) async throws {
        let request = try Self.makeRequest(configuration: configuration, messages: messages)
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 60
        settings.timeoutIntervalForResource = 600
        let session = URLSession(configuration: settings, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw IslandError.invalidResponse }
        _ = try HTTPResult(data: Data(), status: http.statusCode, headers: ["content-type": http.mimeType ?? ""]).validated()
        guard http.mimeType == "text/event-stream" else { throw IslandError.invalidResponse }
        var parser = SSEParser()
        var chunk = Data()
        var receivedText = false
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            if byte == 10 || chunk.count >= 4_096 {
                for event in try parser.feed(chunk) {
                    if event == "[DONE]" { return }
                    if let text = try Self.delta(event) { receivedText = true; try await onDelta(text) }
                }
                chunk.removeAll(keepingCapacity: true)
            }
        }
        for event in try parser.feed(chunk) + parser.finish() {
            if event == "[DONE]" { return }
            if let text = try Self.delta(event) { receivedText = true; try await onDelta(text) }
        }
        // A broken connection must not silently look like a completed answer.
        throw IslandError.configuration(receivedText ? "连接提前结束，已保留收到的内容。" : "服务未返回回答。")
    }

    public static func delta(_ event: String) throws -> String? {
        struct Packet: Decodable {
            struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta }
            let choices: [Choice]?
            let error: APIError?
            struct APIError: Decodable { let message: String }
        }
        let packet = try JSONDecoder().decode(Packet.self, from: Data(event.utf8))
        if let error = packet.error { throw IslandError.configuration(error.message) }
        return packet.choices?.first?.delta.content
    }
}

public struct Conversation: Sendable {
    public struct Turn: Sendable { public let user: String; public let assistant: String; public let prompt: String }
    public private(set) var turns: [Turn] = []
    public init() {}
    public mutating func append(user: String, assistant: String, displayPrompt: String? = nil) {
        turns.append(Turn(user: user, assistant: assistant, prompt: displayPrompt ?? user))
        while turns.count > 8 || turns.reduce(0, { $0 + $1.user.utf8.count + $1.assistant.utf8.count }) > 262_144 {
            turns.removeFirst()
        }
    }
    public var messages: [ChatMessage] {
        turns.flatMap { [ChatMessage(role: "user", text: $0.user), ChatMessage(role: "assistant", text: $0.assistant)] }
    }
    public mutating func clear() { turns.removeAll() }
    public static func needsWideLayout(_ text: String) -> Bool {
        text.contains("```") || text.range(of: #"(?m)^\s*\|?\s*:?-{3,}:?\s*\|"#, options: .regularExpression) != nil
    }
}
