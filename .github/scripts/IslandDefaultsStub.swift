// Deterministic passive preferences for the actual-component fixture. No UserDefaults access.
import SwiftUI

public enum Defaults {
    public struct Key<Value> {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
    public static subscript<Value>(_ key: Key<Value>) -> Value { key.value }
}
extension Defaults.Key where Value == Bool {
    public static var boringShelf: Self { Self(true) }
    public static var showOpenNotchOSD: Self { Self(false) }
    public static var showMirror: Self { Self(false) }
    public static var settingsIconInNotch: Self { Self(false) }
    public static var showBatteryIndicator: Self { Self(true) }
}
@propertyWrapper public struct Default<Value>: DynamicProperty {
    private let key: Defaults.Key<Value>
    public init(_ key: Defaults.Key<Value>) { self.key = key }
    public var wrappedValue: Value { key.value }
}
