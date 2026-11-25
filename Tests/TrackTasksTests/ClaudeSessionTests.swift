import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// The chat with a stand-in for claude and its own history folder.
@MainActor @Suite("Чат", .serialized)
struct ClaudeSessionTests {
    /// Answers with session `s<n>` and message `u<n>`; a prompt with «hang» waits until stopped, «fail» fails.
    private static let script = #"""
    #!/bin/sh
    d=$(dirname "$0")
    n=$(($(cat "$d/count" 2>/dev/null || echo 0) + 1))
    echo $n > "$d/count"
    read init; read prompt
    echo "$*" | tr '\n' ' ' >> "$d/args"; echo >> "$d/args"
    printf '%s\n' "$prompt" >> "$d/prompts"
    echo '{"type":"system","subtype":"init","session_id":"s'$n'","model":"m"}'
    case "$prompt" in
      *hang*)
        echo '{"type":"assistant","session_id":"s'$n'","message":{"model":"m","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"x"}}]}}'
        exec sleep 60 ;;
      *perm*)
        echo '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm x"}}}'
        read answer; printf '%s\n' "$answer" >> "$d/answers" ;;
      *fail*)
        echo '{"type":"result","session_id":"s'$n'","is_error":true,"result":"сбой"}'; exit 1 ;;
    esac
    echo '{"type":"assistant","session_id":"s'$n'","uuid":"u'$n'","message":{"model":"m","content":[{"type":"text","text":"ответ '$n'"}]}}'
    echo '{"type":"result","session_id":"s'$n'","is_error":false,"result":"ok"}'
    """#

    @MainActor private struct Env {
        let dir: URL
        func make() -> ClaudeSession {
            let d = dir
            return ClaudeSession(cwd: d, title: "тест", systemPrompt: "x", historyRoot: d.appendingPathComponent("chats"),
                                 executable: d.appendingPathComponent("claude").path) {
                let p = ClaudeProcess()
                p.sessions = AppSessions(url: d.appendingPathComponent("a.json"))
                p.chatSessions = AppSessions(url: d.appendingPathComponent("c.json"))
                return p
            }
        }
        func lines(_ name: String) -> [String] {
            ((try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
    }

    private func env() throws -> Env {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tt-chat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent("claude")
        try Self.script.write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        return Env(dir: d)
    }

    private func wait(_ what: String = "", _ done: () -> Bool) async throws {
        for _ in 0..<1000 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done(), "не дождались: \(what)")
    }

    private func texts(_ s: ClaudeSession, _ role: ClaudeSession.Role) -> [String] {
        s.messages.filter { $0.role == role }.map(\.text)
    }

    @Test func queueGoesOneByOne() async throws {
        let e = try env(), s = e.make()
        s.submit("как один")
        s.submit("как два")
        s.submit("как три")
        s.submit("как лишнее")
        #expect(s.queue.count == 3 && s.isBusy)
        s.unqueue(s.queue[2].id)
        try await wait("очередь") { !s.isBusy }
        #expect(texts(s, .user) == ["как один", "как два", "как три"])
        #expect(texts(s, .assistant) == ["ответ 1", "ответ 2", "ответ 3"])
    }

    @Test func stopHoldsQueueAndInterruptsTools() async throws {
        let e = try env(), s = e.make()
        s.submit("как hang")
        s.submit("как дальше")
        try await wait("вызов") { s.messages.contains { $0.tool != nil } }
        s.stop()
        try await wait("остановка") { !s.isRunning }
        #expect(s.queue.count == 1 && texts(s, .info).contains("Остановлено"))
        #expect(s.messages.compactMap(\.tool).map(\.state) == [.interrupted])
        s.sendQueued()
        try await wait("очередь") { !s.isBusy }
        #expect(texts(s, .assistant) == ["ответ 2"])
    }

    @Test func errorHoldsQueue() async throws {
        let e = try env(), s = e.make()
        s.submit("как fail")
        s.submit("как дальше")
        try await wait("ошибка") { !s.isRunning }
        #expect(s.queue.count == 1 && !texts(s, .error).isEmpty)
    }

    @Test func queuedRequestAsksAboutTask() async throws {
        guard ClaudeSession.asksBeforeTask else { return }
        let e = try env(), s = e.make()
        s.submit("как дела")
        s.submit("добавь тест")
        s.submit("как потом")
        try await wait("плашка") { s.pending != nil }
        #expect(s.pending?.text == "добавь тест" && s.queue.count == 1 && !s.isRunning)
        s.cancelPending()
        #expect(s.input == "добавь тест" && s.queue.count == 1)
    }

    @Test func lateExitStaysInItsChat() async throws {
        let e = try env(), s = e.make()
        s.submit("как hang")
        s.submit("как в очереди")
        try await wait("вызов") { s.messages.contains { $0.tool != nil } }
        let old = s.chatID
        s.input = "черновик"
        s.reset()
        #expect(s.messages.isEmpty && !s.isRunning && s.isBusy && s.queue.isEmpty)
        #expect(s.input == "как в очереди\nчерновик")
        try await wait("выход") { !s.isBusy }
        #expect(s.messages.isEmpty && s.sessionID == nil)
        let saved = ChatHistory.list(cwd: e.dir, in: e.dir.appendingPathComponent("chats"))
        #expect(saved.map(\.id) == [old] && saved[0].sessionID == "s1")
        #expect(saved[0].messages.compactMap(\.tool).map(\.state) == [.interrupted])
    }

    @Test func repeatBranchesFromThePreviousTurn() async throws {
        let e = try env(), s = e.make()
        s.submit("как один")
        try await wait("1") { !s.isRunning }
        s.send("длинный промпт", display: "Что сделано?", model: .haiku)
        try await wait("2") { !s.isRunning }
        let old = s.chatID
        s.repeatLast()
        try await wait("3") { !s.isRunning }
        let args = e.lines("args")
        #expect(args.count == 3)
        #expect(args[2].contains("--resume s1 --fork-session --resume-session-at u1") && args[2].contains("--model haiku"))
        #expect(e.lines("prompts")[2].contains("длинный промпт"))
        #expect(s.chatID != old && s.history.contains { $0.id == old })
        #expect(texts(s, .user) == ["как один", "Что сделано?"])
        #expect(texts(s, .assistant) == ["ответ 1", "ответ 3"])
        // The branch goes on in its own session.
        s.submit("как дальше")
        try await wait("4") { !s.isRunning }
        #expect(e.lines("args")[3].contains("--resume s3") && !e.lines("args")[3].contains("--fork-session"))
    }

    @Test func editOfTheFirstRequestStartsOver() async throws {
        let e = try env(), s = e.make()
        s.submit("как один")
        try await wait("1") { !s.isRunning }
        s.input = "черновик"
        s.editLast()
        #expect(s.input == "как один" && s.editing != nil)
        s.cancelEditing()
        #expect(s.input == "черновик" && s.editing == nil)
        s.editLast()
        s.input = ""
        s.submit("как два")
        #expect(s.input == "черновик")
        try await wait("2") { !s.isRunning }
        #expect(texts(s, .user) == ["как два"] && !e.lines("args")[1].contains("--resume"))
        #expect(s.history.count == 2)
    }

    @Test func restartKeepsPoint() async throws {
        let e = try env(), s = e.make()
        s.submit("как один")
        try await wait("1") { !s.isRunning }
        let again = e.make()
        again.submit("как два")
        try await wait("2") { !again.isRunning }
        again.repeatLast()
        try await wait("3") { !again.isRunning }
        #expect(e.lines("args")[2].contains("--resume s1 --fork-session --resume-session-at u1"))
    }

    @Test func oldChatIsReadAndRepeatsAsNewMessage() async throws {
        let e = try env()
        let root = e.dir.appendingPathComponent("chats"), folder = ChatHistory.dir(for: e.dir, in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        try Data(#"""
        {"id":"\#(id)","title":"т","created":"2026-11-01T10:00:00Z","updated":"2026-11-01T10:00:00Z","sessionID":"old","totalCost":0,
         "messages":[{"id":"\#(UUID())","role":"user","text":"как было"},{"id":"\#(UUID())","role":"tool","text":"Читает a"}]}
        """#.utf8).write(to: folder.appendingPathComponent("\(id.uuidString).json"))
        let s = e.make()
        #expect(s.chatID == id && s.messages.count == 2)
        s.repeatLast()
        try await wait("повтор") { !s.isRunning }
        #expect(s.chatID == id && texts(s, .user) == ["как было", "как было"])
        #expect(e.lines("args")[0].contains("--resume old") && !e.lines("args")[0].contains("--fork-session"))
    }

    @Test func oldResultsAreNotSaved() {
        func m(_ n: Int) -> ClaudeSession.Message {
            .init(role: .tool, text: "", tool: ChatToolCall(id: "\(n)", name: "Read", detail: "", result: String(repeating: "x", count: 60)))
        }
        let out = ClaudeSession.trimmed([m(1), m(2)], limit: 100)
        #expect(out[0].tool?.result?.contains("не сохранён") == true && out[1].tool?.result?.count == 60)
    }

    @Test func permissionIsAskedAndAnswered() async throws {
        let e = try env(), s = e.make()
        for allow in [true, false] {
            s.submit("как perm")
            try await wait("запрос") { !s.permissions.isEmpty }
            #expect(s.permissions[0].title == "rm x")
            s.answer(s.permissions[0], allow: allow)
            try await wait("ответ") { !s.isRunning }
            #expect(s.permissions.isEmpty)
        }
        #expect(texts(s, .tool) == ["Разрешено: rm x", "Отклонено: rm x"])
        #expect(e.lines("answers")[0].contains("\"allow\"") && e.lines("answers")[1].contains("\"deny\""))
    }

    @Test func historyReopensChat() async throws {
        let e = try env(), s = e.make()
        s.submit("как один")
        try await wait("1") { !s.isRunning }
        let first = s.chatID
        s.reset()
        s.submit("как два")
        try await wait("2") { !s.isRunning }
        #expect(!e.lines("args")[1].contains("--resume"))
        s.open(try #require(s.history.first { $0.id == first }))
        #expect(texts(s, .user) == ["как один"])
        s.submit("как три")
        try await wait("3") { !s.isRunning }
        #expect(e.lines("args")[2].contains("--resume s1"))
        s.deleteChat(first)
        #expect(s.messages.isEmpty && s.history.count == 1)
    }

    @Test func rightsAreTheSame() async throws {
        let e = try env(), s = e.make()
        s.submit("как @Sources/A.swift")
        try await wait("1") { !s.isRunning }
        let a = e.lines("args")[0]
        #expect(a.contains("--permission-mode acceptEdits --permission-prompt-tool stdio"))
        #expect(a.contains("--allowedTools " + ClaudeTools.planning.joined(separator: ",")) && !a.contains("--add-dir"))
    }
}

@Suite("Файлы чата")
struct ChatFilesTests {
    @Test func walkSkipsHeavyFolders() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tt-files-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: d) }
        for p in ["a/deep/x.txt", "node_modules/m.js", ".git/config", ".build/o", "b/y.txt", "z.txt"] {
            let u = d.appendingPathComponent(p)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: u)
        }
        #expect(ChatFiles.walk(d, limit: 100) == ["z.txt", "b/y.txt", "a/deep/x.txt"])
        #expect(ChatFiles.walk(d, limit: 1) == ["z.txt"])
    }
}
