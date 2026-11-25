import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

@MainActor @Suite(.serialized) struct JobQueueGitTests {
    let root: URL, main: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-gitq-\(UUID().uuidString)")
        main = root.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    }

    private func queue(_ agent: FakeAgent? = nil) -> JobQueue {
        let a = agent ?? FakeAgent()
        let q = JobQueue(storeURL: root.appendingPathComponent("queue.json"), agents: AgentRegistry([a]),
                 profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "Fake", agent: AgentID(rawValue: "fake"), model: "m1")], defaultID: "fake") },
                 dangerMode: { DangerMode() }, recordSpend: { _, _, _, _ in })
        q.paused = false
        return q
    }
    private func job(_ state: Job.State, worktree: Bool = false) -> Job {
        let j = Job(kind: .runTask, title: "j", projectID: nil, projectName: "p", cwd: main, prompt: "x", systemPrompt: "")
        j.state = state
        if worktree { j.worktree = .init(path: root.appendingPathComponent("wt"), main: main, branch: "tracktasks/x") }
        return j
    }

    @Test func blockedByTheFolder() {
        let q = queue()
        #expect(q.gitBlocked(main) == nil)
        q.jobs = [job(.running)]
        #expect(q.gitBlocked(main) != nil)
        #expect(q.gitBlocked(root.appendingPathComponent("else")) == nil)
        let w = job(.running, worktree: true)
        q.jobs = [w]
        #expect(q.gitBlocked(main) == nil && q.unmergedWorktrees(main) == 1)
        w.mergePhase = .waiting
        #expect(q.gitBlocked(main) != nil)
        w.mergePhase = nil
        w.worktreeBusy = true
        #expect(q.gitBlocked(main) != nil)
        // The folder is another repository of a task.
        let g = Job(kind: .runTask, title: "g", projectID: nil, projectName: "p", cwd: root.appendingPathComponent("app"), prompt: "x", systemPrompt: "")
        g.state = .running
        g.worktree = .init(path: root.appendingPathComponent("wt-app"), main: g.cwd, branch: "tracktasks/g")
        let part = g.addPart(main: main, worktree: .init(path: root.appendingPathComponent("wt-main"), main: main, branch: "tracktasks/g"), base: "")
        q.jobs = [g]
        #expect(q.gitBlocked(main) == nil && q.unmergedWorktrees(main) == 1)
        part.mergePhase = .waiting
        #expect(q.gitBlocked(main) != nil)
        q.jobs = []
        q.autoMerging = [main.standardizedFileURL.path]
        #expect(q.gitBlocked(main) != nil)
        q.autoMerging = []
    }

    @Test func holdsTheQueueAndLetsGoAfterAnError() async throws {
        let agent = FakeAgent(), q = queue(agent)
        let gate = DispatchSemaphore(value: 0)
        let main = main
        let op = Task { await q.exclusiveGit(main, locked: true) { () -> Result<Bool, GitRun.Failure> in
            // Never on the main thread.
            let onMain = Thread.isMainThread
            gate.wait()
            return .failure(.init(onMain ? "main" : "отказ"))
        } }
        for _ in 0..<100 where q.gitBusy.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(q.gitBlocked(main) != nil)
        let j = job(.pending)
        q.add(j)
        try await Task.sleep(for: .milliseconds(200))
        #expect(j.state == .pending && agent.runs.isEmpty)
        #expect(q.waitReason(j).contains("операцию git"))
        gate.signal()
        guard case .failure(let e) = await op.value else { Issue.record("успех"); return }
        #expect(e.message == "отказ" && q.gitBusy.isEmpty)
        for _ in 0..<100 where agent.runs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!agent.runs.isEmpty)
    }

    @Test func busyCheckLockIsNotWaitedForever() async throws {
        let q = queue()
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let main = main
        Thread.detachNewThread {
            let g = Verify.acquire(main, cancelled: { false })
            held.signal()
            release.wait()
            g?.unlock()
        }
        await GitOps.background { held.wait() }
        let r = await q.exclusiveGit(main, locked: true, wait: 0.5) { .success(true) }
        release.signal()
        guard case .failure(let e) = r else { Issue.record("замок не проверен"); return }
        #expect(e.message.contains("verify") && q.gitBusy.isEmpty)
    }
}
