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
        guard window.map({ process($0) == pid }) ?? true,
              input.map({ process($0) == pid }) ?? true else { return nil }
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

    /// Refuse another target window/control. Setting AXFocused only reasserts the captured
    /// element after native panel release; it does not navigate to a different editor.
    func restore(_ record: Record) -> Bool {
        guard originalTargetUnchanged(record) else { return false }
        if let window = record.window {
            if boolean(window, kAXMinimizedAttribute) == true { return false }
            // Only the already-matching captured window can be raised. This re-establishes
            // the editor's native key window after a nonactivating panel, even if AX kept
            // reporting the old field as focused while WindowServer focus belonged elsewhere.
            if AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .invalidUIElement { return false }
        }
        if let input = record.element {
            guard ClipboardFocusRestoration.mayRestore(sameWindow: windowReady(record),
                savedElementValid: !isInvalid(input), relation: relation(record)) else { return false }
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(input, kAXFocusedAttribute as CFString, &settable) == .success,
               settable.boolValue {
                let result = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if result == .invalidUIElement { return false }
            }
        }
        return originalTargetUnchanged(record)
    }

    func originalTargetUnchanged(_ record: Record) -> Bool {
        if let saved = record.window, let current = element(record.application, kAXFocusedWindowAttribute), !CFEqual(saved, current) { return false }
        if let saved = record.element, isInvalid(saved) { return false }
        return relation(record) != .differentControl
    }

    func canRestoreNow(_ record: Record) -> Bool { windowReady(record) }

    func inputReady(_ record: Record) -> Bool {
        guard record.element != nil else { return windowReady(record) }
        return ClipboardFocusRestoration.ready(sameWindow: windowReady(record), relation: relation(record),
            capturedElementFocused: record.element.flatMap { boolean($0, kAXFocusedAttribute) } == true)
    }
    private func windowReady(_ record: Record) -> Bool {
        guard let saved = record.window else { return true }
        guard let current = element(record.application, kAXFocusedWindowAttribute) else { return false }
        return CFEqual(saved, current)
    }
    private func relation(_ record: Record) -> ClipboardFocusRestoration.Relation {
        guard let saved = record.element else { return .original }
        guard let current = element(record.application, kAXFocusedUIElementAttribute) else { return .missing }
        if CFEqual(saved, current) { return .original }
        // Browsers can temporarily focus their WebArea/group when an app is reactivated.
        // Restore only a container that is actually an ancestor of the saved editor, never
        // another field/control in the same window. No value or text attribute is inspected.
        let containers = Set(["AXWebArea", "AXGroup", "AXScrollArea", "AXWindow", "AXApplication", "AXSplitGroup", "AXLayoutArea"])
        guard let role = string(current, kAXRoleAttribute), containers.contains(role) else { return .differentControl }
        return record.ancestors.contains(where: { CFEqual($0, current) }) ? .ancestorContainer : .differentControl
    }

    private func element(_ source: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, 0.08)
        return result
    }
    private func process(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
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
    private func isInvalid(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .invalidUIElement
    }
}
