import Foundation

/// Reported by the process that actually reads AX focus and synthesizes the shortcut.
/// A host-app AX check is insufficient for a non-sandboxed XPC helper.
struct ClipboardPasteAccess: Codable, Sendable, Equatable {
    let accessibility: Bool
    let postEvents: Bool
    let processIdentifier: Int32
    let bundleIdentifier: String
    var guiSessionAvailable: Bool? = nil
    var canPaste: Bool { accessibility && postEvents }
}

enum ClipboardPastePermission: String, Sendable { case accessibility, postEvents }

/// Only an opaque identifier crosses XPC. No input text, selection or window title is read.
struct ClipboardPasteTarget: Codable, Sendable, Equatable {
    let token: String
    let processIdentifier: Int32
    let hasWindow: Bool
    let hasElement: Bool
}
