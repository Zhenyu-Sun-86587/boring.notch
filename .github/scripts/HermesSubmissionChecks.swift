// Compile with the production HermesStore. Every dependency below is a fixture: no application
// window, pasteboard, Keychain, user settings/file or network service is accessed.
import AppKit
import IslandCore

private struct SubmissionCheckFailure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SubmissionCheckFailure(description: message) }
}
@MainActor private func eventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        if ContinuousClock.now >= deadline { throw SubmissionCheckFailure(description: "Fixture timed out") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor enum IslandSettings {
    static var fail = false
    static func hermes() throws -> HermesConfiguration {
        if fail { throw IslandError.configuration("测试配置错误") }
        return HermesConfiguration(endpoint: URL(string: "https://fixture.invalid/chat/completions")!, model: "fixture")
    }
}
struct NoteSelection: Sendable { let name = "fixture.md" }
@MainActor final class SurfaceAccess {
    static let shared = SurfaceAccess()
    var fail = false
    var suspended = false
    var waiting: CheckedContinuation<String, any Error>?
    func acquire() {}
    func release() {}
    func snapshot() throws -> NoteSelection { NoteSelection() }
    func context(selection: NoteSelection) async throws -> String {
        if fail { throw IslandError.configuration("测试便签读取失败") }
        if suspended { return try await withCheckedThrowingContinuation { waiting = $0 } }
        return "\n便签上下文"
    }
    func appendTask(_ text: String, selection: NoteSelection) async throws {}
}
struct ShelfStagedFile { let url: URL; let temporary: Bool }
@MainActor enum ShelfDropService {
    static var staged: [ShelfStagedFile] = []
    static func stagingFiles(from providers: [NSItemProvider]) async throws -> [ShelfStagedFile] { staged }
}

private actor SubmissionClient: HermesStreaming {
    enum Event: Sendable {
        case text(String, CheckedContinuation<Void, any Error>)
    }
    private var pending: [Int: AsyncThrowingStream<Event, any Error>.Continuation] = [:]
    private(set) var requests: [[ChatMessage]] = []
    var count: Int { requests.count }

    func stream(configuration: HermesConfiguration, messages: [ChatMessage],
                onDelta: @Sendable (String) async throws -> Void) async throws {
        let index = requests.count
        requests.append(messages)
        let (stream, continuation) = AsyncThrowingStream<Event, any Error>.makeStream()
        pending[index] = continuation
        defer { pending.removeValue(forKey: index) }
        for try await event in stream {
            switch event {
            case .text(let text, let acknowledgement):
                do {
                    try await onDelta(text)
                    acknowledgement.resume()
                } catch {
                    acknowledgement.resume(throwing: error)
                    throw error
                }
            }
        }
    }
    func emit(_ text: String, request: Int? = nil) async throws {
        guard let continuation = pending[request ?? (requests.count - 1)] else { throw CancellationError() }
        try await withCheckedThrowingContinuation { acknowledgement in
            if case .terminated = continuation.yield(.text(text, acknowledgement)) {
                acknowledgement.resume(throwing: CancellationError())
            }
        }
    }
    func finish(_ error: (any Error)? = nil) { pending[requests.count - 1]?.finish(throwing: error) }
}

@main enum HermesSubmissionChecks {
    @MainActor static func main() async throws {
        try await preflightPreservesDraft()
        try await submissionAndRetry()
        try await changedDraftDuringPreflight()
        print("PASS: production HermesStore draft preflight, immediate user turn, thinking, partial failure, retry, cancellation and stale callbacks")
    }

    @MainActor private static func preflightPreservesDraft() async throws {
        let client = SubmissionClient()
        let store = HermesStore(client: client)
        defer { store.clear(); IslandSettings.fail = false; SurfaceAccess.shared.fail = false; ShelfDropService.staged = [] }
        store.input = "配置错误时保留草稿"
        IslandSettings.fail = true
        store.send()
        try require(!store.isGenerating && store.input == "配置错误时保留草稿" && store.turns.isEmpty, "Configuration preflight consumed draft")
        IslandSettings.fail = false
        store.includesNote = true
        SurfaceAccess.shared.fail = true
        store.send()
        try await eventually { !store.isGenerating }
        try require(store.input == "配置错误时保留草稿" && store.turns.isEmpty && !store.isPreparingRequest, "Note preflight consumed draft")
        try require(await client.count == 0, "Preflight failure reached client")
        SurfaceAccess.shared.fail = false
        store.includesNote = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-submission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("invalid.txt")
        try Data([0xff, 0xfe]).write(to: file)
        ShelfDropService.staged = [.init(url: file, temporary: false)]
        store.stage([NSItemProvider()])
        try await eventually { !store.isPreparingDrop }
        store.send()
        try await eventually { !store.isGenerating }
        try require(store.input == "配置错误时保留草稿" && store.turns.isEmpty && store.attachments.count == 1,
                    "Attachment preflight consumed draft or attachment")
        try require(await client.count == 0, "Invalid attachment reached client")
    }

    @MainActor private static func submissionAndRetry() async throws {
        let client = SubmissionClient()
        let store = HermesStore(client: client)
        defer { store.clear() }
        store.input = "第一问\n保留换行"
        store.send()
        store.send()
        try await eventually { await client.count == 1 }
        let turn = store.turns[0].id
        try require(store.input.isEmpty && store.turns.count == 1 && store.turns[0].prompt == "第一问\n保留换行", "Submission was not immediately visible/cleared")
        try require(store.turns[0].status == .thinking && !store.isPreparingRequest, "Missing first-token thinking state")
        store.input = "下一轮草稿"
        try await client.emit("部分回答")
        await client.finish(IslandError.configuration("测试连接中断"))
        try await eventually { !store.isGenerating }
        try require(store.input == "下一轮草稿" && store.turns[0].assistant == "部分回答", "Failure lost new draft or buffered partial output")
        try require(store.turns[0].canRetry && store.canRetry(turn), "Failed turn is not retryable")
        IslandSettings.fail = true
        store.retry(turn)
        IslandSettings.fail = false
        try require(!store.isGenerating && store.turns[0].assistant == "部分回答" && store.input == "下一轮草稿",
                    "Retry preflight lost partial output or the next draft")
        store.retry(turn)
        try await eventually { await client.count == 2 }
        try require(store.turns.count == 1 && store.turns[0].id == turn && store.input == "下一轮草稿", "Retry duplicated turn or overwrote next draft")
        try require(await client.requests[1].count == 1, "Failed turn leaked into retry context")
        try await client.emit("完整回答")
        await client.finish()
        try await eventually { !store.isGenerating }
        try require(store.turns.count == 1 && store.turns[0].status == .completed && store.input == "下一轮草稿", "Completion duplicated turn or overwrote draft")
        store.send()
        try await eventually { await client.count == 3 }
        try require(await client.requests[2].count == 3, "Completed exchange was not included exactly once")
        let obsolete = 2
        store.input = "停止期间的新草稿"
        try await client.emit("停止前片段")
        store.stop()
        try require(store.turns.last?.status == .stopped && store.turns.last?.assistant == "停止前片段", "Stop lost submitted prompt/partial answer")
        try require(store.input == "停止期间的新草稿", "Stop overwrote next draft")
        store.send()
        try await eventually { await client.count == 4 }
        do { try await client.emit("迟到输出", request: obsolete); throw SubmissionCheckFailure(description: "Stale stream was accepted") }
        catch is CancellationError {}
        try require(store.answer.isEmpty && store.turns.last?.status == .thinking, "Old callback modified newer request")
        store.clear()
        try require(store.turns.isEmpty && store.input.isEmpty && !store.isGenerating, "Clear left an active turn")
        store.input = "空回复"
        store.send()
        try await eventually { await client.count == 5 }
        await client.finish()
        try await eventually { !store.isGenerating }
        try require(store.turns[0].canRetry && store.turns[0].prompt == "空回复", "Empty completion silently removed submitted prompt")
    }

    @MainActor private static func changedDraftDuringPreflight() async throws {
        let client = SubmissionClient()
        let store = HermesStore(client: client)
        defer { store.clear(); SurfaceAccess.shared.suspended = false }
        SurfaceAccess.shared.suspended = true
        store.includesNote = true
        store.input = "原问题"
        store.send()
        try await eventually { SurfaceAccess.shared.waiting != nil }
        store.input = "编辑中的新草稿"
        store.input = "原问题" // Equal text is still a newer edit; value equality alone is insufficient.
        SurfaceAccess.shared.waiting?.resume(returning: "\n便签上下文")
        SurfaceAccess.shared.waiting = nil
        try await eventually { await client.count == 1 }
        try require(store.input == "原问题" && store.turns.count == 1, "Asynchronous preflight cleared a newer draft revision")
        try require(await client.requests[0].last?.parts[0].text == "原问题\n便签上下文", "Preflight changed the captured prompt/context")
        try await client.emit("回答")
        await client.finish()
        try await eventually { !store.isGenerating }
        try require(store.input == "原问题", "Success cleared draft written during preflight")
        store.input = "取消预检"
        store.send()
        try await eventually { SurfaceAccess.shared.waiting != nil }
        store.stop()
        store.input = "取消后的草稿"
        SurfaceAccess.shared.waiting?.resume(returning: "\n旧便签上下文")
        SurfaceAccess.shared.waiting = nil
        try await Task.sleep(for: .milliseconds(50))
        try require(await client.count == 1 && store.turns.count == 1 && store.input == "取消后的草稿",
                    "Cancelled file preflight accepted a late submission or consumed the new draft")
    }
}
