import AppKit
import SwiftUI

@MainActor
enum HermesLayout {
    static func size(screenUUID: String?, wide: Bool) -> CGSize {
        let screen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
        let key = wide ? "island.hermesWideWidth" : "island.hermesWidth"
        let stored = UserDefaults.standard.double(forKey: key)
        let requested = stored.isFinite && stored >= 480 ? min(stored, 1_920) : (wide ? 920 : 640)
        let minimumWidth: Double = (screen?.safeAreaInsets.top ?? 0) > 0 ? 640 : 480
        return CGSize(width: min(max(requested, minimumWidth), max(320, frame.width - 32)),
                      height: min(wide ? 520 : 420, max(240, frame.height - 80)))
    }
}

/// Keep the host panel centered over its own display; only the pointer's Hermes panel may take keys.
struct IslandWindowBridge: NSViewRepresentable {
    let size: CGSize
    let wantsKeyboard: Bool
    var permitsKeyboardWithoutHover = false
    final class Anchor: NSView {
        var apply: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { apply?(window) } }
    }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.apply = { window in
            guard let screen = window.screen else { return }
            let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                               width: size.width, height: size.height)
            if window.frame != frame { window.setFrame(frame, display: true) }
            if let panel = window as? BoringNotchSkyLightWindow {
                let shouldFocus = wantsKeyboard && (permitsKeyboardWithoutHover || frame.contains(NSEvent.mouseLocation)) && !panel.isIslandScreenLocked
                let previouslyOwnedFocus = panel.allowsIslandKeyboard
                panel.allowsIslandKeyboard = shouldFocus
                if shouldFocus && !panel.isKeyWindow { panel.makeKey() }
                else if previouslyOwnedFocus && !shouldFocus && panel.isKeyWindow && !panel.wantsKeyForTextInput { panel.resignKey() }
            }
        }
        if let window = view.window { view.apply?(window) }
    }
}
