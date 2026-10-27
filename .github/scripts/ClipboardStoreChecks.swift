// Compile and exercise ClipboardStore.copy itself, with only a private named
// pasteboard and temporary history. The user's general clipboard is never read/written.
import AppKit
import IslandCore

private struct Failure: Error { let reason: String }
@MainActor private func check(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
    if !condition() { throw Failure(reason: reason) }
}
@MainActor private final class PayloadGate {
    private var continuation: CheckedContinuation<ClipboardPayload, Error>?
    var waiting = false
    func load() async throws -> ClipboardPayload {
        try await withCheckedThrowingContinuation { continuation = $0; waiting = true }
    }
    func release(_ payload: ClipboardPayload) { continuation?.resume(returning: payload); continuation = nil }
    func fail() { continuation?.resume(throwing: ClipboardHistoryError.missing); continuation = nil }
}

@main private enum ClipboardStoreChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = ClipboardHistory(directory: directory)
        let defaultsName = "com.boringnotch.fixture.clipboard." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        let board = NSPasteboard.withUniqueName()
        defer {
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
        let notifications = NotificationCenter()
        final class Recorder: @unchecked Sendable {
            var requests: [Notification] = []
            var copiedBeforeRequest = false
            var dismissals = 0
            var pasteboard: NSPasteboard?
        }
        let recorder = Recorder()
        recorder.pasteboard = board
        let observer = notifications.addObserver(forName: .clipboardPasteRequested, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                recorder.requests.append(note)
                recorder.copiedBeforeRequest = recorder.pasteboard?.pasteboardItems?.first?.string(forType: .string) == "fixture text"
            }
        }
        defer { notifications.removeObserver(observer) }
        let payload = ClipboardPayload(items: [.init(representations: [
            .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("fixture text".utf8)),
            .init(type: NSPasteboard.PasteboardType.rtf.rawValue, data: Data("{\\rtf1 fixture}".utf8)),
            .init(type: NSPasteboard.PasteboardType.png.rawValue, data: Data([0x89, 0x50, 0x4e, 0x47]))
        ])])
        let record = try await history.insert(payload, title: "fixture", searchableText: "fixture", kind: .text,
            sourceBundleID: nil, sourceName: nil).first!
        let store = ClipboardStore(history: history, pasteboard: board, defaults: defaults, notifications: notifications)
        store.start()
        let deadline = ContinuousClock.now + .seconds(3)
        while store.records.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let beforeContextRead = board.changeCount
        let context = try await store.contextPayload(id: record.id)
        try check(context == payload && board.changeCount == beforeContextRead && recorder.requests.isEmpty,
                  "Explicit context read changed clipboard or invoked paste")
        store.copy(record, paste: true)
        try await settle(store)
        try check(recorder.requests.count == 1 && recorder.copiedBeforeRequest, "copy finishes before any paste/target/permission handling")
        try check(recorder.requests[0].userInfo?["sessionID"] as? String == store.sessionID.uuidString, "request has the originating session")
        try check(recorder.requests[0].userInfo?["changeCount"] as? Int == board.changeCount, "request has the newly written clipboard generation")
        try check(recorder.requests[0].userInfo?["targetToken"] == nil, "copy does not require an AX snapshot or helper permission")
        for representation in payload.items[0].representations {
            try check(board.pasteboardItems?.first?.data(forType: .init(representation.type)) == representation.data,
                      "original text/rich-text/image bytes are preserved")
        }
        store.finishPaste(sessionID: store.sessionID.uuidString)
        recorder.requests.removeAll()
        let dismissObserver = notifications.addObserver(forName: .clipboardDismissRequested, object: nil, queue: nil) { _ in recorder.dismissals += 1 }
        defer { notifications.removeObserver(dismissObserver) }
        store.copy(record, paste: false)
        try await settle(store)
        try check(recorder.dismissals == 1 && recorder.requests.isEmpty, "copy-only closes through the same current-session notification")

        let unchangedCount = board.changeCount
        let loadFailure = ClipboardStore(history: history, pasteboard: board, defaults: defaults,
            notifications: notifications, loadPayload: { _ in throw ClipboardHistoryError.missing })
        loadFailure.copy(record, paste: true)
        try await settle(loadFailure)
        try check(board.changeCount == unchangedCount && recorder.requests.isEmpty && loadFailure.message != nil,
                  "payload failure cannot clear the clipboard or start a paste")
        let writeFailure = ClipboardStore(history: history, pasteboard: board, defaults: defaults,
            notifications: notifications, writePasteboard: { _ in false })
        writeFailure.copy(record, paste: true)
        try await settle(writeFailure)
        try check(board.changeCount == unchangedCount && recorder.requests.isEmpty && writeFailure.message != nil,
                  "failed write cannot announce copied/paste success")

        for termination in ["close", "replacement", "lock"] {
            let gate = PayloadGate()
            let suspended = ClipboardStore(history: history, pasteboard: board, defaults: defaults,
                notifications: notifications, loadPayload: { _ in try await gate.load() })
            suspended.copy(record, paste: true)
            while !gate.waiting { await Task.yield() }
            if termination == "replacement" { suspended.beginSession() }
            else if termination == "lock" { suspended.setScreenLocked(true) }
            else { suspended.endSession() }
            gate.release(payload)
            for _ in 0..<20 { await Task.yield() }
            try check(board.changeCount == unchangedCount && recorder.requests.isEmpty && !suspended.busy && !suspended.pasting,
                      "\(termination) cancels the real pending payload read before writing")
        }
        let cancelledErrorGate = PayloadGate()
        let cancelledError = ClipboardStore(history: history, pasteboard: board, defaults: defaults,
            notifications: notifications, loadPayload: { _ in try await cancelledErrorGate.load() })
        cancelledError.copy(record, paste: true)
        while !cancelledErrorGate.waiting { await Task.yield() }
        cancelledError.endSession()
        cancelledErrorGate.fail()
        for _ in 0..<20 { await Task.yield() }
        try check(cancelledError.message == nil && recorder.requests.isEmpty, "late error from a cancelled load cannot pollute a later session")

        let newerCopyGate = PayloadGate()
        let superseded = ClipboardStore(history: history, pasteboard: board, defaults: defaults,
            notifications: notifications, loadPayload: { _ in try await newerCopyGate.load() })
        superseded.copy(record, paste: true)
        while !newerCopyGate.waiting { await Task.yield() }
        board.clearContents(); board.setString("newer fixture copy", forType: .string)
        let newerCount = board.changeCount
        newerCopyGate.release(payload)
        try await settle(superseded)
        try check(board.changeCount == newerCount && board.string(forType: .string) == "newer fixture copy"
                  && recorder.requests.isEmpty, "a newer clipboard write cancels the old pending selection")

        let file = directory.appendingPathComponent("fixture-file.txt")
        try Data("file fixture".utf8).write(to: file)
        let filePayload = ClipboardPayload(items: [.init(representations: [
            .init(type: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data(file.absoluteString.utf8))
        ])])
        let fileRecord = try await history.insert(filePayload, title: "file", searchableText: "file", kind: .file,
            sourceBundleID: nil, sourceName: nil).first!
        let fileStore = ClipboardStore(history: history, pasteboard: board, defaults: defaults, notifications: notifications)
        fileStore.copy(fileRecord, paste: true)
        try await settle(fileStore)
        try check(board.string(forType: .fileURL) == file.absoluteString && recorder.requests.count == 1,
                  "file URL representation survives the real Store copy path")
        fileStore.finishPaste(sessionID: fileStore.sessionID.uuidString)
        recorder.requests.removeAll()
        try FileManager.default.removeItem(at: file)
        let beforeMissingFile = board.changeCount
        fileStore.copy(fileRecord, paste: true)
        try await settle(fileStore)
        try check(board.changeCount == beforeMissingFile && recorder.requests.isEmpty && fileStore.message != nil,
                  "an unavailable file is rejected before clearing the pasteboard")
        print("PASS production ClipboardStore.copy: copy-first text/rich-text/image/file bytes, nil snapshot/permission-independent dispatch, clipboard generation, copy-only dismiss, load/write/missing-file failure, close/new-session/lock cancellation, late error and newer clipboard; private pasteboard only")
    }
    @MainActor private static func settle(_ store: ClipboardStore) async throws {
        for _ in 0..<400 {
            if !store.busy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(reason: "copy did not finish")
    }
}
