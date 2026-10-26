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
    @Published var input = "" { didSet { if input != oldValue { draftRevision &+= 1 } } }
    @Published private(set) var answer = ""
    @Published private(set) var turns: [HermesTranscript.Turn] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var isPreparingRequest = false
    @Published private(set) var isPreparingDrop = false
    @Published private(set) var isSaving = false
    @Published private(set) var attachments: [StagedAttachment] = []
    @Published var includesNote = false
    @Published var isWide = false
    @Published var capturesNotchDrops = false
    @Published var message: String?
    private var transcript = HermesTranscript()
    private var draftRevision: UInt = 0
    private struct Submission {
        let turnID: UUID
        let prompt: String
        let attachments: [StagedAttachment]
        let note: NoteSelection?
    }
    private var retryableSubmission: Submission?
    private let client: any HermesStreaming
    private let idleExpirationDelay: Duration
    private var lockObserver: AnyCancellable?
    private var generation: Task<Void, Never>?
    private var expiration: Task<Void, Never>?
    private var flush: Task<Void, Never>?
    private var pending = ""
    private var receivedBytes = 0
    private var dropID = UUID()
    private var visible: Set<String> = []
    private var generationID = UUID()
    init(client: any HermesStreaming = HermesClient(), idleExpirationDelay: Duration = .seconds(900)) {
        self.client = client
        self.idleExpirationDelay = idleExpirationDelay
        // The store owns requests even when no drawer exists. Lock protection must have the
        // same lifetime; a view-scoped subscription disappears as soon as the notch closes.
        lockObserver = NotificationCenter.default.publisher(for: .islandLocked)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.stop() }
    }

    func appeared(_ id: String) {
        guard visible.insert(id).inserted else { return }
        expiration?.cancel(); expiration = nil
        SurfaceAccess.shared.acquire()
    }
    func disappeared(_ id: String) {
        guard visible.remove(id) != nil else { return }
        SurfaceAccess.shared.release()
        guard visible.isEmpty else { return }
        scheduleExpirationIfIdle()
    }
    private func scheduleExpirationIfIdle() {
        expiration?.cancel()
        expiration = nil
        // Closing or changing tabs only detaches the UI. A running request keeps its context
        // until it finishes; the full idle interval starts after background completion.
        guard visible.isEmpty, !isGenerating, !isPreparingRequest else { return }
        let delay = idleExpirationDelay
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, visible.isEmpty, !isGenerating, !isPreparingRequest else { return }
            clear()
        }
    }
    func stop() {
        let id = generationID
        generationID = UUID(); generation?.cancel(); generation = nil
        flush?.cancel(); flush = nil
        flushPending(id: id)
        if transcript.finish(.stopped, request: id) { turns = transcript.turns }
        isGenerating = false; isPreparingRequest = false
        scheduleExpirationIfIdle()
    }
    func clear() {
        dropID = UUID()
        stop(); transcript.clear(); turns = []; answer = ""; input = ""; includesNote = false; isWide = false; message = nil
        expiration?.cancel(); expiration = nil
        releaseSubmission()
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
        start(prompt: prompt, staged: staged, note: note, configuration: configuration, draft: draftRevision)
    }
    func canRetry(_ turnID: UUID) -> Bool {
        !isGenerating && !isPreparingDrop && retryableSubmission?.turnID == turnID && turns.last?.canRetry == true
    }
    func retry(_ turnID: UUID) {
        guard canRetry(turnID), !isPreparingDrop, let submission = retryableSubmission else { return }
        do {
            start(prompt: submission.prompt, staged: submission.attachments, note: submission.note,
                  configuration: try IslandSettings.hermes(), retrying: turnID)
        } catch { message = error.localizedDescription }
    }
    private func start(prompt: String, staged: [StagedAttachment], note: NoteSelection?,
                       configuration: HermesConfiguration, draft: UInt? = nil, retrying turnID: UUID? = nil) {
        expiration?.cancel(); expiration = nil
        isGenerating = true; isPreparingRequest = true; message = nil
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
                let messages = transcript.messages + [ChatMessage(role: "user", parts: [.text(userText)] + parts)]
                // Validate the complete request while its original draft/attachments are intact.
                _ = try HermesClient.makeRequest(configuration: configuration, messages: messages)
                guard let accepted = try transcript.accept(request: id, prompt: prompt, user: userText, retrying: turnID) else {
                    throw IslandError.configuration("会话已变化，请重新发送。")
                }
                if turnID == nil { releaseSubmission() }
                retryableSubmission = Submission(turnID: accepted, prompt: prompt, attachments: staged, note: note)
                answer = ""; pending = ""; receivedBytes = 0
                turns = transcript.turns
                // A user may already be writing the next draft during asynchronous file preflight.
                if let draft, draftRevision == draft { input = "" }
                let stagedIDs = Set(staged.map(\.id))
                attachments.removeAll { stagedIDs.contains($0.id) }
                isPreparingRequest = false; started = true
                try await client.stream(configuration: configuration, messages: messages) { [weak self] delta in
                    try await self?.receive(delta, id: id)
                }
                try Task.checkCancellation()
                guard generationID == id else { return }
                flushPending(id: id)
                guard !answer.isEmpty else { throw IslandError.configuration("服务未返回回答。") }
                transcript.finish(.completed, request: id); turns = transcript.turns
                releaseSubmission()
            } catch is CancellationError {
                if generationID == id {
                    flushPending(id: id)
                    if transcript.finish(.stopped, request: id) { turns = transcript.turns }
                }
            } catch {
                if generationID == id {
                    flushPending(id: id)
                    if started {
                        transcript.finish(.failed(error.localizedDescription), request: id); turns = transcript.turns
                    } else { message = error.localizedDescription }
                }
            }
            if generationID == id {
                flush?.cancel(); flush = nil; flushPending(id: id)
                isGenerating = false; isPreparingRequest = false; generation = nil
                if started && Conversation.needsWideLayout(answer) { isWide = true }
                scheduleExpirationIfIdle()
            }
        }
    }
    private func releaseSubmission() {
        if let submission = retryableSubmission {
            for attachment in submission.attachments { deleteTemporary(attachment) }
        }
        retryableSubmission = nil
    }
    private func receive(_ delta: String, id: UUID) throws {
        guard id == generationID else { throw CancellationError() }
        receivedBytes += delta.utf8.count
        guard receivedBytes <= 131_072 else { throw IslandError.limit("回答超过 128 KB，已停止接收。") }
        pending += delta
        if flush == nil {
            flush = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, generationID == id else { return }
                flushPending(id: id); flush = nil
            }
        }
    }
    private func flushPending(id: UUID) {
        guard !pending.isEmpty else { return }
        answer += pending; pending = ""
        if transcript.updateAnswer(answer, request: id) { turns = transcript.turns }
        if Conversation.needsWideLayout(answer) { isWide = true }
    }
    private static func prepare(_ attachments: [StagedAttachment]) async throws -> [ChatPart] {
        let urls = attachments.map(\.url)
        let preparation = Task.detached(priority: .userInitiated) {
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
        }
        return try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
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
