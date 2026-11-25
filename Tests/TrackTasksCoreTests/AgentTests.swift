import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct AgentTests {
    @Test func unknownCost() {
        var c = AgentCost()
        #expect(c.text() == nil)
        c.add(0.5)
        #expect(c.text() == "$0.50")
        c.add(nil)
        #expect(c.text(digits: 3) == "≥ $0.500")
        #expect(AgentCost(unknown: true).text() == "нет данных")
    }

    @Test func profiles() {
        var p = AgentProfiles()
        #expect(p.resolve("")?.agent == .claude)
        #expect(p.resolve("x") == nil)
        #expect(p.add(AgentProfile(id: "x", title: "x", agent: .claude, model: "opus")) == nil)
        #expect(p.add(AgentProfile(id: "x", title: "x", agent: .claude)) != nil)
        #expect(p.add(AgentProfile(id: "Плохо", title: "", agent: .claude)) != nil)
        #expect(p.add(AgentProfile(id: "claude", title: "", agent: .claude)) != nil)
        p.defaultID = "x"
        #expect(p.resolve("")?.model == "opus")
        p.remove("x")
        #expect(p.resolve("")?.id == "claude")
    }

    private let url = URL(fileURLWithPath: "/tmp/20261123-120000-a.md")

    @Test func taskAgentRoundTrip() {
        let text = "---\ntitle: \"A\"\nstatus: todo\npriority: medium\ncreated: 2026-11-23\ncompleted:\nagent: codex-fast  # свой\n---\n\nт\n"
        var t = Codec.task(from: text, url: url)
        #expect(t.agent == "codex-fast")
        #expect(t.problems.isEmpty)
        #expect(Codec.serialize(t, updating: text) == text)
        #expect(Codec.task(from: Codec.serialize(t), url: url).agent == "codex-fast")
        t.agent = ""
        #expect(!Codec.serialize(t, updating: text).contains("agent:"))
        #expect(!Codec.serialize(t).contains("agent:"))
    }

    @Test func malformedAgentIsReported() {
        let t = Codec.task(from: "---\nstatus: todo\nagent: a b\n---\n", url: url)
        #expect(t.problems.contains { $0.kind == .field("agent") })
    }

    /// The exact command lines of claude before the agent layer.
    @Test func claudeFlags() {
        let head = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        let ask = ["--permission-mode", "acceptEdits", "--permission-prompt-tool", "stdio"]
        #expect(ClaudeArgs.run(systemPrompt: "S", model: "", allowedTools: ["Read", "Edit"])
            == head + ask + ["--allowedTools", "Read,Edit", "--append-system-prompt", "S"])
        #expect(ClaudeArgs.run(systemPrompt: "S", model: "opus", allowedTools: ["Read"], bypassPermissions: true, resume: "id",
                               fork: true, resumeAt: "m", addDirs: ["/a", "/b"], isolated: true)
            == head + ["--dangerously-skip-permissions", "--allowedTools", "Read", "--append-system-prompt", "S", "--model", "opus",
                       "--resume", "id", "--fork-session", "--resume-session-at", "m", "--add-dir", "/a", "--add-dir", "/b"] + ClaudeArgs.isolation)
        #expect(ClaudeArgs.run(systemPrompt: "", model: "haiku", allowedTools: [], isolated: true, tools: [])
            == head + ask + ["--allowedTools", "", "--append-system-prompt", "", "--model", "haiku"] + ClaudeArgs.isolation + ["--tools", ""])
        #expect(ClaudeArgs.run(systemPrompt: "S", model: "sonnet", allowedTools: ["Read"], resume: "id")
            == head + ask + ["--allowedTools", "Read", "--append-system-prompt", "S", "--model", "sonnet", "--resume", "id"])
    }

    @Test func limitHoldsOnlyItsAgents() {
        let claude = QueuePlanner.Job(cwd: "/a"), other = QueuePlanner.Job(cwd: "/b", guardedLimit: false)
        let d = QueuePlanner.decide(jobs: [claude, other], settings: .init(limit: 3, hold: "лимит"))
        #expect(d[claude.id] == .wait(.limitHold("лимит")))
        #expect(d[other.id] == .start)
    }
}
