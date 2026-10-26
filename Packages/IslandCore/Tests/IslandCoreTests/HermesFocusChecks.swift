import Foundation
import IslandCore

func hermesInputFocusChecks() throws {
    var generation = HermesFocusGeneration()
    let ready = HermesFocusEligibility(drawerOpen: true, hermesSelected: true,
        windowKey: true, windowVisible: true)
    let first = generation.invalidate()
    try expect(generation.permits(first, eligibility: ready))
    var waitingForWindow = ready
    waitingForWindow.windowKey = false
    try expect(!generation.permits(first, eligibility: waitingForWindow))
    let becameKey = generation.invalidate()
    try expect(generation.permits(becameKey, eligibility: ready))
    try expect(!generation.permits(first, eligibility: ready))

    for keyPath in [\HermesFocusEligibility.drawerOpen, \.hermesSelected, \.windowKey, \.windowVisible] {
        var invalid = ready
        invalid[keyPath: keyPath] = false
        try expect(!generation.permits(becameKey, eligibility: invalid))
    }
    for keyPath in [\HermesFocusEligibility.windowLocked, \.keyboardHandoff, \.inputDisabled, \.blockingUI] {
        var invalid = ready
        invalid[keyPath: keyPath] = true
        try expect(!generation.permits(becameKey, eligibility: invalid))
    }
    // A completed generation or previous drawer must not take focus after Settings, a tab switch or close.
    generation.invalidate()
    try expect(!generation.permits(becameKey, eligibility: ready))
    let reopened = generation.invalidate()
    try expect(generation.permits(reopened, eligibility: ready))
    generation.invalidate() // Focus lost or lock occurred while the queued work was waiting.
    try expect(!generation.permits(reopened, eligibility: ready))
}
