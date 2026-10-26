import Foundation
import IslandCore

private struct ClipboardPermissionFailure: Error { let detail: String }
private func permissionCheck(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
    if !condition() { throw ClipboardPermissionFailure(detail: detail) }
}

/// Authorization policy fixtures do not touch NSApplication, a real clipboard or TCC.
func runClipboardPermissionChecks() throws {
    typealias Policy = ClipboardPermissionPolicy
    for state in [Policy.State.undetermined, .ask, .denied, .unavailable] {
        try permissionCheck(Policy.decision(state: state, requestedBefore: false, trigger: .background) == .skip,
                            "background/launch checks never prompt for missing permissions")
    }
    try permissionCheck(Policy.decision(state: .authorized, requestedBefore: true, trigger: .user) == .proceed,
                        "already authorized user is not disturbed")
    try permissionCheck(Policy.decision(state: .undetermined, requestedBefore: false, trigger: .user) == .requestSystem,
                        "explicit first enable/paste requests the system permission")
    try permissionCheck(Policy.decision(state: .undetermined, requestedBefore: true, trigger: .user) == .showSettings,
                        "previously requested AX shows a clear settings action")
    try permissionCheck(Policy.decision(state: .denied, requestedBefore: false, trigger: .user) == .showSettings,
                        "denied read access shows settings instead of repeatedly probing clipboard data")
    for requestedBefore in [false, true] {
        try permissionCheck(Policy.decision(state: .ask, requestedBefore: requestedBefore, trigger: .user) == .requestSystem,
                            "ask always allows an explicit system request, including after the first read")
        try permissionCheck(Policy.decision(state: .ask, requestedBefore: requestedBefore, trigger: .background) == .skip,
                            "ask never triggers background permission prompts")
    }
    try permissionCheck(Policy.decision(state: .unavailable, requestedBefore: true, trigger: .user) == .showUnavailable,
                        "helper transport failure is distinct from a denied permission")
    try permissionCheck(Policy.mayPaste(wasAuthorized: true, requestedPermission: false), "already granted permissions can paste")
    try permissionCheck(!Policy.mayPaste(wasAuthorized: false, requestedPermission: true), "permission request never resumes a stale paste")
    try permissionCheck(!Policy.mayPaste(wasAuthorized: true, requestedPermission: true), "even newly granted permission requires a fresh user action")
    var gate = ClipboardPermissionRequestGate()
    let first = gate.begin()!
    try permissionCheck(gate.begin() == nil, "Settings and Drawer concurrent requests coalesce")
    gate.cancel()
    let replacement = gate.begin()!
    gate.finish(first)
    try permissionCheck(gate.contains(replacement), "old disabled/locked completion cannot finish a newer request")
    gate.finish(replacement)
    try permissionCheck(gate.begin() != nil, "completed request does not leave permission UI permanently busy")
    print("PASS clipboard permission policy: explicit requests, no background prompts, denied/settings, no stale paste and cancellation")
}
