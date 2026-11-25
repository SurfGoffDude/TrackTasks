import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// Pipelines through the real queue, git and worktrees; only the agents are fake.
@MainActor @Suite(.serialized) struct PipelineQueueTests {
    final class Box { var mode = DangerMode() }
    let dir: URL, main: URL, task: URL
    let box = Box()
    let claude = FakeAgent("claude", [.resume, .fork, .permissions, .cost, .bypass])
    let codex = FakeAgent("codex", [.resume, .requiresWorktree])

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-pipe-\(UUID().uuidString)")
        main = dir.appendingPathComponent("main")
        task = main.appendingPathComponent("tasks/20261124-000000-x.md")
        try FileManager.default.createDirectory(at: task.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: main.appendingPathComponent("a.txt"))
        try Data("---\nverify: \"true\"\n---\n".utf8).write(to: main.appendingPathComponent("about.md"))
        try Data("---\ntitle: \"x\"\nstatus: done\n---\n\nтекст\n".utf8).write(to: task)
        for a in [["init", "-q", "-b", "main"], ["config", "user.name", "t"], ["config", "user.email", "t@t"],
                  ["config", "commit.gpgsign", "false"], ["add", "-A"], ["commit", "-q", "-m", "base"]] {
            #expect(Worktrees.git(a, in: main).ok)
        }
    }

    private func queue() -> JobQueue {
        let box = box
        let q = JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([claude, codex]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "codex", title: "Codex", agent: .codex, model: "gpt")]) },
                         dangerMode: { box.mode }, recordSpend: { _, _, _, _ in })
        q.paused = false
        return q
    }

    /// plan Claude → code Codex → review Claude ⇄ fix Codex.
    private func flow(_ edit: (inout Workflow) -> Void = { _ in }) -> Workflow {
        var w = Workflow.template
        w.steps[0].agent = "claude"
        w.steps[0].model = "opus"
        w.steps[1].agent = "codex"
        w.steps[1].text = "Указание кода"
        w.steps[2].agent = "claude"
        w.steps[2].model = "sonnet"
        w.steps[3].agent = "codex"
        edit(&w)
        #expect(w.lint().isEmpty)
        return w
    }

    private func start(_ q: JobQueue, _ w: Workflow) -> Job {
        let j = Job(kind: .runTask, title: "x", projectID: nil, projectName: "p", cwd: main, prompt: "сделай", systemPrompt: "", taskPath: task.path)
        q.beginPipeline(j, name: "main", workflow: w)
        q.add(j)
        return j
    }

    private func wait(_ what: String = "", _ done: () -> Bool) async throws {
        // Other suites and builds may take the machine: several times longer than usual is no failure.
        for _ in 0..<3000 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(done(), "\(what)")
    }
    private func run(_ a: FakeAgent, _ n: Int) async throws -> FakeRun {
        try await wait("запуск \(n) агента \(a.id.rawValue)") { a.runs.count > n && a.runs[n].request != nil }
        return a.runs[n]
    }
    private func edit(_ r: FakeRun, _ text: String) throws {
        try Data((text + "\n").utf8).write(to: try #require(r.request).cwd.appendingPathComponent("a.txt"))
    }
    private func plan(_ r: FakeRun) throws {
        try Data("---\ntitle: \"x\"\nstatus: done\n---\n\nтекст\n\n## План\n\n1. шаг\n".utf8).write(to: task)
        r.finish(session: "plan")
    }
    private var mainText: String { (try? String(contentsOf: main.appendingPathComponent("a.txt"), encoding: .utf8)) ?? "" }
    private func cleanUp() {
        let key = main.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "__")
        try? FileManager.default.removeItem(at: Worktrees.root.appendingPathComponent(key))
        try? FileManager.default.removeItem(at: dir)
    }
    /// Up to the running review.
    private func upToReview(_ q: JobQueue, _ w: Workflow) async throws -> (Job, FakeRun) {
        let j = start(q, w)
        try plan(try await run(claude, 0))
        try await wait("план") { j.awaitingPlan && j.state == .pending }
        q.approvePlan(j)
        let code = try await run(codex, 0)
        try edit(code, "new")
        code.finish(session: "codex-1")
        return (j, try await run(claude, 1))
    }

    @Test func planClaudeCodeCodexReviewClaude() async throws {
        defer { cleanUp() }
        let q = queue(), (j, review) = try await upToReview(q, flow())
        let planReq = try #require(claude.runs[0].request), code = try #require(codex.runs[0].request), rev = try #require(review.request)
        #expect(planReq.access == .planning && planReq.cwd == main && planReq.model == "opus")
        #expect(code.access == .coding && code.model == "gpt" && code.resume == nil && code.cwd != main)
        #expect(code.prompt.contains("Указание кода") && code.prompt.contains("План одобрен"))
        #expect(rev.access == .planning && rev.model == "sonnet" && rev.resume == nil && rev.cwd == code.cwd)
        #expect(q.mergeable.isEmpty)
        await q.mergeNow(j)
        #expect(!j.merged && j.worktreeNote.contains("Не слито"))
        q.requestReview(j)
        #expect(q.jobs.filter { $0.kind == .review }.count == 1)
        review.finish(session: "r") { $0.resultText = "ВЕРДИКТ: ОК" }
        try await wait("конец") { !j.pipelineOpen }
        #expect(j.agentID == .codex && j.sessionID == "codex-1" && j.verdict == .ok && !j.merged && mainText == "old\n")
        #expect(j.pipeline?.cost.usd == 1.5)
        #expect(q.mergeable.map(\.id) == [j.id])
        // The person merges as usual.
        #expect(await q.mergeNow(j))
        #expect(mainText == "new\n")
    }

    @Test func remarksAreFixedAndReviewedAgain() async throws {
        defer { cleanUp() }
        let q = queue(), (j, r1) = try await upToReview(q, flow { $0.steps[3].agent = "claude" })
        r1.finish(session: "r") { $0.resultText = "ВЕРДИКТ: ПРАВКИ\n- исправь" }
        let fix = try await run(claude, 2)
        // Codex wrote the code: its session isn't for Claude.
        #expect(fix.request?.resume == nil && fix.request?.access == .coding && fix.request?.prompt.contains("исправь") == true)
        try edit(fix, "fixed")
        fix.finish(session: "f")
        let r2 = try await run(claude, 3)
        r2.finish(session: "r2") { $0.resultText = "ВЕРДИКТ: ОК" }
        try await wait("конец") { !j.pipelineOpen }
        #expect(j.sessionID == "codex-1" && j.pipeline?.visits == [1, 1, 2, 1])
        // A reply goes to the agent of the code step; changed code reopens the pipeline.
        #expect(q.sendReply(j, text: "ещё"))
        let reply = try await run(codex, 1)
        #expect(reply.request?.resume == "codex-1")
        try edit(reply, "again")
        reply.finish(session: "codex-2")
        try await wait("остановка") { j.pipelineOpen }
        #expect(q.mergeable.isEmpty && j.pipeline?.gate?.next == .end)
        q.pipelineContinue(j)
        #expect(!j.pipelineOpen && q.mergeable.count == 1)
    }

    @Test func sameAgentFixContinuesItsSession() async throws {
        defer { cleanUp() }
        let q = queue(), (j, r1) = try await upToReview(q, flow())
        r1.finish(session: "r") { $0.resultText = "ВЕРДИКТ: ПРАВКИ" }
        let fix = try await run(codex, 1)
        #expect(fix.request?.resume == "codex-1")
        // Nothing changed: the person decides.
        fix.finish(session: "codex-1")
        try await wait("остановка") { j.pipeline?.gate != nil }
        #expect(j.pipeline?.gate?.reason.contains("не изменил код") == true)
    }

    @Test func repeatsRunOut() async throws {
        defer { cleanUp() }
        let q = queue(), (j, r1) = try await upToReview(q, flow { $0.steps[3].repeats = 1 })
        r1.finish(session: "r") { $0.resultText = "ВЕРДИКТ: ПРАВКИ" }
        let fix = try await run(codex, 1)
        try edit(fix, "fixed")
        fix.finish(session: "codex-1")
        (try await run(claude, 2)).finish(session: "r") { $0.resultText = "ВЕРДИКТ: ПРАВКИ" }
        try await wait("остановка") { j.pipeline?.gate?.kind == .limit }
        #expect(codex.runs.count == 2 && !j.isActive)
        q.pipelineFinish(j)
        #expect(!j.pipelineOpen && !j.merged)
    }

    @Test func budgetStopsAndOtherTasksGoOn() async throws {
        defer { cleanUp() }
        let q = queue(), j = start(q, flow { $0.budget = 0.4 })
        try plan(try await run(claude, 0))
        try await wait("план") { j.awaitingPlan && j.state == .pending }
        q.approvePlan(j)
        #expect(j.pipeline?.gate?.kind == .limit && j.state == .pending && q.waitReason(j).contains("Бюджет"))
        #expect(q.runningCount == 0 && codex.runs.isEmpty)
        // Restart at the stop.
        try JSONEncoder.queue.encode(q.jobs.map(\.record)).write(to: dir.appendingPathComponent("queue.json"))
        let q2 = queue(), k = try #require(q2.jobs.first)
        try await Task.sleep(for: .milliseconds(200))
        #expect(k.pipeline == j.pipeline && codex.runs.isEmpty)
        q2.pipelineContinue(k)
        let code = try await run(codex, 0)
        #expect(code.request?.resume == nil)
        code.finish { $0.stopped = true }
    }

    @Test func restartInTheMiddleOfAReview() async throws {
        defer { cleanUp() }
        let q = queue(), (j, _) = try await upToReview(q, flow())
        try JSONEncoder.queue.encode(q.jobs.map(\.record)).write(to: dir.appendingPathComponent("queue.json"))
        let q2 = queue(), k = try #require(q2.job(j.id))
        try await wait("остановка") { k.pipeline?.gate != nil && !k.worktreeBusy }
        #expect(k.state == .done)
        q2.pipelineRepeat(k)
        let again = try await run(claude, 2)
        again.finish(session: "r") { $0.resultText = "ВЕРДИКТ: ОК" }
        try await wait("конец") { !k.pipelineOpen }
        #expect(codex.runs.count == 1)
    }

    @Test func retryRepeatsOnlyTheCutOffStep() async throws {
        defer { cleanUp() }
        let q = queue(), j = start(q, flow())
        try plan(try await run(claude, 0))
        try await wait("план") { j.awaitingPlan && j.state == .pending }
        q.approvePlan(j)
        let code = try await run(codex, 0)
        try edit(code, "half")
        code.finish(session: "codex-1") { $0.isError = true; $0.resultText = "сломалось" }
        try await wait("ошибка") { j.state == .failed }
        #expect(j.pipeline?.gate?.reason.contains("сломалось") == true)
        let spent = j.pipeline?.cost
        q.retry(j)
        let k = try #require(q.jobs.last)
        let again = try await run(codex, 1)
        #expect(again.request?.cwd == code.request?.cwd && again.request?.prompt.contains("Шаг повторяется") == true)
        #expect(claude.runs.count == 1 && k.pipeline?.visits == [1, 2, 0, 0] && k.pipeline?.cost == spent)
        try edit(again, "whole")
        again.finish(session: "codex-2")
        _ = try await run(claude, 1)
        claude.runs[1].finish { $0.stopped = true }
        try await wait("остановка") { k.pipeline?.gate != nil }
    }

    @Test func reviewerMustNotChangeCode() async throws {
        defer { cleanUp() }
        let q = queue(), (j, r) = try await upToReview(q, flow())
        try edit(r, "by reviewer")
        r.finish(session: "r") { $0.resultText = "ВЕРДИКТ: ОК" }
        try await wait("остановка") { j.pipeline?.gate != nil }
        #expect(j.verdict == nil && j.pipeline?.gate?.next == nil && q.mergeable.isEmpty)
    }

    @Test func vagueReviewStops() async throws {
        defer { cleanUp() }
        let q = queue(), (j, r) = try await upToReview(q, flow())
        r.finish(session: "r") { $0.resultText = "В целом ВЕРДИКТ: ОК" }
        try await wait("остановка") { j.pipeline?.gate != nil }
        #expect(j.verdict == nil && q.mergeable.isEmpty && q.reviewable.isEmpty && q.fixable.isEmpty)
        await q.mergeNow(j, force: true)
        #expect(!j.merged && mainText == "old\n" && j.worktreeNote.contains("пайплайн не завершён"))
    }

    @Test func codeWithoutChangesCanBeRepeated() async throws {
        defer { cleanUp() }
        let q = queue(), j = start(q, flow { $0.steps[0].stop = Workflow.Stop.none })
        try plan(try await run(claude, 0))
        // Dependents wait although the job is «done» without a branch.
        let code = try await run(codex, 0)
        let next = Job(kind: .runTask, title: "y", projectID: nil, projectName: "p", cwd: main, prompt: "y", systemPrompt: "")
        next.dependsOn = [j.id]
        q.add(next)
        code.finish(session: "codex-1")
        try await wait("остановка") { j.pipeline?.gate != nil && !j.worktreeBusy }
        #expect(j.state == .done && j.worktree == nil && next.state == .pending)
        q.pipelineRepeat(j)
        let again = try await run(codex, 1)
        #expect(again.request?.resume == nil && again.request?.cwd != main)
        again.finish { $0.stopped = true }
        try await wait("стоп") { j.state == .cancelled }
    }

    @Test func dangerModeNeitherApprovesNorMerges() async throws {
        defer { cleanUp() }
        let on = box.mode.enable(main.path, name: "p", typed: "p", .hour, autopilot: true, verify: "true", now: Date().addingTimeInterval(-1))
        #expect(on)
        let q = queue(), j = start(q, flow())
        try plan(try await run(claude, 0))
        try await wait("план") { j.awaitingPlan && j.state == .pending }
        try await Task.sleep(for: .milliseconds(200))
        #expect(j.awaitingPlan && codex.runs.isEmpty)
        q.approvePlan(j)
        let code = try await run(codex, 0)
        try edit(code, "new")
        code.finish(session: "c")
        (try await run(claude, 1)).finish(session: "r") { $0.resultText = "ВЕРДИКТ: ОК" }
        try await wait("конец") { !j.pipelineOpen }
        q.pump()
        try await Task.sleep(for: .milliseconds(800))
        #expect(!j.merged && mainText == "old\n" && !q.onAutopilot(j) && q.allows(.merge, j))
    }

    /// The connection broke: the run on the server is continued, never started twice.
    @Test func reviewLeftOnAServerIsContinued() async throws {
        defer { cleanUp() }
        let ssh = FakeAgent("ssh", [.resume, .requiresWorktree, .remote, .cost])
        let server = RemoteServer(host: "example.org")
        let box = box
        let q = JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([claude, codex, ssh]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "codex", title: "Codex", agent: .codex, model: "gpt"),
                                                            AgentProfile(id: "srv", title: "S", agent: .ssh, server: server)]) },
                         dangerMode: { box.mode }, recordSpend: { _, _, _, _ in })
        let j = start(q, flow { $0.steps[2].agent = "srv" })
        try plan(try await run(claude, 0))
        try await wait("план") { j.awaitingPlan && j.state == .pending }
        q.approvePlan(j)
        let code = try await run(codex, 0)
        try edit(code, "new")
        code.finish(session: "codex-1")
        let first = try await run(ssh, 0)
        #expect(first.request?.remote?.attach == false && j.server == nil && j.agentID == .codex)
        first.finish(session: "r") { $0.isError = true; $0.resultText = "нет связи" }
        try await wait("остановка") { j.pipeline?.gate != nil }
        q.pipelineRepeat(j)
        let again = try await run(ssh, 1)
        #expect(again.request?.remote?.attach == true && again.request?.remote?.run.id == first.request?.remote?.run.id)
        #expect(again.request?.cwd == code.request?.cwd && j.pipeline?.visits == [1, 1, 1, 0])
        again.finish(session: "r") { $0.resultText = "ВЕРДИКТ: ОК" }
        try await wait("конец") { !j.pipelineOpen }
        #expect(j.verdict == .ok && ssh.runs.count == 2)
    }

    @Test func unknownProfileStopsTheStep() async throws {
        defer { cleanUp() }
        let q = queue(), j = start(q, flow { $0.steps[0].stop = Workflow.Stop.none; $0.steps[1].agent = "gone" })
        try plan(try await run(claude, 0))
        try await wait("ошибка") { j.state == .failed }
        #expect(j.lastLine.contains("gone") && claude.runs.count == 1 && codex.runs.isEmpty)
        // A lost profile is not taken for Claude after a restart.
        #expect(Job(j.record).agent == nil)
    }
}

private extension JSONEncoder {
    static var queue: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
