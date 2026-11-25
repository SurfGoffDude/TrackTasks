import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct CodexRecordedTests {
    private func driver(_ access: AgentAccess = .coding, resume: String? = nil) -> Driver {
        Driver(AgentRequest(cwd: URL(fileURLWithPath: "/p"), prompt: "go", access: access, resume: resume,
                            addDirs: [URL(fileURLWithPath: "/main/tasks")]))
    }

    private func lines(_ s: String) -> [String] { s.split(separator: "\n").map(String.init) }

    /// Decisions sent, by request id.
    private func decisions(_ d: Driver) -> [Int: String] {
        var out: [Int: String] = [:]
        for s in d.sent {
            if let id = s["id"] as? Int, let x = (s["result"] as? [String: Any])?["decision"] as? String { out[id] = x }
        }
        return out
    }

    private func checkTurn(_ d: Driver) {
        #expect(d.finished)
        // Edits inside the worktree are answered at once, the three commands are asked.
        #expect(decisions(d) == [0: "accept", 1: "accept"])
        #expect(d.asked.map(\.title) == ["declined.txt'", "accepted.txt'", "/o/outside.txt'"].map { "/bin/zsh -lc 'touch \($0)" })
        let r = d.s.result
        #expect(r.gotResult && !r.failed && r.resultText == "fin" && r.sessionID == "id1" && r.model == "gpt-6.1-sol")
        // Two edits, three commands, the message.
        #expect(r.turns == 6)
        // Six requests of 100…600 tokens, 10 of each from the cache.
        #expect(r.totalInput == 2100 && r.cacheReadTokens == 60 && r.outputTokens == 42)
        #expect(d.events.last == .text("fin"))
    }

    @Test func turn() {
        var d = driver()
        for l in lines(CodexRecordings.turn) { d.feed(l) }
        checkTurn(d)
        for (p, (allow, id)) in zip(d.asked, [(false, 2), (true, 3), (true, 4)]) {
            d.take(d.s.respond(p.id, allow: allow))
            #expect(d.sent.last?["id"] as? Int == id)
            #expect(d.lastDecision == (allow ? "accept" : "decline"))
        }
    }

    @Test func turnInPieces() {
        var d = driver()
        let bytes = Array(CodexRecordings.turn.utf8) + [0x0A]
        for i in stride(from: 0, to: bytes.count, by: 97) { d.take(d.s.consume(Data(bytes[i..<min(i + 97, bytes.count)]))) }
        checkTurn(d)
    }

    /// The server repeats the usage of the previous turn first: it isn't counted.
    @Test func resume() {
        var d = driver(resume: "id1")
        for l in lines(CodexRecordings.resume) { d.feed(l) }
        let r = d.s.result
        #expect(d.params("thread/resume")?["threadId"] as? String == "id1")
        #expect(d.finished && r.gotResult && r.resultText == "again" && r.sessionID == "id1" && r.turns == 1)
        #expect(r.totalInput == 700 && r.cacheReadTokens == 10 && r.outputTokens == 7)
    }

    /// Read-only sandbox: a task file is accepted (and Codex wrote it), a command is asked.
    @Test func planning() {
        var d = driver(.planning)
        for l in lines(CodexRecordings.planning) { d.feed(l) }
        #expect(decisions(d) == [0: "accept"])
        #expect(d.asked.map(\.title) == ["/bin/zsh -lc 'echo hi > tasks/q.md'"])
        #expect(d.finished && d.s.result.gotResult)
        #expect(CodexRecordings.planning.contains(#""path":"/p/tasks/p.md","kind":{"type":"add"},"diff":"x\n"}],"status":"completed""#))
    }

    @Test func stop() {
        var d = driver()
        for l in lines(CodexRecordings.stop) {
            if l.contains("turn/completed") { #expect(d.s.interrupt() != nil) }
            d.feed(l)
        }
        let r = d.s.exited(code: 0)
        #expect(d.finished && r.stopped && !r.failed)
    }
}
