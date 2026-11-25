import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// «Передать другому агенту» through the real queue and git; only the agents are fake.
@MainActor @Suite(.serialized) struct HandoffQueueTests {
    let dir: URL, main: URL, wt: URL, task: URL
    let claude = FakeAgent("claude", [.resume, .fork, .permissions])
    let codex = FakeAgent("codex", [.resume, .requiresWorktree])

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-handoff-\(UUID().uuidString)")
        main = dir.appendingPathComponent("main")
        wt = dir.appendingPathComponent("wt")
        task = main.appendingPathComponent("tasks/20261124-000000-x.md")
        try FileManager.default.createDirectory(at: task.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\ntitle: \"x\"\nstatus: doing\n---\n\nтекст задачи\n\n## План\n\n1. шаг плана\n".utf8).write(to: task)
        try Data("old\n".utf8).write(to: main.appendingPathComponent("a.txt"))
        for a in [["init", "-q", "-b", "main"], ["config", "user.name", "t"], ["config", "user.email", "t@t"],
                  ["config", "commit.gpgsign", "false"], ["add", "-A"], ["commit", "-q", "-m", "base"],
                  ["worktree", "add", "-q", "-b", "tracktasks/x", wt.path]] { git(a) }
        try Data("edited\n".utf8).write(to: wt.appendingPathComponent("a.txt"))
        try Data("fresh\n".utf8).write(to: wt.appendingPathComponent("new.txt"))
    }

    @discardableResult private func git(_ args: [String], _ d: URL? = nil) -> String {
        let r = Worktrees.git(args, in: d ?? main)
        #expect(r.ok, "\(args): \(r.err)")
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func queue() -> JobQueue {
        let q = JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([claude, codex]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "codex", title: "Codex", agent: .codex, model: "gpt"),
                                                            AgentProfile(id: "opus", title: "Opus", agent: .claude, model: "opus")]) },
                         dangerMode: { DangerMode() }, recordSpend: { _, _, _, _ in })
        q.paused = false
        return q
    }
    /// Failed after some uncommitted work.
    private func job(_ q: JobQueue, worktree: Bool = true, _ edit: (Job) -> Void = { _ in }) -> Job {
        let j = Job(kind: .runTask, title: "x", projectID: nil, projectName: "p", cwd: main,
                    prompt: "Выполни задачу из файла tasks/\(task.lastPathComponent)", systemPrompt: "", taskPath: task.path)
        j.agent = .claude
        j.state = .failed
        j.sessionID = "s1"
        j.lastLine = "застрял"
        j.setupDone = true
        j.log = ["Сделал половину"]
        if worktree {
            j.worktree = .init(path: wt, main: main, branch: "tracktasks/x")
            j.baseCommit = git(["rev-parse", "HEAD"])
        }
        edit(j)
        q.jobs.append(j)
        return j
    }
    private func draft(_ q: JobQueue, _ j: Job) async throws -> HandoffDraft {
        switch await q.prepareHandoff(j) {
        case .success(let d): return d
        case .failure(let e): throw e
        }
    }
    private func refusal(_ q: JobQueue, _ j: Job) async -> String? {
        if case .failure(let e) = await q.prepareHandoff(j) { e.message } else { nil }
    }
    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(done())
    }
    private func loaded() throws -> [Job] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode([JobRecord].self, from: Data(contentsOf: dir.appendingPathComponent("queue.json"))).map(Job.init)
    }
    private func clean() { try? FileManager.default.removeItem(at: dir) }
    private func handed(_ q: JobQueue, _ j: Job) async throws -> FakeRun {
        #expect(await q.handOff(j, try await draft(q, j), to: "codex") == nil)
        try await wait { codex.runs.last?.request != nil }
        return codex.runs.last!
    }
    private var workIsThere: Bool { FileManager.default.fileExists(atPath: wt.appendingPathComponent("new.txt").path) }

    @Test func sameBranchNewAgentOldSessionKept() async throws {
        defer { clean() }
        let q = queue(), j = job(q), d = try await draft(q, j), text = d.text.message(note: "быстрее")
        for s in ["+edited", "+fresh", "new.txt", "текст задачи", "1. шаг плана", "Сделал половину", task.path] { #expect(text.contains(s), "\(s)") }
        #expect(await q.handOff(j, d, to: "codex", note: "быстрее") == nil)
        try await wait { codex.runs.first?.request != nil }
        let r = try #require(codex.runs.first?.request)
        #expect(r.prompt == text && r.resume == nil && !r.fork && r.cwd == wt && r.model == "gpt")
        #expect(claude.runs.isEmpty && q.jobs.count == 1 && j.worktree?.branch == "tracktasks/x")
        #expect(j.agentID == .codex && j.sessionID == nil && j.handoffs.last?.session == "s1" && j.handoffs.last?.from.agent == .claude)
        #expect(j.log.contains { $0.contains("Передано:") })
        // One checkpoint, before the turn.
        let points = try Checkpoints.list(branch: "tracktasks/x", in: main, git: DiffLoader.runEnv)
        #expect(points.map(\.meta.label) == ["Передача: Fake → Fake (gpt)"] && points.first?.meta.session == "s1")
        // On disk before the turn began, gone after.
        let saved = try #require(try loaded().first)
        #expect(saved.pendingHandoff?.text == text && saved.handoffs.last?.session == "s1" && saved.state == .failed && saved.interrupted)
        codex.runs[0].onTurnStarted?()
        #expect(j.pendingHandoff == nil)
        #expect(try loaded().first?.pendingHandoff == nil)
        codex.runs[0].finish(session: "c1")
        try await wait { j.state == .done }
        #expect(j.sessionID == "c1" && j.handoffs.map(\.status) == [.accepted] && j.committed)
        #expect(git(["show", "tracktasks/x:new.txt"]) == "fresh")
        q.saveNow()
        let again = try #require(try loaded().first { $0.id == j.id })
        #expect(again.handoffs.first?.session == "s1" && again.agentID == .codex && again.sessionID == "c1")
    }

    @Test func approvedPlanAndCommittedWork() async throws {
        defer { clean() }
        git(["add", "-A"], wt)
        git(["commit", "-q", "-m", "job"], wt)
        let q = queue(), j = job(q) { $0.planPhase = .approved; $0.state = .done; $0.committed = true }
        let run = try await handed(q, j)
        #expect(run.request?.prompt.contains("+fresh") == true && run.request?.prompt.components(separatedBy: "План одобрен").count == 2)
        // Nothing new, but the branch and the previous session's folder stay.
        run.finish(session: "c1")
        try await wait { j.state == .done }
        #expect(j.worktree != nil && workIsThere && j.committed)
    }

    @Test func emptyDiffIsSaid() async throws {
        defer { clean() }
        git(["checkout", "-q", "--", "."], wt)
        git(["clean", "-fdq"], wt)
        let q = queue(), j = job(q)
        #expect(try await draft(q, j).text.message().contains("Diff пуст"))
        // Broken git is not «no changes».
        j.baseCommit = "0123456789012345678901234567890123456789"
        #expect(await refusal(q, j)?.contains("git") == true)
    }

    @Test func busyIsRefused() async throws {
        defer { clean() }
        let q = queue()
        q.paused = true
        let j = job(q)
        let d = try await draft(q, j)
        func check(_ why: String, _ on: () -> Void, _ off: () -> Void) async {
            on()
            #expect(await refusal(q, j) != nil, "\(why)")
            #expect(await q.handOff(j, d, to: "codex") != nil, "\(why)")
            off()
            #expect(q.handoffBlocked(j) == nil, "\(why)")
        }
        await check("running", { j.state = .running }, { j.state = .failed })
        await check("pending", { j.state = .pending }, { j.state = .failed })
        await check("busy", { j.worktreeBusy = true }, { j.worktreeBusy = false })
        await check("merge", { j.mergePhase = .checking }, { j.mergePhase = nil })
        await check("plan", { j.planPhase = .awaiting }, { j.planPhase = nil })
        await check("rollback", { j.rolledBack = "№1" }, { j.rolledBack = "" })
        let child = Job(kind: .review, title: "r", projectID: nil, projectName: "p", cwd: main, prompt: "", systemPrompt: "")
        child.parentID = j.id
        await check("child", { q.jobs.append(child) }, { q.jobs.removeAll { $0 === child } })
        await check("pipeline", { q.beginPipeline(j, name: "m", workflow: .template) }, { j.pipeline = nil; j.planPhase = nil; j.fromPipeline = false; j.sessionID = "s1" })
        #expect(codex.runs.isEmpty && j.handoffs.isEmpty && j.sessionID == "s1")
    }

    @Test func noWorktree() async throws {
        defer { clean() }
        let q = queue(), j = job(q, worktree: false)
        try Data("main edit\n".utf8).write(to: main.appendingPathComponent("a.txt"))
        let d = try await draft(q, j)
        #expect(d.text.message().contains("+main edit") && !d.warnings.isEmpty)
        #expect(await q.handOff(j, d, to: "codex")?.contains("только в worktree") == true)
        #expect(j.agentID == .claude && j.handoffs.isEmpty)
        // Another model of an agent that may work there.
        #expect(await q.handOff(j, d, to: "opus") == nil)
        try await wait { claude.runs.first?.request != nil }
        #expect(claude.runs[0].request?.cwd == main && claude.runs[0].request?.resume == nil && claude.runs[0].request?.model == "opus" && j.worktree == nil)
        claude.runs[0].finish()

        let gone = job(q) { $0.hadWorktree = true }
        gone.worktree = nil
        #expect(await refusal(q, gone) != nil)
        let lost = job(q) { $0.worktree = .init(path: self.dir.appendingPathComponent("nope"), main: self.main, branch: "b") }
        #expect(await refusal(q, lost)?.contains("удалён") == true)
    }

    @Test func waitingForTheLimitMayBeHandedOver() async throws {
        defer { clean() }
        let q = queue(), reset = Date().addingTimeInterval(3600)
        let j = job(q) { $0.state = .pending; $0.limitWait = LimitWait(window: "five_hour", resetsAt: reset, session: "s1") }
        let run = try await handed(q, j)
        #expect(j.limitWait == nil && j.state == .running)
        // The new one is refused before it began: it waits as before.
        run.finish(session: "c1") { $0.isError = true; $0.turns = 0; $0.limit = RunLimit(window: "five_hour", resetsAt: reset) }
        #expect(j.state == .pending && j.limitWait?.session == "s1" && j.sessionID == "s1" && j.agentID == .claude)
        #expect(j.handoffs.map(\.status) == [.failed] && j.pendingHandoff == nil && workIsThere)
    }

    @Test func changedWorktreeIsRefused() async throws {
        defer { clean() }
        let q = queue(), j = job(q), d = try await draft(q, j)
        try Data("later\n".utf8).write(to: wt.appendingPathComponent("a.txt"))
        #expect(await q.handOff(j, d, to: "codex")?.contains("обнови окно") == true)
        let d2 = try await draft(q, j)
        try Data("---\ntitle: y\n---\n".utf8).write(to: task)
        #expect(await q.handOff(j, d2, to: "codex")?.contains("обнови окно") == true)
        #expect(codex.runs.isEmpty && j.state == .failed && !j.worktreeBusy && j.handoffs.isEmpty)
    }

    @Test func withoutCheckpointNothingIsHandedOver() async throws {
        defer { clean() }
        let q = queue(), j = job(q), d = try await draft(q, j)
        // A ref in the way of the checkpoint's folder: the state can be read, the checkpoint can't be written.
        git(["update-ref", "refs/tracktasks/checkpoints/tracktasks/x", "HEAD"])
        #expect(await q.handOff(j, d, to: "codex")?.hasPrefix("Не передано") == true)
        #expect(codex.runs.isEmpty && j.agentID == .claude && j.sessionID == "s1" && j.handoffs.isEmpty && !j.worktreeBusy)
    }

    @Test func newAgentDidNotStart() async throws {
        defer { clean() }
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let q = queue()
        for viaStart in [true, false] {
            let j = job(q)
            codex.startError = viaStart ? Boom() : nil
            #expect(await q.handOff(j, try await draft(q, j), to: "codex") == nil)
            if !viaStart {
                try await wait { codex.runs.last?.request != nil }
                codex.runs.last?.finish(session: "c1") { $0.isError = true; $0.turns = 0; $0.cannotStart = true; $0.resultText = "нет входа" }
            }
            try await wait { j.state == .failed }
            #expect(j.agentID == .claude && j.sessionID == "s1" && j.profile.isEmpty && j.interrupted && j.worktree?.path == wt && workIsThere)
            #expect(j.handoffs.map(\.status) == [.failed] && j.pendingHandoff == nil && j.lastLine.contains("Не передано"))
            // «↻» goes on with the previous session.
            let before = claude.runs.count
            q.retry(j)
            try await wait { claude.runs.count > before && claude.runs.last?.request != nil }
            #expect(claude.runs.last?.request?.resume == "s1" && claude.runs.last?.request?.cwd == wt)
            claude.runs.last?.finish { $0.stopped = true }
            try await wait { q.jobs.allSatisfy { !$0.isActive } }
            q.jobs = []
        }
    }

    @Test func cancelledBeforeTheTurnGivesBack() async throws {
        defer { clean() }
        let q = queue(), j = job(q)
        let run = try await handed(q, j)
        run.finish(session: nil) { $0.stopped = true; $0.turns = 0 }
        #expect(j.state == .failed && j.agentID == .claude && j.sessionID == "s1" && workIsThere)
    }

    @Test func retryStaysWithTheNewAgent() async throws {
        defer { clean() }
        let q = queue(), j = job(q) { $0.committed = true }
        let run = try await handed(q, j)
        run.finish(session: "c1") { $0.isError = true; $0.resultText = "упал" }
        #expect(j.state == .failed && j.sessionID == "c1" && !j.interrupted)
        q.retry(j)
        try await wait { codex.runs.count == 2 && codex.runs[1].request != nil }
        let n = try #require(q.jobs.last)
        #expect(codex.runs[1].request?.resume == "c1" && codex.runs[1].request?.cwd == wt && claude.runs.isEmpty)
        #expect(n.handoffs.first?.session == "s1" && n.committed && n.agentID == .codex)
        codex.runs[1].finish(session: "c1") { $0.stopped = true }
        try await wait { !n.isActive }
        #expect(workIsThere)
    }

    /// The app closed before the turn began: the text goes again only by «↻», exactly the same.
    @Test func restart() async throws {
        defer { clean() }
        let q = queue(), j = job(q)
        let sent = try await handed(q, j).request?.prompt
        q.paused = true
        q.jobs = []
        let q2 = queue()
        let l = try #require(q2.jobs.first)
        #expect(l.state == .failed && l.interrupted && codex.runs.count == 1)
        try await wait { !l.worktreeBusy }
        q2.retry(l)
        try await wait { codex.runs.count == 2 && codex.runs[1].request != nil }
        #expect(codex.runs[1].request?.prompt == sent && codex.runs[1].request?.resume == nil && codex.runs[1].request?.cwd == wt)
        codex.runs[1].finish(session: "c1") { $0.stopped = true }
    }
}
