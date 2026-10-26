import Foundation
import IslandCore

func hermesHeaderConfigurationChecks() throws {
    let endpoint = URL(string: "https://hermes.example.test/v1/chat/completions")!
    let fixtureSecret = "fixture-secret-not-a-credential"
    let extra = [HermesHeader(name: "X-Gateway-Route", value: "fixture"), HermesHeader(name: "X-Optional", value: "")]
    let configuration = HermesConfiguration(endpoint: endpoint, model: "fixture-model", apiKey: "fixture-api",
        accessClientID: "fixture-client", accessClientSecret: fixtureSecret, extraHeaders: extra)
    let request = try HermesClient.makeRequest(configuration: configuration,
        messages: [ChatMessage(role: "user", parts: [.text("fixture"), .image("data:image/png;base64,AA==")])])
    try expect(request.url == endpoint && request.httpMethod == "POST")
    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-api")
    try expect(request.value(forHTTPHeaderField: "cf-access-client-id") == "fixture-client")
    try expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == fixtureSecret)
    try expect(request.value(forHTTPHeaderField: "X-Gateway-Route") == "fixture")
    try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    try expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    try expect(body["model"] as? String == "fixture-model" && body["stream"] as? Bool == true)
    try expect(String(decoding: request.httpBody!, as: UTF8.self).contains("image_url"))
    try expect(try JSONDecoder().decode([HermesHeader].self, from: JSONEncoder().encode(extra)) == extra)

    let blank = try HermesRequestHeaders.validated(apiKey: "", accessClientID: "", accessClientSecret: "", extra: [])
    try expect(blank.count == 2 && blank["Authorization"] == nil)
    let alternate = try HermesRequestHeaders.validated(apiKey: "", accessClientID: "", accessClientSecret: "",
        extra: [.init(name: "Authorization", value: "Basic fixture")])
    try expect(alternate["Authorization"] == "Basic fixture")

    for (client, secret) in [("id", ""), ("", "secret"), ("  ", "secret")] {
        try expectThrows { try HermesRequestHeaders.validated(apiKey: "", accessClientID: client,
            accessClientSecret: secret, extra: []) }
    }
    for invalid in ["bad\r\nInjected: x", "bad\n", "bad\0", "bad\u{2028}", "bad\tvalue"] {
        try expectThrows { try HermesRequestHeaders.validated(apiKey: invalid, accessClientID: "", accessClientSecret: "", extra: []) }
        try expectThrows { try HermesRequestHeaders.validated(apiKey: "", accessClientID: invalid, accessClientSecret: "secret", extra: []) }
        try expectThrows { try HermesRequestHeaders.validated(apiKey: "", accessClientID: "id", accessClientSecret: invalid, extra: []) }
        try expectThrows { try HermesRequestHeaders.validated(apiKey: "", accessClientID: "", accessClientSecret: "",
            extra: [.init(name: "X-Test", value: invalid)]) }
    }
    for name in ["", "X Test", "X-Test:", "X-Test\n", "非ASCII", " " + "X-Test"] {
        try expectThrows { try HermesRequestHeaders.validated(apiKey: "", accessClientID: "", accessClientSecret: "",
            extra: [.init(name: name, value: "fixture")]) }
    }
    try expectThrows { try HermesRequestHeaders.validated(apiKey: "", accessClientID: "", accessClientSecret: "",
        extra: [.init(name: "X-Test", value: "a"), .init(name: "x-test", value: "b")]) }
    for name in ["Host", "Content-Length", "Transfer-Encoding", "Connection", "Keep-Alive", "TE", "Accept",
                 "Content-Type", "CF-Access-Client-Id", "cf-access-client-secret"] {
        try expectThrows { try HermesRequestHeaders.validated(apiKey: "", accessClientID: "", accessClientSecret: "",
            extra: [.init(name: name, value: "fixture")]) }
    }
    try expectThrows { try HermesRequestHeaders.validated(apiKey: "fixture-api", accessClientID: "", accessClientSecret: "",
        extra: [.init(name: "authorization", value: "Basic fixture")]) }
    try expectThrows { try HermesRequestHeaders.validated(apiKey: "", accessClientID: "", accessClientSecret: "",
        extra: (0..<33).map { .init(name: "X-\($0)", value: "fixture") }) }
    try expectThrows { try HermesRequestHeaders.validated(apiKey: "", accessClientID: "", accessClientSecret: "",
        extra: [.init(name: "X-Too-Large", value: String(repeating: "x", count: 8_193))]) }
    try expectThrows { try HermesRequestHeaders.validated(apiKey: "", accessClientID: "", accessClientSecret: "",
        extra: (0..<5).map { .init(name: "X-\($0)", value: String(repeating: "x", count: 8_000)) }) }
    var capturedError: (any Error)?
    do {
        _ = try HermesRequestHeaders.validated(apiKey: "", accessClientID: "", accessClientSecret: "",
            extra: [.init(name: "Host", value: fixtureSecret)])
    } catch { capturedError = error }
    try expect(capturedError != nil)
    try expect(!(capturedError?.localizedDescription.contains(fixtureSecret) ?? true))
}
