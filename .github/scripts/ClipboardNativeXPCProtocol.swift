import Foundation

@objc(ClipboardNativeFixtureProtocol) protocol ClipboardNativeFixtureProtocol {
    func access(with reply: @escaping (Data) -> Void)
    func validateGuards(with reply: @escaping (Bool) -> Void)
    func postFixture(_ marker: Int64, with reply: @escaping (Bool) -> Void)
}
