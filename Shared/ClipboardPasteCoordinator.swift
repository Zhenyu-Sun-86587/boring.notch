import Foundation

enum ClipboardPasteResult: String, Sendable {
    case posted, cancelled, unauthorized, targetUnavailable, focusChanged
    case focusUnavailable, inputHeld, clipboardChanged, screenLocked, eventFailure
}

/// Snapshot only: no clipboard contents or accessibility element text is retained.
struct ClipboardPasteObservation: Sendable {
    var authorized = true
    var unlocked = true
    var targetAlive = true
    var clipboardUnchanged = true
    var foregroundPID: Int32?
    var focusedPID: Int32?
    var focusProbeAvailable = true
    var inputReleased = true
}

/// The helper uses the same sequence as the fixture checks. In particular a
/// frontmost PID alone does not prove that a nonactivating panel released focus.
@MainActor
final class ClipboardPasteCoordinator {
    struct Environment {
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(15)) }
        var observe: () -> ClipboardPasteObservation
        var post: () -> Bool
    }

    private var activeRequest: String?
    private var retiredRequests: [String] = []

    func cancel(_ requestID: String) {
        retire(requestID)
        if activeRequest == requestID { activeRequest = nil }
    }

    private func retire(_ requestID: String) {
        guard !retiredRequests.contains(requestID) else { return }
        retiredRequests.append(requestID)
        if retiredRequests.count > 64 { retiredRequests.removeFirst(retiredRequests.count - 64) }
    }

    func perform(requestID: String, targetPID: Int32, hostPID: Int32,
                 environment: Environment) async -> ClipboardPasteResult {
        guard UUID(uuidString: requestID) != nil, !retiredRequests.contains(requestID) else { return .cancelled }
        activeRequest = requestID
        defer {
            if activeRequest == requestID { activeRequest = nil }
            retire(requestID)
        }
        let started = environment.now()
        var readySince: TimeInterval?
        var targetWasForeground = false
        var lastInputReleased = false
        while environment.now() - started < 1.8 {
            guard !Task.isCancelled, activeRequest == requestID,
                  !retiredRequests.contains(requestID) else { return .cancelled }
            let observation = environment.observe()
            guard observation.authorized else { return .unauthorized }
            guard observation.unlocked else { return .screenLocked }
            guard observation.targetAlive else { return .targetUnavailable }
            guard observation.clipboardUnchanged else { return .clipboardChanged }
            lastInputReleased = observation.inputReleased
            if let foreground = observation.foregroundPID {
                if foreground == targetPID { targetWasForeground = true }
                else if foreground != hostPID || targetWasForeground { return .focusChanged }
            }
            let ownsFocus = observation.foregroundPID == targetPID
                && (observation.focusedPID == targetPID || !observation.focusProbeAvailable)
            if ownsFocus && observation.inputReleased {
                if readySince == nil { readySince = environment.now() }
                // AX-less apps retain the native key window restored by orderOut.
                // Give that fallback a longer stable interval, rather than rejecting
                // Qt/custom controls which do not expose an accessibility focus tree.
                let interval: TimeInterval = observation.focusProbeAvailable ? 0.06 : 0.18
                if environment.now() - readySince! >= interval {
                    guard activeRequest == requestID, !Task.isCancelled else { return .cancelled }
                    // There is no delivery acknowledgement: never automatically try
                    // another transport after posting, which can paste twice.
                    return environment.post() ? .posted : .eventFailure
                }
            } else { readySince = nil }
            do { try await environment.wait() } catch { return .cancelled }
        }
        return lastInputReleased ? .focusUnavailable : .inputHeld
    }
}
