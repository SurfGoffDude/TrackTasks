import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// «Опасный режим» through the real queue, git and worktrees; only the agent is fake.
@MainActor @Suite(.serialized) struct DangerQueueTests {
    final class Box { var mode = DangerMode() }
    let dir: URL, main: URL
    let box = Box()
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-danger-\(UUID().uuidString)")
        main = dir.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: main.appendingPathComponent("a.txt"))
        for a in [["init", "-q", "-b", "main"], ["config", "user.name", "t"], ["config", "user.email", "t@t"],
                  ["config", "commit.gpgsign", "false"], ["add", "-A"], ["commit", "-q", "-m", "base"]] { #expect(git(a).ok) }
    }
    @discardableResult private func git(_ args: [String]) -> Worktrees.Result { Worktrees.git(args, in: main) }

    private func turnOn(ago: TimeInterval = 1) {
        let ok = box.mode.enable(main.path, name: "p", typed: "p", .hour, now: Date().addingTimeInterval(-ago))
        #expect(ok)
    }
    private func queue(_ a: FakeAgent) -> JobQueue {
        let box = box
        let q = JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([a]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "F", agent: a.id, model: "m")], defaultID: "fake") },
                         dangerMode: { box.mode }, recordSpend: { _, _, _, _ in })
        // Another suite pauses its queue through the same UserDefaults.
        q.paused = false
        return q
    }
    private func agent() -> FakeAgent { FakeAgent("fake", [.resume, .permissions, .bypass]) }
    private func job(_ q: JobQueue, source: String = "") throws -> Job {
        let task = main.appendingPathComponent("tasks/20261124-000000-x.md")
        try Data("---\ntitle: \"x\"\nstatus: todo\n\(source.isEmpty ? "" : "source: \(source)\n")---\n\nтекст\n".utf8).write(to: task)
        return Job(kind: .runTask, title: "x", projectID: nil, projectName: "p", cwd: main, prompt: "x", systemPrompt: "", taskPath: task.path)
    }
    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(20)) }
    }
    /// The worktrees of this temporary project only.
    private func cleanUp() {
        let key = main.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "__")
        try? FileManager.default.removeItem(at: Worktrees.root.appendingPathComponent(key))
        try? FileManager.default.removeItem(at: dir)
    }
    /// Runs one job up to its start and stops it.
    private func bypass(source: String = "") async throws -> Bool? {
        let a = agent(), q = queue(a), j = try job(q, source: source)
        q.add(j)
        try await wait { !a.runs.isEmpty }
        let flag = a.runs.first?.request?.bypassPermissions
        #expect(j.fullAccess == flag)
        a.runs.first?.finish { $0.stopped = true }
        return flag
    }

    @Test func onGivesFullAccess() async throws {
        defer { cleanUp() }
        turnOn()
        #expect(try await bypass() == true)
    }
    @Test func offAndExpiredGiveNone() async throws {
        defer { cleanUp() }
        #expect(try await bypass() == false)
        turnOn(ago: 3601)
        #expect(try await bypass() == false)
    }
    @Test func foreignTaskHasNone() async throws {
        defer { cleanUp() }
        turnOn()
        #expect(try await bypass(source: "https://github.com/o/r/issues/1") == false)
    }

    @Test func fixAfterTheTermHasOrdinaryRights() async throws {
        defer { cleanUp() }
        turnOn()
        let a = agent(), q = queue(a), j = try job(q)
        q.add(j)
        try await wait { !a.runs.isEmpty }
        let run = try #require(a.runs.first)
        #expect(run.request?.bypassPermissions == true)
        // The running process keeps the flag: noted once.
        turnOn(ago: 3601)
        #expect(q.noteOutlived().map(\.id) == [j.id])
        #expect(q.noteOutlived().isEmpty)
        #expect(j.log.filter { $0.contains("с прежними правами") }.count == 1)
        run.finish()
        try await wait { !j.isActive }
        #expect(j.state == .done)
        // Review, if on, is the second run; the fix is the last one.
        j.review = "замечание"
        q.requestFix(j)
        try await wait { a.runs.contains { $0.request?.resume == "s1" } }
        let fix = try #require(a.runs.first { $0.request?.resume == "s1" })
        #expect(fix.request?.bypassPermissions == false)
        for r in a.runs.dropFirst() { r.finish { $0.stopped = true } }
    }

    @Test func dirtyMainIsNotTouched() async throws {
        defer { cleanUp() }
        turnOn()
        try Data("mine\n".utf8).write(to: main.appendingPathComponent("a.txt"))
        try Data("staged\n".utf8).write(to: main.appendingPathComponent("s.txt"))
        git(["add", "s.txt"])
        let a = agent(), q = queue(a), j = try job(q)
        let before = git(["status", "--porcelain"]).out, head = git(["rev-parse", "main"]).out
        q.add(j)
        try await wait { !a.runs.isEmpty }
        let run = try #require(a.runs.first), wt = try #require(j.worktree)
        #expect(run.request?.cwd.path == wt.path.path)
        #expect(try String(contentsOf: wt.path.appendingPathComponent("a.txt"), encoding: .utf8) == "old\n")
        try Data("agent\n".utf8).write(to: wt.path.appendingPathComponent("a.txt"))
        run.finish()
        try await wait { j.committed && !j.isActive }
        #expect(j.committed && !j.merged)
        #expect(git(["show", "\(wt.branch):a.txt"]).out == "agent\n")
        #expect(git(["status", "--porcelain"]).out == before && git(["rev-parse", "main"]).out == head)
        #expect(try String(contentsOf: main.appendingPathComponent("a.txt"), encoding: .utf8) == "mine\n")
        #expect(try String(contentsOf: main.appendingPathComponent("s.txt"), encoding: .utf8) == "staged\n")
        for r in a.runs.dropFirst() { r.finish { $0.stopped = true } }
    }

    /// A job whose planning run wrote the plan and ended; the plan itself never has full access.
    private func planned(_ q: JobQueue, _ a: FakeAgent, source: String = "") async throws -> Job {
        let j = try job(q, source: source)
        j.planPhase = .planning
        q.add(j)
        try await wait { a.runs.first?.request != nil }
        let run = try #require(a.runs.first)
        #expect(run.request?.bypassPermissions == false && run.request?.access == .planning)
        let path = try #require(j.taskPath)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        try Data((text + "\n## План\n1. шаг\n").utf8).write(to: URL(fileURLWithPath: path))
        run.finish()
        return j
    }

    @Test func planIsApprovedAutomatically() async throws {
        defer { cleanUp() }
        turnOn()
        let a = agent(), q = queue(a), j = try await planned(q, a)
        try await wait { a.runs.count > 1 }
        #expect(j.planPhase == .approved)
        #expect(j.log.contains { $0.contains("Опасный режим: план одобрен автоматически") })
        #expect(a.runs.count == 2 && a.runs.last?.request?.bypassPermissions == true)
        for r in a.runs.dropFirst() { r.finish { $0.stopped = true } }
    }

    @Test func planWaitsForThePersonWhenForeignOrOff() async throws {
        defer { cleanUp() }
        turnOn()
        let a = agent(), q = queue(a), j = try await planned(q, a, source: "https://github.com/o/r/issues/1")
        try await wait { j.awaitingPlan }
        q.dangerChanged()
        #expect(j.awaitingPlan && j.state == .pending && a.runs.count == 1)
        q.cancel(j)

        box.mode = DangerMode()
        let b = agent(), q2 = queue(b), k = try await planned(q2, b)
        try await wait { k.awaitingPlan }
        #expect(k.awaitingPlan && b.runs.count == 1)
        // Turned on while the plan waits.
        turnOn()
        q2.dangerChanged()
        try await wait { b.runs.count > 1 }
        #expect(k.planPhase == .approved && b.runs.count == 2)
        for r in b.runs.dropFirst() { r.finish { $0.stopped = true } }
    }

    @Test func unapprovedSetupRunsOnlyInTheMode() async throws {
        defer { cleanUp() }
        // The folder is unique, so the shared approvals know nothing about it.
        let cmd = "touch setup-ran.txt"
        try Data("---\nname: p\nsetup: \(cmd)\n---\n".utf8).write(to: main.appendingPathComponent("about.md"))
        git(["add", "-A"])
        git(["commit", "-q", "-m", "about"])
        func approved() -> Bool { ScriptStore.approvals.isApproved(.setup, cmd, project: main) }

        let a = agent(), q = queue(a), j = try job(q)
        j.alwaysWorktree = true
        q.add(j)
        try await wait { !j.isActive }
        #expect(j.state == .failed && j.scriptApproval?.setup == cmd)
        #expect(a.runs.isEmpty && !approved())

        turnOn()
        let b = agent(), q2 = queue(b), k = try job(q2)
        q2.add(k)
        try await wait { !b.runs.isEmpty }
        let wt = try #require(k.worktree)
        #expect(FileManager.default.fileExists(atPath: wt.path.appendingPathComponent("setup-ran.txt").path))
        #expect(k.log.contains { $0.contains("Опасный режим: setup без подтверждения: $ \(cmd)") })
        #expect(!approved())
        for r in b.runs { r.finish { $0.stopped = true } }
    }
}
