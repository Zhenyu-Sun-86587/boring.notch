import AppKit
import Combine
import IslandCore
import UniformTypeIdentifiers

struct StagedAttachment: Identifiable {
    let id = UUID()
    let url: URL
    let temporary: Bool
}

@MainActor
final class HermesStore: ObservableObject {
    static let shared = HermesStore()
    @Published var input = ""
    @Published private(set) var answer = ""
    @Published private(set) var turns: [Conversation.Turn] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var isPreparingDrop = false
    @Published private(set) var isSaving = false
    @Published private(set) var attachments: [StagedAttachment] = []
    @Published var includesNote = false
    @Published var isWide = false
    @Published var capturesNotchDrops = false
    @Published var message: String?
    private var conversation = Conversation()
    private let client: any HermesStreaming
    private var generation: Task<Void, Never>?
    private var expiration: Task<Void, Never>?
    private var flush: Task<Void, Never>?
    private var pending = ""
    private var receivedBytes = 0
    private var dropID = UUID()
    private var visible: Set<String> = []
    private var generationID = UUID()
    init(client: any HermesStreaming = HermesClient()) { self.client = client }

    func appeared(_ id: String) {
        guard visible.insert(id).inserted else { return }
        expiration?.cancel(); expiration = nil
        SurfaceAccess.shared.acquire()
    }
    func disappeared(_ id: String) {
        guard visible.remove(id) != nil else { return }
        SurfaceAccess.shared.release()
        guard visible.isEmpty else { return }
        stop()
        expiration?.cancel()
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(900)) } catch { return }
            self?.clear()
        }
    }
    func stop() {
        generationID = UUID(); generation?.cancel(); generation = nil
        flush?.cancel(); flush = nil
        flushPending(); isGenerating = false
    }
    func clear() {
        dropID = UUID()
        stop(); conversation.clear(); turns = []; answer = ""; input = ""; includesNote = false; isWide = false; message = nil
        for attachment in attachments { deleteTemporary(attachment) }
        attachments = []
    }
    func remove(_ attachment: StagedAttachment) {
        guard !isGenerating else { return }
        deleteTemporary(attachment); attachments.removeAll { $0.id == attachment.id }
    }
    private func deleteTemporary(_ item: StagedAttachment) {
        if item.temporary { try? FileManager.default.removeItem(at: item.url) }
    }
    func stage(_ providers: [NSItemProvider]) {
        guard !isGenerating, !isPreparingDrop else { return }
        let remaining = max(0, 6 - attachments.count)
        guard remaining > 0 else { message = "最多暂存 6 个附件。"; return }
        isPreparingDrop = true
        let id = UUID(); dropID = id
        Task {
            defer { isPreparingDrop = false }
            do {
                let staged = try await ShelfDropService.stagingFiles(from: Array(providers.prefix(remaining)))
                guard id == dropID else {
                    for item in staged where item.temporary { try? FileManager.default.removeItem(at: item.url) }
                    return
                }
                attachments.append(contentsOf: staged.map { StagedAttachment(url: $0.url, temporary: $0.temporary) })
            } catch { message = error.localizedDescription }
        }
    }
    func send() {
        guard !isGenerating, !isPreparingDrop, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let prompt = input
        guard prompt.utf8.count <= 65_536 else { message = "输入超过 64 KB。"; return }
        let staged = attachments
        let configuration: HermesConfiguration
        let note: NoteSelection?
        do {
            configuration = try IslandSettings.hermes()
            note = includesNote ? try SurfaceAccess.shared.snapshot() : nil
        } catch { message = error.localizedDescription; return }
        isGenerating = true; message = nil
        let id = UUID(); generationID = id
        generation = Task { [weak self] in
            guard let self else { return }
            var started = false
            do {
                let context: String
                if let note { context = try await SurfaceAccess.shared.context(selection: note) }
                else { context = "" }
                let parts = try await Self.prepare(staged)
                try Task.checkCancellation()
                guard generationID == id else { return }
                let userText = prompt + context
                let messages = conversation.messages + [ChatMessage(role: "user", parts: [.text(userText)] + parts)]
                answer = ""; pending = ""; receivedBytes = 0; started = true
                try await client.stream(configuration: configuration, messages: messages) { [weak self] delta in
                    try await self?.receive(delta, id: id)
                }
                try Task.checkCancellation()
                guard generationID == id else { return }
                flushPending()
                conversation.append(user: userText, assistant: answer, displayPrompt: prompt); turns = conversation.turns
                input = ""
                for attachment in attachments { deleteTemporary(attachment) }
                attachments = []
            } catch is CancellationError {
                // Keep draft and partial output for an explicit retry.
            } catch {
                if generationID == id { message = error.localizedDescription }
            }
            if generationID == id {
                flush?.cancel(); flush = nil; flushPending(); isGenerating = false; generation = nil
                if started && Conversation.needsWideLayout(answer) { isWide = true }
            }
        }
    }
    private func receive(_ delta: String, id: UUID) throws {
        guard id == generationID else { throw CancellationError() }
        receivedBytes += delta.utf8.count
        guard receivedBytes <= 131_072 else { throw IslandError.limit("回答超过 128 KB，已停止接收。") }
        pending += delta
        if flush == nil {
            flush = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                self?.flushPending(); self?.flush = nil
            }
        }
    }
    private func flushPending() {
        answer += pending; pending = ""
        if Conversation.needsWideLayout(answer) { isWide = true }
    }
    private static func prepare(_ attachments: [StagedAttachment]) async throws -> [ChatPart] {
        let urls = attachments.map(\.url)
        return try await Task.detached(priority: .userInitiated) {
            var parts: [ChatPart] = []
            var bytes = 0
            for url in urls {
                try Task.checkCancellation()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
                if type?.conforms(to: .image) == true {
                    let jpeg = try AttachmentImage.jpeg(at: url)
                    bytes += jpeg.count * 4 / 3
                    guard bytes <= 8 * 1_024 * 1_024 else { throw IslandError.limit("图片附件超过 8 MB，请减少图片。") }
                    parts.append(.image("data:image/jpeg;base64," + jpeg.base64EncodedString()))
                } else {
                    let text = try SurfaceFiles.read(url)
                    bytes += text.utf8.count
                    parts.append(.text("\n\n--- Attachment: \(url.lastPathComponent) ---\n" + text))
                }
            }
            return parts
        }.value
    }
    func saveAnswer() {
        guard !isGenerating, !isSaving, !answer.isEmpty else { return }
        let text = answer
        let selection: NoteSelection
        do { selection = try SurfaceAccess.shared.snapshot() }
        catch { message = error.localizedDescription; return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await SurfaceAccess.shared.appendTask(text, selection: selection)
                message = "已保存到 \(selection.name)"
            } catch { message = error.localizedDescription }
        }
    }
}
