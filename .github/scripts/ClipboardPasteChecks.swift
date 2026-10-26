import Foundation

private struct Failure: Error { let reason: String }
@MainActor private func check(_ condition: Bool, _ reason: String) throws {
    if !condition { throw Failure(reason: reason) }
}

@MainActor private final class Fixture {
    var time: TimeInterval = 0
    var posts = 0
    var postedAt: TimeInterval?
    var postSucceeds = true
    var sample: (TimeInterval) -> ClipboardPasteObservation = { _ in
        ClipboardPasteObservation(foregroundPID: 100, focusedPID: 100)
    }
    var onWait: (() async throws -> Void)?
    var environment: ClipboardPasteCoordinator.Environment {
        .init(now: { self.time }, wait: {
            self.time += 0.015
            try await self.onWait?()
        }, observe: { self.sample(self.time) }, post: {
            self.posts += 1; self.postedAt = self.time
            return self.postSucceeds
        })
    }
}

@main private enum ClipboardPasteChecks {
    @MainActor static func main() async throws {
        let coordinator = ClipboardPasteCoordinator()
        func run(_ fixture: Fixture, id: String = UUID().uuidString) async -> ClipboardPasteResult {
            await coordinator.perform(requestID: id, targetPID: 100, hostPID: 200, environment: fixture.environment)
        }
        let normal = Fixture()
        let normalID = UUID().uuidString
        try check(await run(normal, id: normalID) == .posted, "normal paste")
        try check(normal.posts == 1 && normal.postedAt! >= 0.06, "exactly one post after stable native focus")
        try check(await run(normal, id: normalID) == .cancelled && normal.posts == 1, "a completed request cannot paste twice")

        let panelStillKey = Fixture()
        panelStillKey.sample = { time in
            .init(foregroundPID: 100, focusedPID: time < 0.24 ? 200 : 100)
        }
        try check(await run(panelStillKey) == .posted, "wait for nonactivating panel focus to leave")
        try check(panelStillKey.postedAt! >= 0.30, "frontmost PID alone must not permit early paste")

        let heldReturn = Fixture()
        heldReturn.sample = { time in .init(foregroundPID: 100, focusedPID: 100, inputReleased: time >= 0.35) }
        try check(await run(heldReturn) == .posted && heldReturn.postedAt! >= 0.41, "wait for Return/modifiers/mouse release")

        let noAXTree = Fixture()
        noAXTree.sample = { _ in .init(foregroundPID: 100, focusedPID: nil, focusProbeAvailable: false) }
        try check(await run(noAXTree) == .posted && noAXTree.postedAt! >= 0.18, "native focus fallback for controls without an AX tree")

        let switched = Fixture()
        switched.sample = { time in .init(foregroundPID: time < 0.03 ? 100 : 300, focusedPID: 100) }
        try check(await run(switched) == .focusChanged && switched.posts == 0, "switching application cancels rather than stealing focus")

        let clipboardChanged = Fixture()
        clipboardChanged.sample = { time in .init(clipboardUnchanged: time < 0.03, foregroundPID: 100, focusedPID: 100) }
        try check(await run(clipboardChanged) == .clipboardChanged && clipboardChanged.posts == 0, "a newer copy cancels old paste")

        let locked = Fixture()
        locked.sample = { time in .init(unlocked: time < 0.03, foregroundPID: 100, focusedPID: 100) }
        try check(await run(locked) == .screenLocked && locked.posts == 0, "locking cancels paste")

        let denied = Fixture()
        denied.sample = { _ in .init(authorized: false, foregroundPID: 100, focusedPID: 100) }
        try check(await run(denied) == .unauthorized && denied.posts == 0, "authorization failure never posts")

        let postDenied = Fixture()
        postDenied.sample = { _ in .init(postEventAuthorized: false, foregroundPID: 100, focusedPID: 100) }
        try check(await run(postDenied) == .postEventUnauthorized && postDenied.posts == 0, "AX authorization alone never claims event-post permission")
        let inputNotRestored = Fixture()
        inputNotRestored.sample = { time in .init(foregroundPID: 100, focusedPID: 100, originalInputReady: time >= 0.3) }
        try check(await run(inputNotRestored) == .posted && inputNotRestored.postedAt! >= 0.36, "frontmost app is insufficient until the original input is restored")
        let otherWindow = Fixture()
        otherWindow.sample = { _ in .init(originalTargetUnchanged: false, foregroundPID: 100, focusedPID: 100) }
        try check(await run(otherWindow) == .focusChanged && otherWindow.posts == 0, "another window/editor cancels instead of receiving old content")

        try check(ClipboardFocusRestoration.mayRestore(sameWindow: true, savedElementValid: true, relation: .ancestorContainer), "browser WebArea ancestor can restore the original field")
        try check(ClipboardFocusRestoration.mayRestore(sameWindow: true, savedElementValid: true, relation: .missing), "temporary loss of focused element can restore the saved field")
        try check(!ClipboardFocusRestoration.mayRestore(sameWindow: true, savedElementValid: true, relation: .differentControl), "a newly focused editor is never overridden")
        try check(!ClipboardFocusRestoration.mayRestore(sameWindow: false, savedElementValid: true, relation: .original), "another window is never raised")
        try check(!ClipboardFocusRestoration.mayRestore(sameWindow: true, savedElementValid: false, relation: .missing), "deleted editors cannot be restored")
        try check(!ClipboardFocusRestoration.ready(sameWindow: true, relation: .ancestorContainer, capturedElementFocused: false), "restoration must finish before posting")
        try check(ClipboardFocusRestoration.ready(sameWindow: true, relation: .ancestorContainer, capturedElementFocused: true), "AXFocused confirms a restored field despite container focus reporting")

        let focusTimeout = Fixture()
        focusTimeout.sample = { _ in .init(foregroundPID: 100, focusedPID: 200) }
        try check(await run(focusTimeout) == .focusUnavailable && focusTimeout.posts == 0, "focus timeout stays bounded")
        let keyTimeout = Fixture()
        keyTimeout.sample = { _ in .init(foregroundPID: 100, focusedPID: 100, inputReleased: false) }
        try check(await run(keyTimeout) == .inputHeld && keyTimeout.posts == 0, "held input never falls through at deadline")

        let cancelled = Fixture()
        let cancelledID = UUID().uuidString
        cancelled.onWait = { coordinator.cancel(cancelledID) }
        try check(await run(cancelled, id: cancelledID) == .cancelled && cancelled.posts == 0, "XPC cancel prevents a delayed post")
        let cancelledEarly = Fixture()
        let earlyID = UUID().uuidString
        coordinator.cancel(earlyID)
        try check(await run(cancelledEarly, id: earlyID) == .cancelled && cancelledEarly.posts == 0, "cancel arriving before request is retained")

        let old = Fixture(), replacement = Fixture()
        var replacementResult: ClipboardPasteResult?
        old.onWait = {
            old.onWait = nil
            replacementResult = await run(replacement)
        }
        try check(await run(old) == .cancelled && old.posts == 0, "new request invalidates the older sequence")
        try check(replacementResult == .posted && replacement.posts == 1, "only the new request posts")

        let interrupted = Fixture()
        interrupted.onWait = { throw CancellationError() }
        try check(await run(interrupted) == .cancelled && interrupted.posts == 0, "cancelled wait does not continue")

        let failedTransport = Fixture()
        failedTransport.postSucceeds = false
        try check(await run(failedTransport) == .eventFailure && failedTransport.posts == 1, "failed post is not retried through another route")
        print("PASS paste sequence: native focus, variable activation, AX-less controls, input release, cancellation, supersession, lock, newer clipboard and single delivery")
    }
}
