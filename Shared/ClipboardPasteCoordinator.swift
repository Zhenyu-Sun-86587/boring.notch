import Foundation

enum ClipboardPasteResult: String, Sendable {
    case posted, cancelled, unauthorized, targetUnavailable, focusChanged
    case focusUnavailable, inputHeld, clipboardChanged, screenLocked, eventFailure
    case postEventUnauthorized, snapshotUnavailable
    case sessionUnavailable
}

/// Snapshot only: no clipboard contents or accessibility element text is retained.
struct ClipboardPasteObservation: Sendable {
    var authorized = true
    var postEventAuthorized = true
    var unlocked = true
    var sessionAvailable = true
    var targetAlive = true
    var clipboardUnchanged = true
    var originalTargetUnchanged = true
    var foregroundPID: Int32?
    var focusedPID: Int32?
    var focusProbeAvailable = true
    var originalInputReady = true
    var requiresNativeStability = false
    var inputReleased = true

    func withFocusAssessment(_ assessment: ClipboardFocusRestoration.Assessment) -> Self {
        var result = self
        result.originalTargetUnchanged = assessment.match != .conflict
        result.originalInputReady = assessment.inputReady
        result.requiresNativeStability = assessment.match == .unknown
        return result
    }
}

/// The helper uses the same sequence as the fixture checks. In particular a
/// frontmost PID alone does not prove that a nonactivating panel released focus.
@MainActor
final class ClipboardPasteCoordinator {
    enum Submission { case posted, requiresNativeStability, failed }
    struct Environment {
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(15)) }
        var observe: @MainActor () -> ClipboardPasteObservation
        var post: @MainActor () -> Submission
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
        var nativeStabilityRequired = false
        while environment.now() - started < 1.8 {
            guard !Task.isCancelled, activeRequest == requestID,
                  !retiredRequests.contains(requestID) else { return .cancelled }
            let observation = environment.observe()
            guard observation.authorized else { return .unauthorized }
            guard observation.postEventAuthorized else { return .postEventUnauthorized }
            guard observation.sessionAvailable else { return .sessionUnavailable }
            guard observation.unlocked else { return .screenLocked }
            guard observation.targetAlive else { return .targetUnavailable }
            guard observation.clipboardUnchanged else { return .clipboardChanged }
            guard observation.originalTargetUnchanged else { return .focusChanged }
            lastInputReleased = observation.inputReleased
            if (observation.requiresNativeStability || !observation.focusProbeAvailable) && !nativeStabilityRequired {
                nativeStabilityRequired = true
                readySince = nil
            }
            if let foreground = observation.foregroundPID {
                if foreground == targetPID { targetWasForeground = true }
                else if foreground != hostPID || targetWasForeground { return .focusChanged }
            }
            let ownsFocus = observation.foregroundPID == targetPID
                && (observation.focusedPID == targetPID || !observation.focusProbeAvailable)
            if ownsFocus && observation.originalInputReady && observation.inputReleased {
                if readySince == nil { readySince = environment.now() }
                // AX-less apps retain the native key window restored by orderOut.
                // Give that fallback a longer stable interval, rather than rejecting
                // Qt/custom controls which do not expose an accessibility focus tree.
                let interval: TimeInterval = nativeStabilityRequired ? 0.18 : 0.06
                if environment.now() - readySince! >= interval {
                    guard activeRequest == requestID, !Task.isCancelled else { return .cancelled }
                    // There is no delivery acknowledgement: never automatically try
                    // another transport after posting, which can paste twice.
                    switch environment.post() {
                    case .posted: return .posted
                    case .failed: return .eventFailure
                    case .requiresNativeStability:
                        // Final AX preflight lost its enhancement before any event was
                        // sent. Continue this request's native settling, never retry input.
                        nativeStabilityRequired = true
                        readySince = nil
                    }
                }
            } else { readySince = nil }
            do { try await environment.wait() } catch { return .cancelled }
        }
        return lastInputReleased ? .focusUnavailable : .inputHeld
    }
}
