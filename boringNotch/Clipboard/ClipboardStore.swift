import AppKit
import Combine
import ImageIO
import IslandCore
import UniformTypeIdentifiers

extension Notification.Name {
    static let clipboardPasteRequested = Notification.Name("ClipboardPasteRequested")
    static let clipboardDismissRequested = Notification.Name("ClipboardDismissRequested")
    static let clipboardCopyFailed = Notification.Name("ClipboardCopyFailed")
}

/// AppKit pasteboard access stays on the main actor; all persistence and image decoding are isolated.
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()
    @Published private(set) var records: [ClipboardHistoryRecord] = [] {
        didSet { rebuildResults() }
    }
    @Published var search = "" {
        didSet { if search != oldValue { rebuildResults(resetSelection: true) } }
    }
    @Published private(set) var filteredRecords: [ClipboardHistoryRecord] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var keyboardSelectionRevision: UInt = 0
    private(set) var keyboardSelectionDirection = 1
    @Published var keyboardSessionActive = false
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    @Published private(set) var pasting = false
    @Published private(set) var needsReadAccess = false
    @Published private(set) var needsPasteAccess = false
    @Published private(set) var readDenied = false
    @Published private(set) var requestingPermissions = false
    @Published private(set) var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "island.clipboardEnabled")
            if enabled { restartMonitor() } else {
                timer?.invalidate(); timer = nil
                cancelPermissionRequest()
            }
        }
    }
    @Published var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "island.clipboardRetentionDays"); applyLimits() }
    }
    @Published var maximumCount: Int {
        didSet { UserDefaults.standard.set(maximumCount, forKey: "island.clipboardMaximumCount"); applyLimits() }
    }
    @Published var diskMegabytes: Int {
        didSet { UserDefaults.standard.set(diskMegabytes, forKey: "island.clipboardDiskMB"); applyLimits() }
    }
    @Published var excludedApps: String {
        didSet { UserDefaults.standard.set(excludedApps, forKey: "island.clipboardExcludedApps") }
    }
    private let history: ClipboardHistory
    private let pasteboard: NSPasteboard
    private let notifications: NotificationCenter
    private let loadPayload: (String) async throws -> ClipboardPayload
    private let writePasteboard: ([NSPasteboardItem]) -> Bool
    private var timer: Timer?
    private var changeCount: Int
    private var started = false
    private var locked = false
    private var loading = false
    private var capturing = false
    private var permissionTask: Task<Void, Never>?
    private var permissionEpoch = UUID()
    private var monitorTick = 0
    private var legacyReadAllowed = false
    private var sessionGeneration = UUID()
    var sessionID: UUID { sessionGeneration }
    private var copyTask: Task<Void, Never>?
    private var copyActionID: UUID?
    private var heldScopes: [URL] = []
    private var scopeReleaseTask: Task<Void, Never>?
    private var thumbnailCache = NSCache<NSString, NSImage>()
    private var thumbnailTasks: [String: Task<NSImage?, Never>] = [:]
    private static let bookmarkType = "theboringteam.boringnotch.file-bookmark"
    private let supportedTypes = Set(["public.utf8-plain-text", "public.utf16-external-plain-text", "public.rtf", "public.html",
                                     "public.url", "public.file-url", "public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic"])

    init(history: ClipboardHistory? = nil, pasteboard: NSPasteboard = .general,
         defaults: UserDefaults = .standard, notifications: NotificationCenter = .default,
         loadPayload: ((String) async throws -> ClipboardPayload)? = nil,
         writePasteboard: (([NSPasteboardItem]) -> Bool)? = nil) {
        self.pasteboard = pasteboard
        self.notifications = notifications
        enabled = defaults.bool(forKey: "island.clipboardEnabled")
        retentionDays = max(1, defaults.object(forKey: "island.clipboardRetentionDays") as? Int ?? 7)
        maximumCount = max(20, defaults.object(forKey: "island.clipboardMaximumCount") as? Int ?? 200)
        diskMegabytes = max(32, defaults.object(forKey: "island.clipboardDiskMB") as? Int ?? 256)
        excludedApps = defaults.string(forKey: "island.clipboardExcludedApps") ?? ""
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let history = history ?? ClipboardHistory(directory: support.appendingPathComponent("boringNotch/Clipboard", isDirectory: true))
        self.history = history
        self.loadPayload = loadPayload ?? { try await history.payload(id: $0) }
        self.writePasteboard = writePasteboard ?? { objects in
            pasteboard.clearContents()
            return pasteboard.writeObjects(objects)
        }
        changeCount = pasteboard.changeCount
        thumbnailCache.countLimit = 24
        thumbnailCache.totalCostLimit = 12 * 1_024 * 1_024
    }
    var selectedRecord: ClipboardHistoryRecord? { filteredRecords.first { $0.id == selectedID } }

    private func rebuildResults(resetSelection: Bool = false) {
        let previousIndex = filteredRecords.firstIndex { $0.id == selectedID } ?? 0
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = records.filter {
            query.isEmpty || $0.searchableText.localizedStandardContains(query)
                || $0.sourceName?.localizedStandardContains(query) == true
                || $0.title.localizedStandardContains(query)
        }.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            if $0.copiedAt != $1.copiedAt { return $0.copiedAt > $1.copiedAt }
            return $0.id < $1.id
        }
        // Selection updates do not re-filter/re-sort the full history on every arrow or mouse event.
        if updated != filteredRecords { filteredRecords = updated }
        let next = ClipboardSelectionPolicy.reconciledID(selectedID, in: updated.map(\.id),
            fallbackIndex: resetSelection ? 0 : previousIndex, reset: resetSelection)
        if next != selectedID { selectedID = next }
    }

    func select(_ id: String) {
        guard filteredRecords.contains(where: { $0.id == id }), selectedID != id else { return }
        selectedID = id
    }

    func dismiss() {
        notifications.post(name: .clipboardDismissRequested, object: nil,
                                        userInfo: ["sessionID": sessionID.uuidString])
    }
    private var limits: ClipboardHistoryLimits {
        .init(count: maximumCount, retention: Double(retentionDays) * 86_400, diskBytes: min(1_024, max(64, diskMegabytes)) * 1_024 * 1_024)
    }
    func start() {
        guard !started else { return }; started = true
        applyLimits()
        if enabled { restartMonitor() }
    }
    func beginSession() {
        cancelCopyTask()
        pasting = false
        sessionGeneration = UUID()
        start()
        search = ""
        rebuildResults(resetSelection: true)
        applyLimits()
    }
    func endSession() {
        pasting = false
        sessionGeneration = UUID()
        cancelCopyTask()
        keyboardSessionActive = false
        search = ""
        thumbnailTasks.values.forEach { $0.cancel() }; thumbnailTasks.removeAll()
        thumbnailCache.removeAllObjects()
    }
    func setScreenLocked(_ value: Bool) {
        locked = value
        if value {
            cancelPermissionRequest()
            endSession(); timer?.invalidate(); timer = nil
        } else if enabled { changeCount = pasteboard.changeCount; restartMonitor() }
    }
    func reportPasteError(_ value: String) { message = value }
    func clearMessage() { message = nil }
    func setPasteAccessNeeded(_ value: Bool) { needsPasteAccess = value }
    func finishPaste(sessionID: String) {
        if sessionID == sessionGeneration.uuidString { pasting = false }
    }
    func setEnabledByUser(_ value: Bool) {
        enabled = value
        if value { requestPermissions() }
    }
    func requestReadAccess() { requestPermissions() }
    func requestPermissions() {
        guard !locked, permissionTask == nil else { return }
        if !enabled { enabled = true }
        let requestEpoch = permissionEpoch
        requestingPermissions = true
        permissionTask = Task { @MainActor in
            defer {
                if self.permissionEpoch == requestEpoch {
                    self.requestingPermissions = false
                    self.permissionTask = nil
                }
            }
            await ClipboardPermissionController.shared.requestOnEnable(readState: { [weak self] in
                self?.readPermissionState ?? .unavailable
            }, requestRead: { [weak self] in
                self?.performExplicitReadRequest() ?? .unavailable
            })
            guard self.permissionEpoch == requestEpoch, self.enabled, !self.locked, !Task.isCancelled else { return }
            self.refreshReadPermissionState()
        }
    }
    private func cancelPermissionRequest() {
        permissionEpoch = UUID()
        permissionTask?.cancel(); permissionTask = nil
        requestingPermissions = false
        ClipboardPermissionController.shared.cancelRequests()
    }
    private var readPermissionState: ClipboardPermissionPolicy.State {
        switch pasteboard.accessBehavior {
        case .alwaysAllow: return .authorized
        case .alwaysDeny: return .denied
        case .ask: return .ask
        case .default: return legacyReadAllowed ? .authorized : .undetermined
        @unknown default: return .unavailable
        }
    }
    private func refreshReadPermissionState() {
        let state = readPermissionState
        readDenied = state == .denied
        needsReadAccess = state == .ask || state == .undetermined
    }
    /// A permission probe is separate from capture, so an in-flight history write cannot drop
    /// a user's request. Probe bytes are discarded and never imported into history here.
    private func performExplicitReadRequest() -> ClipboardPermissionPolicy.State {
        guard enabled, !locked else { return .unavailable }
        let didRead = autoreleasepool {
            if let item = pasteboard.pasteboardItems?.first,
               let type = item.types.first(where: { supportedTypes.contains($0.rawValue) }) {
                return item.data(forType: type) != nil
            }
            return pasteboard.data(forType: .string) != nil
        }
        if pasteboard.accessBehavior == .default && didRead { legacyReadAllowed = true }
        refreshReadPermissionState()
        return readPermissionState
    }
    private func restartMonitor() {
        timer?.invalidate(); timer = nil
        guard enabled, !locked else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer?.tolerance = 0.15
        poll()
    }
    private func poll() {
        guard enabled, !locked else { return }
        let access = pasteboard.accessBehavior
        readDenied = access == .alwaysDeny
        needsReadAccess = access == .ask || (access == .default && !legacyReadAllowed)
        guard access == .alwaysAllow || (access == .default && legacyReadAllowed) else { return }
        monitorTick += 1
        if monitorTick % 120 == 0 { applyLimits() }
        guard !capturing, pasteboard.changeCount != changeCount else { return }
        capture(allowPrompt: false)
    }
    private func capture(allowPrompt: Bool) {
        guard enabled, !locked, !capturing else { return }
        guard allowPrompt || pasteboard.accessBehavior == .alwaysAllow || (pasteboard.accessBehavior == .default && legacyReadAllowed) else { return }
        let count = pasteboard.changeCount
        guard count != changeCount else { return }
        changeCount = count
        let source = NSWorkspace.shared.frontmostApplication
        let extraApps = Set(excludedApps.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) })
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard !ClipboardPrivacy.shouldIgnore(types: types, sourceBundleID: source?.bundleIdentifier, extraApps: extraApps) else { return }
        guard let boardItems = pasteboard.pasteboardItems else {
            needsReadAccess = pasteboard.accessBehavior != .alwaysAllow
            return
        }
        readDenied = pasteboard.accessBehavior == .alwaysDeny
        // Older systems may expose the API before enforcing pasteboard privacy. A successful
        // explicit user read in `.default` permits monitoring until the system reports ask/deny.
        if allowPrompt && pasteboard.accessBehavior == .default { legacyReadAllowed = true }
        needsReadAccess = pasteboard.accessBehavior == .ask || (pasteboard.accessBehavior == .default && !legacyReadAllowed)
        guard !readDenied, boardItems.count <= 64 else { return }
        var items: [ClipboardPayloadItem] = []
        var searchable = ""
        var kind: ClipboardHistoryRecord.Kind = .text
        var total = 0
        for item in boardItems {
            let itemTypes = Set(item.types.map(\.rawValue))
            if ClipboardPrivacy.shouldIgnore(types: itemTypes, sourceBundleID: source?.bundleIdentifier, extraApps: extraApps) { return }
            var representations: [ClipboardRepresentation] = []
            for type in item.types where supportedTypes.contains(type.rawValue) {
                guard let data = item.data(forType: type), !data.isEmpty else { continue }
                total += data.count
                guard total <= limits.itemBytes else { message = ClipboardHistoryError.tooLarge.localizedDescription; return }
                representations.append(.init(type: type.rawValue, data: data))
                if UTType(type.rawValue)?.conforms(to: .image) == true { kind = .image }
            }
            let plainText = item.string(forType: .string) ?? item.string(forType: .URL)
                ?? item.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
            if let text = plainText, !text.isEmpty {
                searchable += String(text.prefix(8_192)) + "\n"
            } else if let html = item.string(forType: .html) {
                // Metadata extraction never invokes HTML rendering or fetches remote resources.
                searchable += String(html.prefix(32_768)).replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&") + "\n"
            }
            if let path = item.string(forType: .fileURL), let url = URL(string: path), url.isFileURL {
                if kind != .image { kind = .file }
                searchable += url.lastPathComponent + "\n"
                // The pasteboard-granted file access is converted to a bookmark where possible.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    representations.append(.init(type: Self.bookmarkType, data: bookmark))
                }
            }
            if !representations.isEmpty { items.append(.init(representations: representations)) }
        }
        guard count == pasteboard.changeCount, !items.isEmpty else { return }
        let payload = ClipboardPayload(items: items)
        if kind == .text && searchable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard items.contains(where: { $0.representations.contains(where: { $0.type == "public.rtf" || $0.type == "public.html" }) }) else { return }
            searchable = "富文本"
        }
        let title: String
        switch kind {
        case .image: title = "图片"
        case .file: title = searchable.split(separator: "\n").first.map(String.init) ?? "文件"
        case .text: title = String(searchable.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        }
        capturing = true
        let currentLimits = limits
        Task {
            defer { capturing = false }
            do {
                let updated = try await history.insert(payload, title: title, searchableText: searchable, kind: kind,
                    sourceBundleID: source?.bundleIdentifier, sourceName: source?.localizedName, limits: currentLimits)
                records = updated
            } catch { message = error.localizedDescription }
        }
    }
    private func applyLimits() {
        guard !loading else { return }; loading = true
        let currentLimits = limits
        Task {
            defer { loading = false }
            do { records = try await history.load(limits: currentLimits) }
            catch { message = error.localizedDescription }
        }
    }
    func moveSelection(_ offset: Int) {
        let next = ClipboardSelectionPolicy.movedID(selectedID, in: filteredRecords.map(\.id), offset: offset)
        guard next != selectedID else { return }
        keyboardSelectionDirection = offset < 0 ? -1 : 1
        selectedID = next
        keyboardSelectionRevision &+= 1
    }
    func copySelected(paste: Bool) {
        guard let record = selectedRecord, !busy, !pasting else { return }
        copy(record, paste: paste)
    }
    func copy(_ record: ClipboardHistoryRecord, paste: Bool) {
        guard !busy, !pasting, !locked else { return }
        select(record.id)
        busy = true
        let generation = sessionGeneration
        let initialChangeCount = pasteboard.changeCount
        let actionID = UUID()
        copyActionID = actionID
        copyTask = Task {
            defer {
                if copyActionID == actionID { busy = false; copyTask = nil; copyActionID = nil }
            }
            do {
                let payload = try await loadPayload(record.id)
                guard !Task.isCancelled, !locked, sessionGeneration == generation else { return }
                let objects = try payload.items.map { item -> NSPasteboardItem in
                    let object = NSPasteboardItem()
                    for representation in item.representations where representation.type != Self.bookmarkType {
                        if representation.type == NSPasteboard.PasteboardType.fileURL.rawValue,
                           let path = String(data: representation.data, encoding: .utf8),
                           let url = URL(string: path), url.isFileURL {
                            var reachable = FileManager.default.fileExists(atPath: url.path)
                            if let bookmark = item.representations.first(where: { $0.type == Self.bookmarkType }) {
                                var stale = false
                                if let resolved = try? URL(resolvingBookmarkData: bookmark.data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
                                   resolved.startAccessingSecurityScopedResource() {
                                    heldScopes.append(resolved)
                                    reachable = FileManager.default.fileExists(atPath: resolved.path)
                                    object.setString(resolved.absoluteString, forType: .fileURL)
                                    continue
                                }
                            }
                            guard reachable else { throw ClipboardHistoryError.missing }
                        }
                        object.setData(representation.data, forType: .init(representation.type))
                    }
                    object.setString("1", forType: .init(ClipboardPrivacy.ownMarker))
                    return object
                }
                // End the file scope after the receiving app has time to consume file references.
                scheduleScopeRelease()
                guard pasteboard.changeCount == initialChangeCount else {
                    reportCopyFailure("剪贴板已被其他复制操作更改，已取消本次选择。", generation: generation)
                    return
                }
                guard writePasteboard(objects) else { throw ClipboardHistoryError.missing }
                changeCount = pasteboard.changeCount
                message = nil
                // Copy always completes before focus, helper or permission checks. The
                // presenter owns the latched destination and an optional AX enhancement.
                if paste {
                    pasting = true
                    notifications.post(name: .clipboardPasteRequested, object: nil,
                                       userInfo: ["sessionID": generation.uuidString, "changeCount": changeCount])
                } else {
                    notifications.post(name: .clipboardDismissRequested, object: nil,
                                       userInfo: ["sessionID": generation.uuidString])
                }
            } catch {
                scheduleScopeRelease()
                guard !Task.isCancelled, !locked, sessionGeneration == generation, copyActionID == actionID else { return }
                reportCopyFailure(error.localizedDescription, generation: generation)
            }
        }
    }
    private func reportCopyFailure(_ value: String, generation: UUID) {
        message = value
        notifications.post(name: .clipboardCopyFailed, object: nil,
                           userInfo: ["sessionID": generation.uuidString, "message": value])
    }
    private func cancelCopyTask() {
        copyActionID = nil
        copyTask?.cancel(); copyTask = nil
        busy = false
    }
    private func scheduleScopeRelease() {
        scopeReleaseTask?.cancel()
        scopeReleaseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self else { return }
            heldScopes.forEach { $0.stopAccessingSecurityScopedResource() }; heldScopes = []
        }
    }
    func favorite(_ record: ClipboardHistoryRecord) {
        Task { do { records = try await history.setFavorite(id: record.id, value: !record.favorite) } catch { message = error.localizedDescription } }
    }
    func delete(_ record: ClipboardHistoryRecord) {
        Task {
            do {
                records = try await history.delete(id: record.id)
                thumbnailCache.removeObject(forKey: record.id as NSString)
            } catch { message = error.localizedDescription }
        }
    }
    func clear() {
        Task {
            do { try await history.clear(); records = []; thumbnailCache.removeAllObjects() }
            catch { message = error.localizedDescription }
        }
    }
    func thumbnail(for record: ClipboardHistoryRecord) async -> NSImage? {
        if let cached = thumbnailCache.object(forKey: record.id as NSString) { return cached }
        guard record.kind == .image else { return nil }
        if let task = thumbnailTasks[record.id] { return await task.value }
        let history = self.history
        let task = Task<NSImage?, Never> {
            let decoded = await ClipboardThumbnailRenderer.shared.render(history: history, id: record.id)
            guard !Task.isCancelled, let decoded, let image = NSImage(data: decoded) else { return nil }
            thumbnailCache.setObject(image, forKey: record.id as NSString, cost: 240 * 240 * 4)
            return image
        }
        thumbnailTasks[record.id] = task
        let result = await task.value
        thumbnailTasks.removeValue(forKey: record.id)
        return result
    }
}
