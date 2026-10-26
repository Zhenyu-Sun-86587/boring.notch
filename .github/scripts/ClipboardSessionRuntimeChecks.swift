// Run real Store/Presentation methods against passive app/workspace services and
// a private pasteboard. The settings notification is synthetic; its NSWindow stays
// hidden. No activation, general clipboard, AX inspection or input event is allowed.
import AppKit
import Combine
import IslandCore

@MainActor final class FixtureRunningApplication {
  static var apps: [Int32: FixtureRunningApplication] = [:]
  let processIdentifier: Int32
  var isTerminated = false
  var bundleIdentifier: String? = "fixture.external"
  init(pid: Int32) {
    processIdentifier = pid
    Self.apps[pid] = self
  }
  convenience init?(processIdentifier: Int32) {
    guard Self.apps[processIdentifier] != nil else { return nil }
    self.init(pid: processIdentifier)
  }
  func activate(from: FixtureRunningApplication, options: [Int]) -> Bool {
    FixtureWorkspace.shared.frontmostApplication = self
    FixtureWorkspace.shared.notificationCenter.post(
      name: FixtureWorkspace.didActivateApplicationNotification, object: nil,
      userInfo: [FixtureWorkspace.applicationUserInfoKey: self])
    return true
  }
  static var current: FixtureRunningApplication {
    apps[Int32(ProcessInfo.processInfo.processIdentifier)]!
  }
}
@MainActor final class FixtureWorkspace {
  static let shared = FixtureWorkspace()
  let notificationCenter = NotificationCenter()
  var frontmostApplication: FixtureRunningApplication?
  static let didActivateApplicationNotification = NSWorkspace.didActivateApplicationNotification
  static let didTerminateApplicationNotification = NSWorkspace.didTerminateApplicationNotification
  nonisolated static let applicationUserInfoKey = NSWorkspace.applicationUserInfoKey
}
@MainActor final class FixtureApplication {
  static let shared = FixtureApplication()
  var keyWindow: NSWindow?
  func yieldActivation(to: FixtureRunningApplication) {}
}
enum FixtureEvent {
  static var mouseLocation = CGPoint.zero
  static func addGlobalMonitorForEvents(
    matching: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void
  ) -> Any? { UUID() }
  static func addLocalMonitorForEvents(
    matching: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?
  ) -> Any? { UUID() }
}
enum NotchViews { case home, hermes, clipboard }
@MainActor final class BoringViewModel {
  var screenUUID: String? = "fixture"
  var didClose: (() -> Void)?
  var closes = 0
  func open(tab: NotchViews) { BoringViewCoordinator.shared.currentView = tab }
  func close() {
    closes += 1
    didClose?()
  }
}
@MainActor final class BoringViewCoordinator {
  static let shared = BoringViewCoordinator()
  var firstLaunch = false
  var currentView = NotchViews.clipboard
  func releaseKeyboard() {}
}
@MainActor final class NotchWindowManager {
  struct Context {
    let viewModel: BoringViewModel
    var window: NSWindow?
  }
  var isScreenLocked = false
  var contexts: [String: Context] = [:]
  var windows: [String: NSWindow] = [:]
  var viewModels: [String: BoringViewModel] = [:]
  let primaryViewModel = BoringViewModel()
  var primaryWindow: NSWindow?
}
class BoringNotchSkyLightWindow: NSPanel {
  var allowsIslandKeyboard = false
  var isIslandKeyboardHandoffActive = false
  func beginIslandKeyboardHandoff() -> UUID {
    isIslandKeyboardHandoffActive = true
    return UUID()
  }
  func endIslandKeyboardHandoff(_ token: UUID, restoreVisible: Bool) {
    isIslandKeyboardHandoffActive = false
  }
  func releaseIslandKeyboard() {}
}
@MainActor enum FixtureStore { static var shared: ClipboardStore! }
@MainActor final class ClipboardPermissionController {
  static let shared = ClipboardPermissionController()
  var failures: [ClipboardPasteResult] = []
  var duringProbe: (() -> Void)?
  var probesReturned = 0
  func cancelRequests() {}
  func requestOnEnable(
    readState: () -> ClipboardPermissionPolicy.State,
    requestRead: () -> ClipboardPermissionPolicy.State
  ) async { fatalError("No permission prompts") }

  func pasteAccessWithoutPrompt() async -> ClipboardPasteAccess? {
    duringProbe?()
    try? await Task.sleep(for: .milliseconds(20))
    probesReturned += 1
    return .init(
      accessibility: true, postEvents: true, processIdentifier: 22,
      bundleIdentifier: "fixture.helper")
  }
  func explainPasteFailure(_ result: ClipboardPasteResult) { failures.append(result) }
  func explainCopyFailure(_ text: String) {}
}
@MainActor final class XPCHelperClient {
  static let shared = XPCHelperClient()
  var pastes = 0
  var destinations: [Int32] = []
  func captureClipboardTarget(_ pid: Int32) async -> ClipboardPasteTarget? {
    .init(token: "fixture", processIdentifier: pid, hasWindow: true, hasElement: true)
  }
  func releaseClipboardTarget(_ token: String) {}
  func pasteClipboard(to pid: Int32, changeCount: Int, targetToken: String?, requestID: UUID) async
    -> ClipboardPasteResult
  {
    pastes += 1
    destinations.append(pid)
    return .posted
  }
}
extension NSScreen {
  var displayUUID: String? { "fixture" }
  static func screen(withUUID: String) -> NSScreen? { nil }
}
let openNotchSize = CGSize(width: 640, height: 190)
@main struct Checks {
  @MainActor static func main() async {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    _ = FixtureRunningApplication(pid: Int32(ProcessInfo.processInfo.processIdentifier))
    let target = FixtureRunningApplication(pid: 100)
    let other = FixtureRunningApplication(pid: 200)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let history = ClipboardHistory(directory: directory)
    let defaultsName = "fixture.combined." + UUID().uuidString
    let defaults = UserDefaults(suiteName: defaultsName)!
    let board = NSPasteboard.withUniqueName()
    defer {
      board.releaseGlobally()
      defaults.removePersistentDomain(forName: defaultsName)
      try? FileManager.default.removeItem(at: directory)
    }
    FixtureStore.shared = ClipboardStore(history: history, pasteboard: board, defaults: defaults)
    let payload = ClipboardPayload(items: [
      .init(representations: [.init(type: "public.utf8-plain-text", data: Data("fixture".utf8))])
    ])
    let record = try! await history.insert(
      payload, title: "fixture", searchableText: "fixture", kind: .text, sourceBundleID: nil,
      sourceName: nil
    ).first!
    let manager = NotchWindowManager()
    let presentation = ClipboardPresentation()
    presentation.configure(windowManager: manager)
    let owner = UUID()
    manager.primaryViewModel.didClose = {
      presentation.updateKeyboardTargetVisibility(owner: owner, visible: false)
      presentation.updateVisibility(owner: owner, screenUUID: "fixture", visible: false)
    }
    let settings = NSWindow(
      contentRect: NSRect(x: 20000, y: 20000, width: 100, height: 100), styleMask: [],
      backing: .buffered, defer: false)
    for mode in [
      "hover-after-settings", "keyboard", "hover", "hover-new-editor", "active-own-editor",
      "pending-own-editor",
    ] {
      FixtureWorkspace.shared.frontmostApplication = target
      BoringViewCoordinator.shared.currentView = .clipboard
      if mode == "hover-after-settings" {
        // A settings window became key and closed before this new clipboard lease.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
      }
      if mode == "hover-new-editor" {
        // Hermes had captured the previous editor; pointer entry must refresh it.
        BoringViewCoordinator.shared.currentView = .hermes
        presentation.updateKeyboardTargetVisibility(owner: owner, visible: true)
        await ready { presentation.keyboardTargetReady }
        FixtureWorkspace.shared.frontmostApplication = other
        FixtureWorkspace.shared.notificationCenter.post(
          name: FixtureWorkspace.didActivateApplicationNotification,
          object: nil, userInfo: [FixtureWorkspace.applicationUserInfoKey: other])
        BoringViewCoordinator.shared.currentView = .clipboard
      }
      if mode == "keyboard" { presentation.beginKeyboardSession(on: manager.primaryViewModel) }
      presentation.updateKeyboardTargetVisibility(owner: owner, visible: true)
      presentation.updateVisibility(owner: owner, screenUUID: "fixture", visible: true)
      await ready { presentation.keyboardTargetReady }
      if mode == "active-own-editor" {
        // The same event DURING a lease must still invalidate the destination.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
      }
      let prior = XPCHelperClient.shared.pastes
      let replies = ClipboardPermissionController.shared.failures.count
      let probes = ClipboardPermissionController.shared.probesReturned
      let session = FixtureStore.shared.sessionID
      if mode == "pending-own-editor" {
        ClipboardPermissionController.shared.duringProbe = {
          NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
        }
      }
      FixtureStore.shared.copy(record, paste: true)
      if mode == "pending-own-editor" {
        await ready { ClipboardPermissionController.shared.probesReturned > probes }
        ClipboardPermissionController.shared.duringProbe = nil
      } else {
        await ready { ClipboardPermissionController.shared.failures.count > replies }
      }
      await Task.yield()
      let cancelled = mode == "active-own-editor" || mode == "pending-own-editor"
      require(
        XPCHelperClient.shared.pastes - prior == (cancelled ? 0 : 1),
        "\(mode): wrong helper submission count")
      if mode == "pending-own-editor" {
        require(
          ClipboardPermissionController.shared.failures.count == replies,
          "\(mode): superseded action produced late feedback")
      } else {
        require(
          ClipboardPermissionController.shared.failures.last
            == (cancelled ? .focusChanged : .posted),
          "\(mode): incorrect completion")
      }
      if !cancelled {
        require(
          XPCHelperClient.shared.destinations.last == (mode == "hover-new-editor" ? 200 : 100),
          "\(mode): stale editor was retained")
      }
      require(board.string(forType: .string) == "fixture", "\(mode): fallback payload missing")
      require(
        FixtureStore.shared.sessionID != session && !FixtureStore.shared.keyboardSessionActive,
        "\(mode): drawer session was not closed")
      print(
        "PASS runtime clipboard session:", mode, "submissions",
        XPCHelperClient.shared.pastes - prior)
    }
    print(
      "PASS production Store+Presentation runtime: fresh pointer/keyboard destinations, settings re-entry, stale Hermes editor refresh, active own-editor cancellation, copy-first fallback and unified close; passive OS adapters only"
    )

  }
}

actor ClipboardThumbnailRenderer {
  static let shared = ClipboardThumbnailRenderer()
  func render(history: ClipboardHistory, id: String) async -> Data? { fatalError("No thumbnail") }
}

@MainActor private func require(_ condition: Bool, _ message: String) {
  if !condition {
    print("FAIL runtime clipboard:", message)
    exit(2)
  }
}
@MainActor private func ready(_ condition: () -> Bool) async {
  let deadline = ProcessInfo.processInfo.systemUptime + 3
  while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
    try? await Task.sleep(for: .milliseconds(5))
  }
  require(condition(), "asynchronous operation exceeded fixture deadline")
}
