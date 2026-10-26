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
    var preflightChecks = 0
    var requireNativeOnFirstPreflight = false
    var sample: (TimeInterval) -> ClipboardPasteObservation = { _ in
        ClipboardPasteObservation(foregroundPID: 100, focusedPID: 100)
    }
    var onWait: (() async throws -> Void)?
    var environment: ClipboardPasteCoordinator.Environment {
        .init(now: { self.time }, wait: {
            self.time += 0.015
            try await self.onWait?()
        }, observe: { self.sample(self.time) }, post: {
            self.preflightChecks += 1
            if self.requireNativeOnFirstPreflight && self.preflightChecks == 1 { return .requiresNativeStability }
            self.posts += 1; self.postedAt = self.time
            return self.postSucceeds ? .posted : .failed
        })
    }
}

@main private enum ClipboardPasteChecks {
    @MainActor static func main() async throws {
        try destinationTrackerChecks()
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

        try check(ClipboardFocusRestoration.relation(sameElement: false, currentRole: "AXUnknown", knownAncestor: false) == .unavailable,
                  "AXUnknown cannot prove a different control")
        try check(ClipboardFocusRestoration.relation(sameElement: false, currentRole: "AXFutureRole", knownAncestor: false) == .unavailable,
                  "unrecognized AX role cannot prove a different control")
        try check(ClipboardFocusRestoration.relation(sameElement: false, currentRole: "AXGroup", knownAncestor: false) == .unavailable,
                  "unproven browser container is unknown")
        try check(ClipboardFocusRestoration.relation(sameElement: false, currentRole: "AXGroup", knownAncestor: true) == .ancestorContainer,
                  "captured ancestor remains safe for AX restoration")
        try check(ClipboardFocusRestoration.relation(sameElement: false, currentRole: "AXTextField", knownAncestor: false) == .differentControl,
                  "a different readable input is a positive conflict")
        let original = ClipboardFocusRestoration.Evidence(window: .matched, savedElementAvailable: true, relation: .original)
        let ancestor = ClipboardFocusRestoration.Evidence(window: .matched, savedElementAvailable: true, relation: .ancestorContainer)
        try check(ClipboardFocusRestoration.assess(original).mayRestore, "confirmed original window/control may restore")
        try check(ClipboardFocusRestoration.assess(ancestor).mayRestore && !ClipboardFocusRestoration.assess(ancestor).inputReady,
                  "known browser ancestor can restore but must finish before posting")
        var focusedAncestor = ancestor
        focusedAncestor.capturedElementFocused = true
        try check(ClipboardFocusRestoration.assess(focusedAncestor).inputReady, "AXFocused confirms restored field despite ancestor reporting")

        let unknownEvidence: [(String, ClipboardFocusRestoration.Evidence)] = [
            ("no record", .init()),
            ("saved element invalid", .init(window: .matched, savedElementAvailable: false, relation: .differentControl)),
            ("window noValue/timeout", .init(window: .unknown, savedElementAvailable: true, relation: .original)),
            ("focused element noValue", .init(window: .matched, savedElementAvailable: true, relation: .missing)),
            ("current role unavailable", .init(window: .matched, savedElementAvailable: true, relation: .unavailable)),
            ("unrecognized container", .init(window: .matched, savedElementAvailable: true, relation: .unavailable)),
            ("AX restore invalid/cannotComplete", .init(window: .matched, savedElementAvailable: true, relation: .original, restorationAvailable: false))
        ]
        for (name, evidence) in unknownEvidence {
            let assessment = ClipboardFocusRestoration.assess(evidence)
            try check(assessment.match == .unknown && !assessment.mayRestore && assessment.inputReady,
                      "\(name) is optional AX enhancement loss, never a proven conflict")
            let fallback = Fixture()
            fallback.sample = { _ in ClipboardPasteObservation(foregroundPID: 100, focusedPID: 100).withFocusAssessment(assessment) }
            try check(await run(fallback) == .posted && fallback.posts == 1 && fallback.postedAt! >= 0.18,
                      "\(name) uses one native paste after the longer stable interval")
        }
        let conflictEvidence: [(String, ClipboardFocusRestoration.Evidence)] = [
            ("different readable window", .init(window: .conflict)),
            ("different valid control", .init(window: .matched, savedElementAvailable: true, relation: .differentControl)),
            ("different control survives restore failure", .init(window: .matched, savedElementAvailable: true, relation: .differentControl, restorationAvailable: false))
        ]
        for (name, evidence) in conflictEvidence {
            var lease = ClipboardFocusRestoration.Lease()
            let assessment = lease.assess(evidence)
            try check(assessment.match == .conflict && !assessment.mayRestore && !assessment.inputReady,
                      "\(name) remains a positive conflict")
            try check(lease.assess(.init()).match == .conflict, "a later AX failure cannot erase \(name)")
            let conflict = Fixture()
            conflict.sample = { _ in ClipboardPasteObservation(foregroundPID: 100, focusedPID: 100).withFocusAssessment(assessment) }
            try check(await run(conflict) == .focusChanged && conflict.posts == 0, "\(name) never receives an event")
        }
        let unknownWithOtherFocus = Fixture()
        unknownWithOtherFocus.sample = { _ in ClipboardPasteObservation(foregroundPID: 100, focusedPID: 200)
            .withFocusAssessment(ClipboardFocusRestoration.assess(.init())) }
        try check(await run(unknownWithOtherFocus) == .focusUnavailable && unknownWithOtherFocus.posts == 0,
                  "unknown AX target never hides an explicit different focused application")
        let losesAXWhileSettling = Fixture()
        losesAXWhileSettling.sample = { time in ClipboardPasteObservation(foregroundPID: 100, focusedPID: 100)
            .withFocusAssessment(ClipboardFocusRestoration.assess(time < 0.045 || time > 0.075 ? original : .init())) }
        try check(await run(losesAXWhileSettling) == .posted && losesAXWhileSettling.posts == 1
                  && losesAXWhileSettling.postedAt! >= 0.225,
                  "matched-to-unknown resets and retains the native stable interval even if AX later recovers")

        let finalProbeLosesAX = Fixture()
        finalProbeLosesAX.requireNativeOnFirstPreflight = true
        try check(await run(finalProbeLosesAX) == .posted && finalProbeLosesAX.posts == 1
                  && finalProbeLosesAX.preflightChecks == 2 && finalProbeLosesAX.postedAt! >= 0.24,
                  "first unknown final preflight settles natively before one event, without retrying sent input")

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
        print("PASS paste sequence: native focus, variable activation, AX matched/unknown/conflict policy, sticky positive conflict, native stability after AX loss, input release, cancellation, supersession, lock, newer clipboard and single delivery")
    }

    @MainActor private static func destinationTrackerChecks() throws {
        let host: Int32 = 200, editorA: Int32 = 100, editorB: Int32 = 300

        // The first snapshot can happen while our permission dialog owns foreground. It must
        // not erase the previous editor or freeze the session permanently without a target.
        var permissionRoundTrip = ClipboardDestinationTracker()
        permissionRoundTrip.observeActivation(editorA, hostPID: host)
        permissionRoundTrip.observeActivation(host, hostPID: host)
        try check(permissionRoundTrip.rememberedPID == editorA, "permission alert activation preserves the last external editor")
        try check(permissionRoundTrip.begin(frontmostPID: host, hostPID: host, allowRemembered: false) == nil,
                  "a currently open own-editor/permission context does not choose an external destination")
        try check(permissionRoundTrip.activePID == nil, "failed initial capture does not create an active destination")
        try check(permissionRoundTrip.begin(frontmostPID: host, hostPID: host, allowRemembered: true) == editorA,
                  "after the permission window closes, a later capture can recover the remembered editor")
        try check(permissionRoundTrip.activePID == editorA, "recovered destination is latched for this session")

        // No activation history is not a target. A later real external foreground can recover
        // without closing/reopening the drawer solely to reset a failed-capture flag.
        var initiallyMissing = ClipboardDestinationTracker()
        try check(initiallyMissing.begin(frontmostPID: nil, hostPID: host, allowRemembered: true) == nil,
                  "a missing foreground does not invent a destination")
        try check(initiallyMissing.begin(frontmostPID: host, hostPID: host, allowRemembered: true) == nil,
                  "our application without external history does not become its own paste target")
        initiallyMissing.observeActivation(editorA, hostPID: host)
        try check(initiallyMissing.begin(frontmostPID: editorA, hostPID: host, allowRemembered: false) == editorA,
                  "later external foreground recovers a session whose first capture found no destination")

        // Workspace activation notifications may continue while the drawer is open. They are
        // useful for the next opening but must never silently redirect the current paste lease.
        var opened = ClipboardDestinationTracker()
        try check(opened.begin(frontmostPID: editorA, hostPID: host, allowRemembered: true) == editorA,
                  "external foreground is the initial destination")
        opened.observeActivation(editorB, hostPID: host)
        try check(opened.rememberedPID == editorB && opened.activePID == editorA,
                  "external activation updates future memory without replacing an active target")
        try check(opened.begin(frontmostPID: editorB, hostPID: host, allowRemembered: true) == editorA,
                  "repeated begin while open cannot redirect paste to a newly activated application")
        opened.observeActivation(host, hostPID: host)
        try check(opened.begin(frontmostPID: host, hostPID: host, allowRemembered: false) == editorA,
                  "a latched lease remains unchanged until end; foreground safety is checked by the paste coordinator")
        opened.end()
        try check(opened.activePID == nil && opened.rememberedPID == editorB,
                  "close releases only the active destination and retains latest external activation")
        try check(opened.begin(frontmostPID: editorB, hostPID: host, allowRemembered: true) == editorB,
                  "close and reopen uses the new foreground destination")

        // Fallback is only valid when our own non-editor UI is foreground; nil foreground and
        // settings text fields are deliberately excluded even with a remembered external app.
        var ownEditor = ClipboardDestinationTracker()
        ownEditor.observeActivation(editorA, hostPID: host)
        try check(ownEditor.begin(frontmostPID: nil, hostPID: host, allowRemembered: true) == nil,
                  "remembered destination is not used when there is no known foreground")
        try check(ownEditor.begin(frontmostPID: host, hostPID: host, allowRemembered: false) == nil,
                  "our settings input never falls back to a previously active external app")
        try check(ownEditor.begin(frontmostPID: editorB, hostPID: host, allowRemembered: false) == editorB,
                  "a verified external foreground takes priority over remembered fallback policy")

        // Process termination must remove only the matching destination, so a terminated PID
        // cannot be resurrected by a later own-window capture or corrupt an unrelated lease.
        var terminated = ClipboardDestinationTracker()
        terminated.observeActivation(editorA, hostPID: host)
        try check(terminated.begin(frontmostPID: editorA, hostPID: host, allowRemembered: true) == editorA,
                  "termination fixture captures the first editor")
        terminated.observeActivation(editorB, hostPID: host)
        terminated.forget(editorB)
        try check(terminated.rememberedPID == nil && terminated.activePID == editorA,
                  "terminating only the remembered app preserves an unrelated active destination")
        terminated.observeActivation(editorB, hostPID: host)
        terminated.forget(editorA)
        try check(terminated.activePID == nil && terminated.rememberedPID == editorB,
                  "terminating the active app releases that lease without discarding other history")
        terminated.forget(editorB)
        try check(terminated.begin(frontmostPID: host, hostPID: host, allowRemembered: true) == nil,
                  "terminated remembered apps are not reused from an own-window opening")
        terminated.observeActivation(editorA, hostPID: host)
        terminated.forget(999)
        terminated.observeActivation(nil, hostPID: host)
        try check(terminated.rememberedPID == editorA,
                  "unrelated termination and absent activation do not erase a valid remembered app")
        print("PASS clipboard destination state: permission round-trip recovery, retry after missing target, stable open-session lease, new target after close, terminated process cleanup and own-editor fallback exclusion")
    }
}
