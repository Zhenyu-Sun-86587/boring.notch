// Compile with the production HermesStore. Every dependency below is a fixture: no application
// window, pasteboard, Keychain, user settings/file or network service is accessed.
import AppKit
import ImageIO
import IslandCore
import UniformTypeIdentifiers

extension Notification.Name { static let islandLocked = Notification.Name("fixture.islandLocked") }

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
    var hasFile = false
    var suspended = false
    var appendCount = 0
    var lastSaved = ""
    var waiting: CheckedContinuation<String, any Error>?
    func acquire() {}
    func release() {}
    func snapshot() throws -> NoteSelection { NoteSelection() }
    func context(selection: NoteSelection) async throws -> String {
        if fail { throw IslandError.configuration("测试便签读取失败") }
        if suspended { return try await withCheckedThrowingContinuation { waiting = $0 } }
        return "\n便签上下文"
    }
    func appendTask(_ text: String, selection: NoteSelection) async throws { appendCount += 1; lastSaved = text }
}
@MainActor struct ShelfStateViewModel {
    static let shared = Self()
    func hermesAttachments(including: Set<UUID>) throws -> [StagedAttachment] { [] }
}

@MainActor struct ClipboardStore {
    static let shared = Self()
    func contextPayload(id: String) async throws -> ClipboardPayload { throw ClipboardHistoryError.missing }
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
    var activeCount: Int { pending.count }

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
        try await backgroundGenerationSurvivesDrawerChanges()
        try await backgroundPreflightAndLock()
        try await defaultContextAndShelfFiles()
        try await explicitSelectionClipboardAndManualSave()
        try await fiveRoundContextAndImages()
        print("PASS: production HermesStore draft preflight, immediate user turn, thinking, partial failure, retry, cancellation and stale callbacks")
        print("PASS: closed/tab-switched Hermes requests continue, reopen restores progress, idle expiry waits for completion, hidden lock cancels, five complete context pairs, images excluded from history")
    }

    @MainActor private static func preflightPreservesDraft() async throws {
        let client = SubmissionClient()
        let store = HermesStore(client: client)
        defer { store.clear(); IslandSettings.fail = false; SurfaceAccess.shared.fail = false; SurfaceAccess.shared.hasFile = false; ShelfDropService.staged = [] }
        store.input = "配置错误时保留草稿"
        IslandSettings.fail = true
        store.send()
        try require(!store.isGenerating && store.input == "配置错误时保留草稿" && store.turns.isEmpty, "Configuration preflight consumed draft")
        IslandSettings.fail = false
        SurfaceAccess.shared.hasFile = true
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
        defer { store.clear(); SurfaceAccess.shared.suspended = false; SurfaceAccess.shared.hasFile = false }
        SurfaceAccess.shared.suspended = true
        SurfaceAccess.shared.hasFile = true
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

    @MainActor private static func backgroundGenerationSurvivesDrawerChanges() async throws {
        let client = SubmissionClient()
        let store = HermesStore(client: client, idleExpirationDelay: .milliseconds(120))
        defer { store.clear(); store.disappeared("primary"); store.disappeared("secondary") }
        store.appeared("primary")
        store.appeared("secondary")
        store.input = "收起后继续回答"
        store.send()
        try await eventually { await client.count == 1 }
        let turnID = store.turns[0].id
        store.disappeared("primary")
        try await client.emit("第一段")
        store.disappeared("secondary")
        try await Task.sleep(for: .milliseconds(280)) // Longer than the fixture's entire idle interval.
        try require(store.isGenerating && store.turns[0].id == turnID,
                    "Last drawer close cancelled or expired the active request")
        try await client.emit("，后台第二段")
        try await eventually { store.answer == "第一段，后台第二段" }
        store.appeared("primary")
        try require(store.turns.count == 1 && store.turns[0].status == .responding,
                    "Reopening lost the in-flight turn or created another submission")
        store.disappeared("primary")
        try await client.emit("，完成")
        await client.finish()
        try await eventually { !store.isGenerating }
        try require(store.turns[0].status == .completed && store.answer == "第一段，后台第二段，完成",
                    "Background completion lost the answer")
        store.appeared("primary")
        try await Task.sleep(for: .milliseconds(280))
        let requestCount = await client.count
        try require(store.turns.count == 1 && requestCount == 1,
                    "Reopen did not cancel idle cleanup or restarted the request")
        store.disappeared("primary")
        try await eventually { store.turns.isEmpty }
        try require(store.answer.isEmpty && !store.isGenerating, "Idle completion did not release the conversation")
    }

    @MainActor private static func backgroundPreflightAndLock() async throws {
        let client = SubmissionClient()
        let store = HermesStore(client: client, idleExpirationDelay: .milliseconds(120))
        defer { store.clear(); store.disappeared("primary"); SurfaceAccess.shared.suspended = false; SurfaceAccess.shared.hasFile = false }
        SurfaceAccess.shared.suspended = true
        store.appeared("primary")
        SurfaceAccess.shared.hasFile = true
        store.includesNote = true
        store.input = "预检期间收起"
        store.send()
        try await eventually { SurfaceAccess.shared.waiting != nil }
        store.disappeared("primary")
        try await Task.sleep(for: .milliseconds(280))
        try require(store.isGenerating && store.isPreparingRequest && store.input == "预检期间收起",
                    "Closing during file preflight cancelled or expired the draft")
        SurfaceAccess.shared.waiting?.resume(returning: "\n便签上下文")
        SurfaceAccess.shared.waiting = nil
        SurfaceAccess.shared.suspended = false
        try await eventually { await client.count == 1 }
        try require(store.input.isEmpty && store.turns[0].status == .thinking,
                    "Closed preflight did not submit exactly once")
        try await client.emit("锁屏前片段")
        NotificationCenter.default.post(name: .islandLocked, object: nil)
        try await eventually { !store.isGenerating }
        try await eventually { await client.activeCount == 0 }
        try require(store.turns.last?.status == .stopped && store.answer == "锁屏前片段",
                    "A hidden store failed to stop on lock or lost buffered output")
        store.appeared("primary")
        try require(store.canRetry(store.turns[0].id), "Lock cancellation lost the explicit retry action")
    }

    @MainActor private static func defaultContextAndShelfFiles() async throws {
        let client = SubmissionClient()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-context-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("shelf-context.md")
        try Data("UNIQUE-SHELF-CONTEXT".utf8).write(to: file)
        let image = directory.appendingPathComponent("shelf-image.png")
        let bitmap = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(image as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "Could not write Shelf image fixture")
        let source = StagedAttachment(url: file, temporary: false)
        let picture = StagedAttachment(url: image, temporary: false)
        var snapshots = 0
        let store = HermesStore(client: client, shelfAttachments: { included in
            snapshots += 1
            return [source, picture].filter { included.contains($0.id) }
        })
        SurfaceAccess.shared.hasFile = true
        defer { store.clear(); SurfaceAccess.shared.hasFile = false; try? FileManager.default.removeItem(at: directory) }
        try require(store.includesNote, "Bound note is not included by default")
        store.toggleShelfItem(source.id)
        store.toggleShelfItem(picture.id)
        store.input = "依据便签和暂存区回答"
        store.send()
        try await eventually { await client.count == 1 }
        let first = await client.requests[0]
        let body = try HermesClient.makeRequest(configuration: IslandSettings.hermes(), messages: first).httpBody!
        let decoded = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let content = (decoded["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        let text = content[0]["text"] as! String
        let imageURL = (content[1]["image_url"] as! [String: Any])["url"] as! String
        try require(content.count == 2 && imageURL.hasPrefix("data:image/jpeg;base64,"), "Serialized request lost Shelf image bytes")
        try require(text.contains("便签上下文") && text.contains("UNIQUE-SHELF-CONTEXT"), "Serialized HTTP request lost default note or shelf text")
        try await client.emit("第一答")
        await client.finish()
        try await eventually { !store.isGenerating }
        try require(FileManager.default.fileExists(atPath: file.path), "Sending context deleted Shelf-owned source")
        store.includesNote = false
        store.toggleShelfItem(source.id)
        store.toggleShelfItem(picture.id)
        store.input = "追问"
        store.send()
        try await eventually { await client.count == 2 }
        let followup = await client.requests[1]
        try require(followup[0].parts[0].text == text, "Text attachment was dropped from completed conversation history")
        try require(followup.last?.parts[0].text == "追问", "Excluded note/shelf was attached again to current question")
        try await client.emit("第二答")
        await client.finish()
        try await eventually { !store.isGenerating }
        store.toggleShelfItem(source.id)
        store.toggleShelfItem(picture.id)
        try Data("UPDATED-SHELF-CONTEXT".utf8).write(to: file, options: .atomic)
        store.input = "再读取"
        store.send()
        try await eventually { await client.count == 3 }
        try require(await client.requests[2].last?.parts[0].text?.contains("UPDATED-SHELF-CONTEXT") == true, "Shelf was not reread at submission")
        try await client.emit("第三答")
        await client.finish()
        try await eventually { !store.isGenerating }
        try FileManager.default.removeItem(at: file)
        store.input = "文件失效保留草稿"
        store.send()
        try await eventually { !store.isGenerating }
        try require(await client.count == 3 && store.input == "文件失效保留草稿" && store.message != nil && snapshots == 4,
                    "Missing Shelf source was silently omitted or consumed the draft")
        print("PASS: serialized bound Markdown + Shelf text/image context; followup preserves attachment text; exclusions, fresh reads and failed preflight preserve source/draft")
    }

    @MainActor private static func explicitSelectionClipboardAndManualSave() async throws {
        let client = SubmissionClient()
        let missing = StagedAttachment(url: URL(fileURLWithPath: "/fixture-not-selected.txt"), temporary: false)
        let payload = ClipboardPayload(items: [.init(representations: [
            .init(type: UTType.utf8PlainText.identifier, data: Data("CLIPBOARD-EXPLICIT-TEXT".utf8))
        ])])
        let store = HermesStore(client: client, shelfAttachments: { included in
            included.contains(missing.id) ? [missing] : []
        }, clipboardPayload: { _ in payload })
        SurfaceAccess.shared.hasFile = true
        let saved = SurfaceAccess.shared.appendCount
        defer { store.clear(); SurfaceAccess.shared.hasFile = false }
        store.includesNote = false
        store.input = "无附件"
        store.send()
        try await eventually { await client.count == 1 }
        try require(await client.requests[0].last?.parts[0].text == "无附件" && store.selectedShelfIDs.isEmpty,
                    "Unselected Shelf file or disabled Markdown was sent")
        try await client.emit("第一答")
        await client.finish()
        try await eventually { !store.isGenerating }
        try require(SurfaceAccess.shared.appendCount == saved, "Completion automatically wrote to Markdown")
        store.stageClipboard("explicit-fixture-id")
        try await eventually { !store.isPreparingDrop }
        try require(store.attachments.count == 1 && store.attachments[0].displayName == "剪贴板文本", "Explicit clipboard selection did not create a chip")
        let source = store.attachments[0].url
        try require(await client.count == 1, "Selecting clipboard content sent an unsolicited request")
        store.input = "分析剪贴板"
        store.send()
        try await eventually { await client.count == 2 }
        try require(await client.requests[1].last?.parts[0].text?.contains("CLIPBOARD-EXPLICIT-TEXT") == true,
                    "Clipboard text was not included in the request")
        try await client.emit("只能手动保存的回复")
        await client.finish()
        try await eventually { !store.isGenerating }
        try require(!FileManager.default.fileExists(atPath: source.path), "Clipboard attachment temp file leaked after success")
        try require(SurfaceAccess.shared.appendCount == saved, "Clipboard completion automatically wrote to Markdown")
        store.saveAnswer()
        try await eventually { !store.isSaving }
        try require(SurfaceAccess.shared.appendCount == saved + 1 && SurfaceAccess.shared.lastSaved == "只能手动保存的回复",
                    "Explicit save did not write exactly once")
        // Image bytes become a temporary URL, never a system pasteboard write or full NSImage.
        let bitmap = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "Clipboard PNG fixture failed")
        let images = try HermesClipboardContext.files(from: .init(items: [.init(representations: [
            .init(type: UTType.png.identifier, data: data as Data)
        ])]), maximumCount: 1)
        defer { for item in images { try? FileManager.default.removeItem(at: item.url) } }
        try require(images.count == 1 && images[0].displayName == "剪贴板图片" && !(try AttachmentImage.jpeg(at: images[0].url)).isEmpty,
                    "Clipboard image bytes did not survive attachment staging")
        store.clear()
        try require(!store.includesNote, "Clear unexpectedly re-enabled Markdown context")
        var preferences: [Bool] = []
        let configured = HermesStore(client: client, noteEnabled: false, notePreferenceChanged: { preferences.append($0) })
        try require(!configured.includesNote, "Saved note switch was not restored")
        configured.includesNote = true
        configured.includesNote = false
        configured.clear()
        try require(preferences == [true, false], "Clear changed the saved note switch")
        print("PASS: explicit Shelf selection; input note switch; clipboard text/image staging; no implicit send or Markdown write; one manual save")
    }

    @MainActor private static func fiveRoundContextAndImages() async throws {
        let client = SubmissionClient()
        let store = HermesStore(client: client)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-images-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { store.clear(); ShelfDropService.staged = []; try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("fixture.png")
        let bitmap = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(image as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "Could not write the isolated image fixture")
        ShelfDropService.staged = [.init(url: image, temporary: true)]
        store.stage([NSItemProvider()])
        try await eventually { !store.isPreparingDrop }
        for index in 0..<7 {
            store.input = "问题\(index)"
            store.send()
            try await eventually { await client.count == index + 1 }
            let messages = await client.requests[index]
            try require(messages.count == min(index, 5) * 2 + 1,
                        "Context did not retain five complete exchanges (ten messages) plus current question")
            try require(messages.first?.parts.first?.text == "问题\(max(0, index - 5))",
                        "Context evicted the wrong oldest exchange")
            try require(messages.dropLast().allSatisfy { $0.parts.allSatisfy { $0.imageURL == nil } },
                        "An earlier image was retained in model context")
            try require(messages.last?.parts.compactMap(\.imageURL).count == (index == 0 ? 1 : 0),
                        "Current attachment was lost or leaked into another request")
            try await client.emit("回答\(index)")
            await client.finish()
            try await eventually { !store.isGenerating }
            try require(store.turns.count == min(index + 1, 5)
                        && store.turns.first?.prompt == "问题\(max(0, index - 4))",
                        "Visible transcript did not evict whole turns at five exchanges")
            try require(!FileManager.default.fileExists(atPath: image.path),
                        "Completed request retained its temporary image source")
        }
        try await eventually { await client.activeCount == 0 }

        // Cancellation ends the encoded request; only the temporary source URL remains for
        // an explicit retry. Clearing the conversation releases that source as well.
        let retryDestination = CGImageDestinationCreateWithURL(image as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(retryDestination, bitmap.makeImage()!, nil)
        try require(CGImageDestinationFinalize(retryDestination), "Could not recreate the isolated image fixture")
        store.stage([NSItemProvider()])
        try await eventually { !store.isPreparingDrop }
        store.input = "停止带图请求"
        store.send()
        try await eventually { await client.count == 8 }
        store.stop()
        try await eventually { await client.activeCount == 0 }
        try require(store.canRetry(store.turns.last!.id) && FileManager.default.fileExists(atPath: image.path),
                    "Explicit cancellation lost the source required for retry")
        store.clear()
        try require(!FileManager.default.fileExists(atPath: image.path) && store.turns.isEmpty && store.attachments.isEmpty,
                    "Clear retained a cancelled request's temporary image or history")
    }
}
