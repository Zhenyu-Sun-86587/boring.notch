import Foundation
import IslandCore

func hermesSubmissionChecks() throws {
    var transcript = HermesTranscript()
    let first = UUID()
    let original = "第一问\n保留原文"
    let turn = try transcript.accept(request: first, prompt: original, user: original + "\n便签上下文")!
    try expect(transcript.turns.count == 1 && transcript.turns[0].prompt == original)
    try expect(transcript.turns[0].status == .thinking && transcript.turns[0].assistant.isEmpty)
    try expect(transcript.messages.isEmpty)
    try expect(try transcript.accept(request: UUID(), prompt: "重复提交", user: "重复提交") == nil)
    try expect(transcript.updateAnswer("部分回答", request: first))
    try expect(transcript.turns[0].status == .responding)
    try expect(transcript.finish(.failed("测试连接失败"), request: first))
    try expect(transcript.turns[0].prompt == original && transcript.turns[0].assistant == "部分回答")
    try expect(transcript.turns[0].canRetry && transcript.messages.isEmpty)

    let retry = UUID()
    try expect(try transcript.accept(request: retry, prompt: original, user: original + "\n新便签", retrying: turn) == turn)
    try expect(transcript.turns.count == 1 && transcript.turns[0].assistant.isEmpty)
    try expect(!transcript.updateAnswer("迟到的旧回答", request: first))
    try expect(!transcript.finish(.completed, request: first))
    try expect(transcript.updateAnswer("相同回答", request: retry))
    try expect(transcript.finish(.completed, request: retry))
    try expect(!transcript.finish(.completed, request: retry))
    try expect(transcript.turns.count == 1 && transcript.messages.count == 2)
    try expect(transcript.messages[0].parts[0].text == original + "\n新便签")
    try expect(transcript.messages[1].parts[0].text == "相同回答")
    try expect(try transcript.accept(request: UUID(), prompt: original, user: original, retrying: turn) == nil)

    let second = UUID()
    let secondTurn = try transcript.accept(request: second, prompt: "第二问", user: "第二问")!
    try expect(transcript.updateAnswer("相同回答", request: second))
    try expect(transcript.finish(.completed, request: second))
    try expect(transcript.turns.count == 2 && transcript.turns[0].id != secondTurn)
    try expect(transcript.messages.count == 4) // Equal replies belong to two distinct exchanges.

    let cancelled = UUID()
    _ = try transcript.accept(request: cancelled, prompt: "停止后保留问题", user: "停止后保留问题")
    try expect(transcript.updateAnswer("已收到的片段", request: cancelled))
    try expect(transcript.finish(.stopped, request: cancelled))
    try expect(transcript.turns.last?.prompt == "停止后保留问题")
    try expect(transcript.turns.last?.assistant == "已收到的片段" && transcript.messages.count == 4)
    try expect(!transcript.updateAnswer("停止后迟到", request: cancelled))
    let newer = UUID()
    _ = try transcript.accept(request: newer, prompt: "新问题", user: "新问题")
    try expect(transcript.turns.count == 4 && transcript.turns[2].canRetry)
    transcript.clear()
    try expect(transcript.turns.isEmpty && transcript.messages.isEmpty)
    try expect(!transcript.updateAnswer("清空后迟到", request: newer))
    try expect(!transcript.finish(.completed, request: newer))

    try expectThrows { try transcript.accept(request: UUID(), prompt: "超出预检限制", user: String(repeating: "x", count: 131_073)) }
    try expect(transcript.turns.isEmpty)
    for index in 0..<12 {
        let request = UUID()
        _ = try transcript.accept(request: request, prompt: "\(index)", user: "\(index)")
        _ = transcript.updateAnswer("回答", request: request)
        _ = transcript.finish(.completed, request: request)
    }
    try expect(transcript.turns.count == 5 && transcript.turns.first?.prompt == "7")
    try expect(transcript.messages.count == 10)
    try expect(transcript.messages.map(\.role) == Array(repeating: ["user", "assistant"], count: 5).flatMap { $0 })
    try expect(transcript.messages[0].parts[0].text == "7" && transcript.messages[8].parts[0].text == "11")
    let large = UUID()
    _ = try transcript.accept(request: large, prompt: "边界", user: String(repeating: "x", count: 131_072))
    _ = transcript.updateAnswer(String(repeating: "y", count: 131_072), request: large)
    _ = transcript.finish(.completed, request: large)
    try expect(transcript.turns.count == 1 && transcript.turns[0].prompt == "边界")
    try expect(transcript.messages.count == 2)
    print("PASS Hermes submission transcript: immediate user turn, partial failures, stable retry, stale callbacks, completed context and bounded history")
}
