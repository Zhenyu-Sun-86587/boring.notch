import Foundation

/// Submitted messages are visible immediately; only completed exchanges become model context.
/// Request IDs fence off delayed callbacks, while a retry keeps the original visible turn ID.
public struct HermesTranscript: Sendable {
    public static let maximumTurns = 5
    public enum Status: Sendable, Equatable {
        case thinking, responding, completed, stopped
        case failed(String)
    }
    public struct Turn: Identifiable, Sendable {
        public let id: UUID
        public let prompt: String
        public fileprivate(set) var user: String
        public fileprivate(set) var assistant: String
        public fileprivate(set) var status: Status

        public var canRetry: Bool {
            switch status {
            case .failed, .stopped: return true
            default: return false
            }
        }
    }
    public private(set) var turns: [Turn] = []
    private var active: (request: UUID, turn: UUID)?
    public init() {}

    public var messages: [ChatMessage] {
        turns.filter { $0.status == .completed }.flatMap {
            [ChatMessage(role: "user", text: $0.user), ChatMessage(role: "assistant", text: $0.assistant)]
        }
    }

    /// Run file/configuration preflight before accepting. A rejected acceptance changes nothing.
    @discardableResult
    public mutating func accept(request: UUID, prompt: String, user: String, retrying turnID: UUID? = nil) throws -> UUID? {
        guard active == nil else { return nil }
        guard user.utf8.count <= 131_072 else { throw IslandError.limit("问题与便签合计超过 128 KB，请减少内容。") }
        let id: UUID
        if let turnID {
            guard let index = turns.indices.last, turns[index].id == turnID, turns[index].canRetry else { return nil }
            id = turnID
            turns[index].user = user
            turns[index].assistant = ""
            turns[index].status = .thinking
        } else {
            id = UUID()
            turns.append(Turn(id: id, prompt: prompt, user: user, assistant: "", status: .thinking))
        }
        active = (request, id)
        trim()
        return id
    }

    @discardableResult
    public mutating func updateAnswer(_ answer: String, request: UUID) -> Bool {
        guard active?.request == request, let index = turns.firstIndex(where: { $0.id == active?.turn }) else { return false }
        turns[index].assistant = answer
        if !answer.isEmpty { turns[index].status = .responding }
        trim()
        return true
    }

    @discardableResult
    public mutating func finish(_ status: Status, request: UUID) -> Bool {
        guard status != .thinking, status != .responding, active?.request == request,
              let index = turns.firstIndex(where: { $0.id == active?.turn }) else { return false }
        turns[index].status = status
        active = nil
        trim()
        return true
    }

    public mutating func clear() { turns.removeAll(); active = nil }

    private mutating func trim() {
        // The accepted request and bounded response fit within one 256 KB turn. Evict whole
        // older exchanges, including failed attempts, without hiding the message being answered.
        while turns.count > 1 && (turns.count > Self.maximumTurns || turns.reduce(0, {
            $0 + $1.user.utf8.count + $1.assistant.utf8.count
        }) > 262_144) { turns.removeFirst() }
    }
}
