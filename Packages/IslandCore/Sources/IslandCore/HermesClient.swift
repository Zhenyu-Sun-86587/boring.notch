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

public struct HermesConfiguration: Sendable {
    public let endpoint: URL
    public let model: String
    public let apiKey: String
    public init(endpoint: URL, model: String, apiKey: String = "") {
        self.endpoint = endpoint; self.model = model; self.apiKey = apiKey
    }
}

public protocol HermesStreaming: Sendable {
    func stream(configuration: HermesConfiguration, messages: [ChatMessage],
                onDelta: @Sendable (String) async throws -> Void) async throws
}

public struct HermesClient: HermesStreaming {
    public init() {}
    public func stream(configuration: HermesConfiguration, messages: [ChatMessage],
                       onDelta: @Sendable (String) async throws -> Void) async throws {
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IslandError.configuration("请先在设置中填写 Hermes 模型名称。")
        }
        struct Body: Encodable { let model: String; let messages: [ChatMessage]; let stream = true }
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !configuration.apiKey.isEmpty { request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(Body(model: configuration.model, messages: messages))
        guard (request.httpBody?.count ?? 0) <= 12 * 1_024 * 1_024 else { throw IslandError.limit("请求超过 12 MB，请减少附件。") }
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
