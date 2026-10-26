import Foundation

public enum ClipboardPermissionPolicy {
    public enum State: Sendable, Equatable { case authorized, undetermined, ask, denied, unavailable }
    public enum Trigger: Sendable, Equatable { case user, background }
    public enum Decision: Sendable, Equatable { case proceed, requestSystem, showSettings, showUnavailable, skip }
    public static func decision(state: State, requestedBefore: Bool, trigger: Trigger) -> Decision {
        if state == .authorized { return .proceed }
        guard trigger == .user else { return .skip }
        switch state {
        case .authorized: return .proceed
        case .undetermined: return requestedBefore ? .showSettings : .requestSystem
        // Ask remains a system-prompt state after the first pasteboard request. It must not
        // become a silent Settings-only path when the user explicitly requests access again.
        case .ask: return .requestSystem
        case .denied: return .showSettings
        case .unavailable: return .showUnavailable
        }
    }
    public static func mayPaste(wasAuthorized: Bool, requestedPermission: Bool) -> Bool {
        wasAuthorized && !requestedPermission
    }
}

/// Disabling/locking invalidates both pending work and any late completion from a previous request.
public struct ClipboardPermissionRequestGate: Sendable {
    private var active: UUID?
    public init() {}
    public mutating func begin() -> UUID? {
        guard active == nil else { return nil }
        let token = UUID(); active = token; return token
    }
    public func contains(_ token: UUID) -> Bool { active == token }
    public mutating func finish(_ token: UUID) { if active == token { active = nil } }
    public mutating func cancel() { active = nil }
}
