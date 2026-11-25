import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

@MainActor @Suite("Вызовы инструментов в потоке claude")
struct ClaudeStreamToolTests {
    private final class Seen {
        var calls: [(ChatToolCall, String)] = []
        var results: [(id: String, text: String, failed: Bool)] = []
        var contexts: [ClaudeContext] = []
        var events: [AgentEvent] = []
    }

    private func read(_ lines: [String]) -> (Seen, ClaudeStream) {
        let seen = Seen(), s = ClaudeStream(cwd: "/p")
        s.onEvent = { seen.events.append($0) }
        s.onContext = { seen.contexts.append($0) }
        s.onTool = {
            switch $0 {
            case .started(let c, let t): seen.calls.append((c, t))
            case .finished(let id, let r, let f): seen.results.append((id, r, f))
            }
        }
        s.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        return (seen, s)
    }

    private func use(_ name: String, _ input: String, parent: String = "null") -> String {
        #"{"type":"assistant","uuid":"u1","parent_tool_use_id":\#(parent),"message":{"model":"m","usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":30,"output_tokens":99},"content":[{"type":"tool_use","id":"t1","name":"\#(name)","input":\#(input)}]}}"#
    }

    private func result(_ content: String, error: String = "false") -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":\#(content),"is_error":\#(error)}]}}"#
    }

    @Test func callAndResult() {
        let (seen, _) = read([use("Bash", #"{"command":"ls -la"}"#), result(#""a\nb""#)])
        #expect(seen.calls.count == 1 && seen.calls[0].0 == ChatToolCall(id: "t1", name: "Bash", detail: "ls -la"))
        #expect(seen.calls[0].1 == "$ ls -la")
        #expect(seen.results.count == 1 && seen.results[0] == ("t1", "a\nb", false))
        // The queue's log keeps its line.
        #expect(seen.events == [.tool("$ ls -la")])
    }

    @Test func errorAndBlocks() {
        let (seen, _) = read([result(#"[{"type":"text","text":"нет"},{"type":"image","source":{}}]"#, error: "true"), result("null")])
        #expect(seen.results[0] == ("t1", "нет\n[изображение]", true))
        #expect(seen.results[1].text.isEmpty)
    }

    @Test func subagentKeepsParentAndNotContext() {
        let (seen, s) = read([use("Read", #"{"file_path":"/p/a.md"}"#, parent: #""task1""#)])
        #expect(seen.calls[0].0.parent == "task1" && seen.calls[0].1 == "Читает a.md")
        #expect(seen.contexts.isEmpty && s.point == nil)
    }

    @Test func editShowsFragment() {
        let (seen, _) = read([use("Edit", #"{"file_path":"/p/a.md","old_string":"x","new_string":"y\nz"}"#)])
        #expect(seen.calls[0].0.detail == "/p/a.md\n\n- x\n+ y\n+ z")
    }

    @Test func longResultIsCutAndKeysRemoved() {
        let key = "ghp_" + String(repeating: "a", count: 36)
        let text = "key " + key + " " + String(repeating: "я", count: 20_000)
        let (seen, _) = read([result("\"\(text)\"")])
        let r = seen.results[0].text
        #expect(!r.contains(key) && r.contains(Redactor.mark))
        #expect(r.count < ChatToolCall.resultLimit + 50 && r.hasSuffix("обрезано"))
        // A key across the cut.
        let edge = String(repeating: "я ", count: ChatToolCall.resultLimit / 2 - 10) + key
        #expect(!read([result("\"\(edge)\"")]).0.results[0].text.contains("ghp_"))
    }

    @Test func contextFromLastMessageAndWindow() {
        let (seen, s) = read([use("Read", "{}"),
                              #"{"type":"result","usage":{"input_tokens":5000},"modelUsage":{"m":{"contextWindow":200},"other":{"contextWindow":1}}}"#])
        #expect(seen.contexts == [ClaudeContext(tokens: 42, window: nil), ClaudeContext(tokens: 42, window: 200)])
        #expect(s.point == "u1")
    }
}
