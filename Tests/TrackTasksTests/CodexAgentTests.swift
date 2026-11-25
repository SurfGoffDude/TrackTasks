import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// The adapter with a stand-in script instead of codex, and the queue's rules for it.
@MainActor @Suite(.serialized) struct CodexAgentTests {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private final class Turn { var started = false }

    private func run(_ body: String, stopAfter: Duration? = nil, turn: Turn = Turn()) async throws -> AgentRunResult {
        let script = dir.appendingPathComponent("codex")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let p = CodexProcess()
        var result: AgentRunResult?
        p.onExit = { result = $0 }
        p.onTurnStarted = { turn.started = true }
        try p.start(AgentRequest(cwd: dir, prompt: String(repeating: "ы", count: 200_000), access: .coding), executable: script.path)
        if let stopAfter { try await Task.sleep(for: stopAfter); p.stop() }
        for _ in 0..<1000 where result == nil { try await Task.sleep(for: .milliseconds(20)) }
        return try #require(result)
    }

    private let start = """
    read l; echo '{"id":1,"result":{"userAgent":"t/0.162.0 (x)"}}'
    read l; read l; echo '{"id":2,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}'
    read l; echo '{"id":3,"result":{"config":{}}}'
    read l; echo '{"id":4,"result":{"thread":{"id":"th1"},"model":"m","approvalPolicy":"untrusted","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"}}}'
    read l; echo '{"id":5,"result":{"turn":{"id":"tu1"}}}'

    """

    @Test func success() async throws {
        let turn = Turn()
        let r = try await run(start + """
        echo '{"method":"item/completed","params":{"threadId":"th1","item":{"type":"agentMessage","id":"m","text":"ok"}}}'
        echo '{"method":"turn/completed","params":{"threadId":"th1","turn":{"id":"tu1","status":"completed"}}}'
        cat >/dev/null
        """, turn: turn)
        #expect(turn.started)
        #expect(!r.failed && r.gotResult && r.resultText == "ok" && r.sessionID == "th1")
    }

    @Test func notACodexServer() async throws {
        let turn = Turn()
        let r = try await run("echo hello; exit 3", turn: turn)
        #expect(!turn.started)
        #expect(r.failed && r.cannotStart && r.errorText.contains("обнови Codex"))
    }

    @Test func stopKillsADeafServer() async throws {
        let r = try await run(start + "trap '' TERM; while :; do sleep 1; done", stopAfter: .milliseconds(500))
        #expect(r.stopped && !r.failed)
    }

    @Test func allowRuleStopsBeforeTheProcess() async throws {
        let rules = dir.appendingPathComponent(".codex/rules")
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        let file = rules.appendingPathComponent("default.rules"), mark = dir.appendingPathComponent("started")
        try "prefix_rule(pattern=['ls'], decision='allow')".write(to: file, atomically: true, encoding: .utf8)
        do {
            _ = try await run("touch '\(mark.path)'")
            Issue.record("started")
        } catch let e as CodexError {
            #expect(e.localizedDescription.contains("default.rules"))
        }
        #expect(!FileManager.default.fileExists(atPath: mark.path))
        let home = CodexLocator.rulesDirs(nil, env: ["CODEX_HOME": "/h"])
        #expect(home.map(\.path).contains("/h/rules"))
        #expect(CodexLocator.rulesDirs(nil, env: [:]).contains { $0.path.hasSuffix("/.codex/rules") })
    }

    @Test func ownPathIsNotReplaced() {
        let d = UserDefaults.standard, old = d.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { d.setVolatileDomain(old, forName: UserDefaults.argumentDomain) }
        var args = old
        args[CodexLocator.key] = "/no/such/codex"
        d.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        #expect(CodexLocator.resolve() == nil)
        #expect(throws: CodexError.self) { try CodexProcess().start(AgentRequest(cwd: dir, prompt: "", access: .coding)) }
    }

    private func queue(_ agent: FakeAgent, danger: DangerMode = DangerMode()) -> JobQueue {
        let q = JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([agent]),
                 profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "F", agent: agent.id)], defaultID: "fake") },
                 dangerMode: { danger }, recordSpend: { _, _, _, _ in })
        // Another suite pauses its queue through the same UserDefaults at this time.
        q.paused = false
        return q
    }
    private func job(_ kind: Job.Kind = .runTask) -> Job {
        Job(kind: kind, title: "Задача", projectID: nil, projectName: "p", cwd: dir, prompt: "x", systemPrompt: "")
    }

    @Test func neverCodesInTheMainFolder() async throws {
        let a = FakeAgent("fake", CodexAgent().capabilities), q = queue(a), main = job()
        main.mustUseMain = true
        q.add(main)
        for _ in 0..<100 where main.state == .pending { try await Task.sleep(for: .milliseconds(20)) }
        #expect(main.state == .failed && main.lastLine.contains("только в worktree"))
        // No git here: waits with a reason.
        let j = job()
        q.add(j)
        for _ in 0..<200 where !q.waitReason(j).contains("только в worktree") { try await Task.sleep(for: .milliseconds(20)) }
        #expect(j.state == .pending && q.waitReason(j).contains("только в worktree"))
        q.runInMainFolder(j)
        #expect(!j.mustUseMain && a.runs.isEmpty && !q.canResolveMain)
        q.cancel(j)
    }

    @Test func dangerModeDoesNotAnswerForIt() async throws {
        for bypass in [false, true] {
            var mode = DangerMode()
            let on = mode.enable(dir.path, name: "p", typed: "p", .hour, autopilot: false, verify: "", now: Date())
            #expect(on)
            let a = FakeAgent("fake", bypass ? [.permissions, .bypass] : CodexAgent().capabilities), q = queue(a, danger: mode)
            let j = job(.review)
            q.add(j)
            for _ in 0..<100 where a.runs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            let run = try #require(a.runs.first)
            run.onPermission?(AgentPermission(id: "1", tool: "Bash", title: "rm"))
            #expect(run.answers.isEmpty == !bypass)
            if !bypass { #expect(run.request?.bypassPermissions == false) }
            run.finish { $0.stopped = true }
        }
    }

    @Test func startProblemKeepsTheSession() async throws {
        let a = FakeAgent(), q = queue(a), j = job()
        q.add(j)
        a.runs[0].finish()
        j.review = "замечание"
        q.requestFix(j)
        a.runs[1].finish { $0.isError = true; $0.turns = 0; $0.cannotStart = true; $0.resultText = "нет входа" }
        #expect(a.runs.count == 2 && j.sessionID == "s1")
    }
}
