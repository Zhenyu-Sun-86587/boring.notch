import AppKit
import ApplicationServices

/// AX references stay in the helper and expire. No text/value/selection/title attributes are read.
@MainActor
final class ClipboardPasteTargets {
    struct Record {
        let descriptor: ClipboardPasteTarget
        let application: AXUIElement
        let window: AXUIElement?
        let element: AXUIElement?
        let ancestors: [AXUIElement]
        let expires: TimeInterval
    }
    private var records: [String: Record] = [:]

    func capture(_ pid: Int32) -> ClipboardPasteTarget? {
        expire()
        guard pid > 0, AXIsProcessTrusted(), NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        let window = element(application, kAXFocusedWindowAttribute)
        let input = element(application, kAXFocusedUIElementAttribute)
        // AX descendants may live in a browser's renderer process. Their references
        // came from this application, so equality with the app PID is not required.
        let descriptor = ClipboardPasteTarget(token: UUID().uuidString, processIdentifier: pid,
            hasWindow: window != nil, hasElement: input != nil)
        var ancestors: [AXUIElement] = []
        var parent = input.flatMap { element($0, kAXParentAttribute) }
        for _ in 0..<16 {
            guard let value = parent, !ancestors.contains(where: { CFEqual($0, value) }) else { break }
            ancestors.append(value)
            parent = element(value, kAXParentAttribute)
        }
        records[descriptor.token] = Record(descriptor: descriptor, application: application,
            // The live workspace owns the lease and releases it on close. The bounded fallback
            // expiry cleans up a lost client without expiring a normal long Hermes session.
            window: window, element: input, ancestors: ancestors, expires: ProcessInfo.processInfo.systemUptime + 12 * 3_600)
        if records.count > 8, let oldest = records.min(by: { $0.value.expires < $1.value.expires })?.key { records.removeValue(forKey: oldest) }
        return descriptor
    }

    func record(_ token: String?, pid: Int32) -> Record? {
        expire()
        guard let token, let record = records[token], record.descriptor.processIdentifier == pid else { return nil }
        return record
    }
    func release(_ token: String) { records.removeValue(forKey: token) }
    private func expire() {
        let now = ProcessInfo.processInfo.systemUptime
        records = records.filter { $0.value.expires > now }
    }

    /// References are optional enhancements, including after a token was captured.
    /// An AX failure cannot prove that the user selected another editor.
    func evidence(_ record: Record, restorationAvailable: Bool = true) -> ClipboardFocusRestoration.Evidence {
        let window: ClipboardFocusRestoration.Match
        if let saved = record.window, string(saved, kAXRoleAttribute) != nil,
           let current = element(record.application, kAXFocusedWindowAttribute),
           string(current, kAXRoleAttribute) != nil {
            window = CFEqual(saved, current) ? .matched : .conflict
        } else { window = .unknown }
        let savedAvailable = record.element.flatMap { string($0, kAXRoleAttribute) } != nil
        return .init(window: window, savedElementAvailable: savedAvailable,
            relation: savedAvailable ? relation(record) : .unavailable,
            capturedElementFocused: record.element.flatMap { boolean($0, kAXFocusedAttribute) } == true,
            restorationAvailable: restorationAvailable)
    }

    /// Restore only a confirmed matching window and a valid saved input. The return
    /// value describes AX availability, never whether the destination changed.
    func restore(_ record: Record, assessment: ClipboardFocusRestoration.Assessment) -> Bool {
        guard assessment.mayRestore, let window = record.window, let input = record.element,
              boolean(window, kAXMinimizedAttribute) != true else { return false }
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return false }
        if assessment.inputReady { return true }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(input, kAXFocusedAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    private func relation(_ record: Record) -> ClipboardFocusRestoration.Relation {
        guard let saved = record.element else { return .unavailable }
        guard let current = element(record.application, kAXFocusedUIElementAttribute) else { return .missing }
        return ClipboardFocusRestoration.relation(sameElement: CFEqual(saved, current),
            currentRole: string(current, kAXRoleAttribute),
            knownAncestor: record.ancestors.contains(where: { CFEqual($0, current) }))
    }

    private func element(_ source: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, 0.08)
        return result
    }
    private func boolean(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
