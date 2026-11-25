import Testing
@testable import TrackTasksCore

@Suite("ClaudeArgs")
struct ClaudeArgsTests {
    @Test func codeModeRefusal() {
        var r = AgentRunResult(sessionID: nil)
        r.isError = true
        r.stderr = "Failed to resume session: This session was started in Code Mode (experimental), which isn't available because for now it only works in the interactive terminal, so it can't be resumed here."
        #expect(r.failed && r.errorText == "Сессия Code Mode: продолжить её можно только в терминале")
        r.stderr = "boom"
        #expect(r.errorText == "boom")
    }

    @Test func headlessRunHasNoCodeMode() {
        #expect(!ClaudeArgs.run(systemPrompt: "", model: "", allowedTools: []).contains { $0.contains("CODE_MODE") })
    }

    @Test func permissions() {
        #expect(ClaudeArgs.permissions(bypass: true) == ["--dangerously-skip-permissions"])
        #expect(ClaudeArgs.permissions(bypass: false) == ["--permission-mode", "acceptEdits", "--permission-prompt-tool", "stdio"])
    }

    @Test func noToolsIsEmptyValue() {
        #expect(ClaudeArgs.tools([]) == ["--tools", ""])
    }

    @Test func toolsAreCommaSeparated() {
        #expect(ClaudeArgs.tools(["Read", "Grep"]) == ["--tools", "Read,Grep"])
    }

    @Test func isolationDisablesUserMCPAndSettings() {
        let a = ClaudeArgs.isolation
        #expect(a.contains("--strict-mcp-config"))
        #expect(a.firstIndex(of: "--mcp-config").map { a[$0 + 1] } == #"{"mcpServers":{}}"#)
        #expect(a.firstIndex(of: "--setting-sources").map { a[$0 + 1] } == "project,local")
    }
}

import Foundation
@testable import TrackTasksCore

@Suite struct SessionForkTests {
    private func info(_ id: String, cwd: String = "/p", prompt: String = "привет", started: Double = 100, updated: Double = 200) -> ClaudeSessionInfo {
        ClaudeSessionInfo(id: id, path: "/x/\(id).jsonl", cwd: cwd, title: "", firstPrompt: prompt,
                          started: Date(timeIntervalSince1970: started), updated: Date(timeIntervalSince1970: updated),
                          turns: 1, taskFile: nil)
    }

    @Test func resumeArgs() {
        #expect(ClaudeArgs.resume("abc", fork: false) == ["--resume", "abc"])
        #expect(ClaudeArgs.resume("abc", fork: true) == ["--resume", "abc", "--fork-session"])
    }

    @Test func matchesCopiedHistoryAfterClick() {
        let p = SessionFork.Pending(parent: "a", cwd: "/p", firstPrompt: "привет", at: Date(timeIntervalSince1970: 150))
        let all = [info("a"), info("b", started: 160, updated: 170), info("c", cwd: "/q", started: 160, updated: 170),
                   info("d", prompt: "другое", started: 160, updated: 170), info("e", started: 90, updated: 100)]
        #expect(SessionFork.match(p, in: all, taken: [])?.id == "b")
        #expect(SessionFork.match(p, in: all, taken: ["b"]) == nil)
    }
}
