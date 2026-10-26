// Only passive, deterministic dependencies are stubbed. Header, tabs, tab buttons, shape,
// page container, shell and hosting factory are compiled from production sources.
import AppKit
import SwiftUI

enum NotchViews: String, CaseIterable { case home, shelf, hermes, clipboard }
enum NotchState { case open, closed }
enum SneakContentType { case volume, brightness, battery, music, backlight, mic }
struct FixtureOSD {
    var type = SneakContentType.volume
    var value: Float = 0
    var icon = "speaker"
    var accent = Color.white
}
@MainActor final class BoringViewCoordinator: ObservableObject {
    static let shared = BoringViewCoordinator()
    @Published var currentView = NotchViews.home
    var selectedScreenUUID = "fixture"
    func selectTab(_ view: NotchViews) { currentView = view }
    func sneakPeekState(for _: String?) -> FixtureOSD { .init() }
    func shouldShowSneakPeek(on _: String?) -> Bool { false }
    func binding(for _: String?) -> Binding<FixtureOSD> { .constant(.init()) }
}
@MainActor final class BoringViewModel: ObservableObject {
    @Published var notchState = NotchState.open
    var hasNotch = true
    var closedNotchSize = CGSize(width: 185, height: 38)
    var screenUUID: String? = "fixture"
    func toggleCameraPreview() { fatalError("Fixture must not start a camera") }
}
@MainActor final class BatteryStatusViewModel: ObservableObject {
    static let shared = BatteryStatusViewModel()
    let isCharging = false, isInLowPowerMode = false, isPluggedIn = false
    let levelBattery = 92.0, maxCapacity = 100.0, timeToFullCharge = 0.0
    let timeToDischarge = 0.0, maxAdapterWatts = 0.0
}
@MainActor final class ShelfStateViewModel: ObservableObject { static let shared = ShelfStateViewModel() }
@MainActor final class HermesStore {
    static let shared = HermesStore()
    var capturesNotchDrops = false
}
@MainActor final class SettingsWindowController {
    static let shared = SettingsWindowController()
    func showWindow() { fatalError("Fixture must not open settings") }
}
func isOSDType(_: SneakContentType) -> Bool { false }
struct OpenNotchOSD: View {
    let type: Binding<SneakContentType>, value: Binding<Float>, icon: Binding<String>, accent: Binding<Color>
    var body: some View { Color.clear.frame(width: 30, height: 30) }
}
struct BoringBatteryView: View {
    let batteryWidth: CGFloat
    let isCharging: Bool, isInLowPowerMode: Bool, isPluggedIn: Bool
    let levelBattery: Double, maxCapacity: Double, timeToFullCharge: Double
    let timeToDischarge: Double, maxAdapterWatts: Double
    let isForNotification: Bool
    var body: some View { Text("92%  ▰").font(.caption).foregroundStyle(.white) }
}
extension NSScreen { static func screen(withUUID _: String) -> NSScreen? { main } }
