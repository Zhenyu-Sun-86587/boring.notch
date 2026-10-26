// Passive preferences used only while typechecking clipboard presentation.
public enum FixtureDisplayMode { case allDisplays, primary }
public enum Defaults {
    public struct Key<Value> { let value: Value; public init(_ value: Value) { self.value = value } }
    public static subscript<Value>(_ key: Key<Value>) -> Value { key.value }
}
extension Defaults.Key where Value == FixtureDisplayMode {
    public static var displayMode: Self { Self(.primary) }
}
