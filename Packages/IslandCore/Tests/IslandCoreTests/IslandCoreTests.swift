import Foundation
import ImageIO
import UniformTypeIdentifiers
import IslandCore

func sseSurvivesEveryUTF8Boundary() throws {
    let input = Data(": heartbeat\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"你好🌙\"}}]}\r\n\r\ndata: [DONE]\n\n".utf8)
    for split in 0...input.count {
        var parser = SSEParser()
        let events = try parser.feed(input.prefix(split)) + parser.feed(input.dropFirst(split))
        try expect(events.count == 2)
        try expect(try HermesClient.delta(events[0]) == "你好🌙")
        try expect(events[1] == "[DONE]")
    }
}

func sseMultilineAndLimits() throws {
    var parser = SSEParser()
    try expect(try parser.feed(Data("event: message\ndata: first\ndata: second\n\n".utf8)) == ["first\nsecond"])
    try expectThrows { try parser.feed(Data(repeating: 65, count: 262_145)) }
    try expectThrows { try HermesClient.delta("{\"error\":{\"message\":\"bad model\"}}") }
}

func conversationEvictsWholeTurns() throws {
    var conversation = Conversation()
    for index in 0..<12 { conversation.append(user: "\(index)", assistant: "reply") }
    try expect(conversation.turns.count == 8)
    try expect(conversation.turns.first?.user == "4")
    conversation.append(user: "large", assistant: String(repeating: "x", count: 262_145))
    try expect(conversation.turns.isEmpty)
    try expect(Conversation.needsWideLayout("| A | B |\n|---|---|"))
    try expect(!Conversation.needsWideLayout("short answer"))
}

func taskAppendPreservesBOMCRLFAndPrefix() throws {
    let before = Data("\u{feff}# Existing\r\n- [ ] Original".utf8)
    let result = try SurfaceFiles.appendingTask("New task\nDetails", to: before)
    try expect(result.starts(with: before))
    try expect(String(decoding: result, as: UTF8.self).hasSuffix("\r\n- [ ] New task\r\n  Details\r\n"))
    try expect(SurfaceFiles.references(in: "use @TODAY and @inbox, email@example.com not@today") == ["Today.md", "Inbox.md"])
}

func coordinatedAppendOnlyTouchesFixture() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Today.md")
    try Data("# Original\n".utf8).write(to: file)
    try SurfaceFiles.appendTask("Saved\nsecond line", to: file)
    try expect(try SurfaceFiles.read(file) == "# Original\n- [ ] Saved\n  second line\n")
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<6 {
            group.addTask { try SurfaceFiles.appendTask("Concurrent \(index)", to: file) }
        }
        try await group.waitForAll()
    }
    let final = try SurfaceFiles.read(file)
    for index in 0..<6 { try expect(final.contains("- [ ] Concurrent \(index)\n")) }
}

actor FixtureTransport: HTTPTransport {
    var results: [HTTPResult]
    var requests: [URLRequest] = []
    init(_ results: [HTTPResult]) { self.results = results }
    func execute(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        guard !results.isEmpty else { throw IslandError.invalidResponse }
        return results.removeFirst()
    }
}

private func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResult {
    HTTPResult(data: Data(text.utf8), status: status, headers: headers)
}
private let taskJSON = "{\"id\":1,\"project_id\":2,\"title\":\"Task\",\"done\":false,\"due_date\":\"2026-10-26T10:00:00Z\",\"custom_field\":42}"
private func config() -> TodoConfiguration {
    TodoConfiguration(baseURL: URL(string: "https://todo.example.test")!, token: "fixture")
}

func todoPaginationDedupAndExclusion() async throws {
    let transport = FixtureTransport([
        json("{\"openapi\":\"3.1.0\"}"),
        json("{\"items\":[\(taskJSON)],\"total_pages\":2}"),
        json("{\"items\":[\(taskJSON),{\"id\":2,\"project_id\":3,\"title\":\"Projection\",\"done\":false}],\"total_pages\":2}")
    ])
    let tasks = try await VikunjaClient(configuration: config(), transport: transport).tasks()
    try expect(tasks.count == 1)
    try expect(tasks[0].due != nil)
    try expect(await transport.requests.count == 3)
    let requestURL = await transport.requests[1].url!
    try expect(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "filter" })?.value == "project != 3")
}

func todoV2UsesConditionalPatch() async throws {
    let transport = FixtureTransport([json("{\"openapi\":\"3.1.0\"}"), json(taskJSON, headers: ["ETag": "revision-1"]), json(taskJSON)])
    try await VikunjaClient(configuration: config(), transport: transport).setCompleted(taskID: 1, completed: true)
    let request = await transport.requests.last!
    try expect(request.httpMethod == "PATCH")
    try expect(request.value(forHTTPHeaderField: "If-Match") == "revision-1")
    try expect(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Bool] == ["done": true])
}

func todoV1PreservesUnknownFields() async throws {
    let transport = FixtureTransport([json("", status: 404), json(taskJSON), json(taskJSON)])
    try await VikunjaClient(configuration: config(), transport: transport).setCompleted(taskID: 1, completed: true)
    let request = await transport.requests.last!
    let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    try expect(request.httpMethod == "POST")
    try expect(payload["custom_field"] as? Int == 42)
}

func todoNeverWritesExcludedProjectOrFallsBackOnAuth() async throws {
    let excluded = taskJSON.replacingOccurrences(of: "\"project_id\":2", with: "\"project_id\":3")
    let transport = FixtureTransport([json("{\"openapi\":\"3.1.0\"}"), json(excluded)])
    try await expectThrowsAsync {
        try await VikunjaClient(configuration: config(), transport: transport).setCompleted(taskID: 1, completed: true)
    }
    try expect(await transport.requests.count == 2)
    let auth = FixtureTransport([json("", status: 302)])
    try await expectThrowsAsync {
        try await VikunjaClient(configuration: config(), transport: auth).tasks()
    }
    try expect(await auth.requests.count == 1)
}

func imageIsDownsampledBeforeEncoding() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: url) }
    let context = CGContext(data: nil, width: 2_000, height: 1_000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    try expect(CGImageDestinationFinalize(destination))
    let jpeg = try AttachmentImage.jpeg(at: url, maxPixelSize: 160)
    let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
    try expect(properties[kCGImagePropertyPixelWidth] as? Int == 160)
    try expect(properties[kCGImagePropertyPixelHeight] as? Int == 80)
}

struct CheckFailure: Error { let message: String }
func expect(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    guard condition else { throw CheckFailure(message: "Failed at \(file):\(line)") }
}
func expectThrows<T>(_ body: () throws -> T) throws {
    do { _ = try body() } catch { return }
    throw CheckFailure(message: "Expected an error")
}
func expectThrowsAsync<T>(_ body: () async throws -> T) async throws {
    do { _ = try await body() } catch { return }
    throw CheckFailure(message: "Expected an async error")
}
@main enum CoreChecks {
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--sse" {
            try await checkStreaming(endpoint: URL(string: CommandLine.arguments[2])!)
            return
        }
        try sseSurvivesEveryUTF8Boundary()
        try sseMultilineAndLimits()
        try conversationEvictsWholeTurns()
        try taskAppendPreservesBOMCRLFAndPrefix()
        try await coordinatedAppendOnlyTouchesFixture()
        try await todoPaginationDedupAndExclusion()
        try await todoV2UsesConditionalPatch()
        try await todoV1PreservesUnknownFields()
        try await todoNeverWritesExcludedProjectOrFallsBackOnAuth()
        try imageIsDownsampledBeforeEncoding()
        print("PASS: 10 IslandCore checks (UTF-8 boundaries, SSE limits, FIFO, file preservation, atomic append, pagination, conditional update, v1 merge, exclusions/auth, ImageIO downsampling)")
    }
}

actor ReceivedText {
    var value = ""
    func append(_ text: String) { value += text }
}

func checkStreaming(endpoint: URL) async throws {
    let client = HermesClient()
    let received = ReceivedText()
    try await client.stream(configuration: HermesConfiguration(endpoint: endpoint, model: "fixture"),
                            messages: [ChatMessage(role: "user", text: "fixture")]) { delta in
        await received.append(delta)
    }
    try expect(await received.value == "你好🌙")
    let task = Task {
        try await client.stream(configuration: HermesConfiguration(endpoint: endpoint.appendingPathComponent("slow"), model: "fixture"),
                                messages: [ChatMessage(role: "user", text: "cancel")]) { _ in }
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    try await expectThrowsAsync { try await task.value }
    print("PASS: URLSession.bytes SSE completion and cancellation against localhost fixture")
}
