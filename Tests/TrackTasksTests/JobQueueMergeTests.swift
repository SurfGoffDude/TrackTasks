import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// The real queue and git in a temporary repository; `verify` is a shell command.
@MainActor @Suite(.serialized) struct JobQueueMergeTests {
    let root: URL, main: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-merge-\(UUID().uuidString)")
        main = root.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main")
        for (k, v) in ["user.name": "t", "user.email": "t@t", "commit.gpgsign": "false"] { git("config", k, v) }
        // Branch "b" breaks it: the two files can't be together.
        try "---\nname: p\nverify: \"! { test -f a.txt && test -f b.txt; }\"\n---\n".write(to: main.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
        try "1\n".write(to: main.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        git("add", "-A")
        git("commit", "-q", "-m", "base")
    }

    @discardableResult private func git(_ args: String..., at dir: URL? = nil) -> Worktrees.Result {
        let r = Worktrees.git(args, in: dir ?? main)
        #expect(r.ok, "\(args): \(r.err)")
        return r
    }
    private func has(_ f: String) -> Bool { FileManager.default.fileExists(atPath: main.appendingPathComponent(f).path) }

    private func queue(_ agent: FakeAgent? = nil) -> JobQueue {
        let a = agent ?? FakeAgent()
        return JobQueue(storeURL: root.appendingPathComponent("queue.json"), agents: AgentRegistry([a]),
                 profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "Fake", agent: AgentID(rawValue: "fake"), model: "m1")], defaultID: "fake") },
                 dangerMode: { DangerMode() }, recordSpend: { _, _, _, _ in })
    }
    private func done(_ name: String, at t: TimeInterval) throws -> Job {
        let wt = root.appendingPathComponent(name)
        git("worktree", "add", "-q", "-b", "tracktasks/\(name)", wt.path)
        try name.write(to: wt.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        git("add", "-A", at: wt)
        git("commit", "-q", "-m", name, at: wt)
        let j = Job(kind: .runTask, title: name, projectID: nil, projectName: "p", cwd: main, prompt: "x", systemPrompt: "",
                    created: Date(timeIntervalSince1970: t))
        j.agent = AgentID(rawValue: "fake")
        j.sessionID = "s1"
        j.state = .done
        j.committed = true
        j.worktree = .init(path: wt, main: main, branch: "tracktasks/\(name)")
        j.baseCommit = git("rev-parse", "HEAD").out.trimmingCharacters(in: .whitespacesAndNewlines)
        return j
    }

    @Test func guideSaysWhatTheCardOffers() throws {
        let q = queue()
        let a = try done("a", at: 1), b = try done("b", at: 2)
        q.jobs = [a, b]
        #expect(q.guide(a).primary == .merge && q.guide(a).need == .merge)
        #expect(q.offers(a)[.discard]?.blocked == nil && q.offers(a)[.diff] != nil && q.offers(a)[.pullRequest] != nil)
        a.worktreeBusy = true
        #expect(q.guide(a).primary == nil && q.offers(a)[.merge]?.blocked != nil && q.offers(a)[.discard]?.blocked != nil)
        a.worktreeBusy = false
        b.mergeFailed = true
        // A running follow-up's request belongs to the task's card.
        let child = Job(kind: .fix, title: "fix", projectID: nil, projectName: "p", cwd: main, prompt: "", systemPrompt: "")
        child.parentID = a.id
        child.state = .running
        q.jobs = [a, b, child]
        #expect(q.waitingForYou.map(\.need) == [.conflict])
        #expect(q.offers(a)[.merge]?.blocked != nil && q.cardJob(child) === a)
        child.permissions = [PermissionRequest(id: "r", tool: "Bash", title: "ls")]
        #expect(q.waitingForYou.map(\.need) == [.permission, .conflict] && q.guide(a).card == .permission)
    }

    @Test func mergeAllSkipsTheRedOne() async throws {
        let agent = FakeAgent(), q = queue(agent)
        let a = try done("a", at: 1), b = try done("b", at: 2), c = try done("c", at: 3)
        q.jobs = [a, b, c]
        try "правка\n".write(to: main.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        let batch = try #require(await q.mergeAll())
        #expect(batch.merged == 2 && batch.skipped.map(\.title) == ["b"])
        #expect(batch.skipped.first?.reason.contains("проверка не проходит") == true)
        #expect(a.merged && !b.merged && c.merged)
        #expect(has("a.txt") && !has("b.txt") && has("c.txt"))
        #expect(try String(contentsOf: main.appendingPathComponent("local.txt"), encoding: .utf8) == "правка\n")
        #expect(a.worktree == nil && b.worktree != nil)
        #expect(!q.mergeable.contains { $0 === b })
        // The check survives a restart.
        let restored = Job(b.record)
        #expect(restored.mergeCheck?.state == .red)

        // «Исправить» continues the task's session and doesn't count as a review fix.
        q.requestMergeFix(b)
        let fix = try #require(q.jobs.first { $0.fixesMergeCheck })
        #expect(Job(fix.record).fixesMergeCheck)
        for _ in 0..<100 where agent.runs.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let run = try #require(agent.runs.first)
        #expect(run.request?.resume == "s1")
        #expect(run.request?.prompt.contains("test -f a.txt") == true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("b/a.txt"))
        run.finish()
        for _ in 0..<100 where fix.isActive { try await Task.sleep(for: .milliseconds(50)) }
        #expect(fix.state == .done && !b.reviewFixed && b.mergeCheck == nil)
        #expect(q.mergeable.contains { $0 === b })
        #expect(await q.mergeNow(b))
        #expect(has("b.txt") && !has("a.txt"))
    }

    /// The agent couldn't repair it: the red record stays, the branch isn't offered for «Слить все».
    @Test func failedFixStaysRed() async throws {
        let agent = FakeAgent(), q = queue(agent)
        let a = try done("a", at: 1), b = try done("b", at: 2)
        q.jobs = [a, b]
        _ = await q.mergeAll()
        q.requestMergeFix(b)
        let fix = try #require(q.jobs.first { $0.fixesMergeCheck })
        for n in 1...(JobQueue.maxVerifyAttempts + 1) {
            for _ in 0..<200 where agent.runs.count < n { try await Task.sleep(for: .milliseconds(50)) }
            try #require(agent.runs.count == n)
            agent.runs[n - 1].finish()
        }
        for _ in 0..<200 where fix.isActive { try await Task.sleep(for: .milliseconds(50)) }
        #expect(fix.state == .done && fix.verifyFailed && b.mergeCheck?.state == .red)
        #expect(b.worktreeNote.contains("Исправить не удалось"))
        #expect(!q.mergeable.contains { $0 === b } && !has("b.txt"))
    }

    /// Stopped during the check, which left a file: it is remembered, also across a restart.
    @Test func cancelKeepsArtifacts() async throws {
        let about = main.appendingPathComponent("about.md")
        try "---\nverify: touch out.log; sleep 60\n---\n".write(to: about, atomically: true, encoding: .utf8)
        let q = queue(), a = try done("a", at: 1)
        q.jobs = [a]
        q.merge(a)
        let log = root.appendingPathComponent("a/out.log").path
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: log) { try await Task.sleep(for: .milliseconds(50)) }
        q.cancelMerge(a)
        for _ in 0..<200 where a.worktreeBusy { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!a.merged && a.mergeCheck == nil && a.mergeArtifacts == ["out.log"])
        let data = try JSONEncoder().encode(a.record)
        #expect(Job(try JSONDecoder().decode(JobRecord.self, from: data)).mergeArtifacts == ["out.log"])
        // A record of an older version has the list only in the check.
        var old = a.record
        old.mergeArtifacts = nil
        #expect(Job(old).mergeArtifacts.isEmpty)
        old.mergeCheck = .init(state: .red, branchCommit: "", mainCommit: "", mainBranch: "main", command: "x", artifacts: ["x.log"])
        #expect(Job(old).mergeArtifacts == ["x.log"])
        try "---\nverify: \"true\"\n---\n".write(to: about, atomically: true, encoding: .utf8)
        #expect(await q.mergeNow(a))
        #expect(has("a.txt") && !has("out.log") && a.worktreeNote.contains("out.log") && a.mergeArtifacts.isEmpty)
    }

    @Test func cancelKillsTheCheck() async throws {
        try "---\nverify: sleep 60\n---\n".write(to: main.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
        let q = queue(), a = try done("a", at: 1)
        q.jobs = [a]
        q.merge(a)
        for _ in 0..<200 where a.mergePhase != .checking { try await Task.sleep(for: .milliseconds(50)) }
        #expect(a.mergePhase == .checking && a.worktreeBusy)
        q.requestReview(a)
        #expect(q.jobs.count == 1)
        q.cancelMerge(a)
        for _ in 0..<200 where a.worktreeBusy { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!a.worktreeBusy && a.mergePhase == nil && !a.merged && !has("a.txt"))
        #expect(a.worktreeNote.contains("остановлено"))
    }

    /// The app died after main was moved: the next start marks the branch merged and removes the worktree.
    @Test func restartFinishesALandedMerge() async throws {
        let a = try done("a", at: 1)
        let c = git("commit-tree", "-p", "HEAD", "-p", "tracktasks/a", "-m", "c", "tracktasks/a^{tree}").out.trimmingCharacters(in: .whitespacesAndNewlines)
        git("update-ref", "refs/tracktasks/merge-land/tracktasks/a", c)
        git("merge", "-q", "--ff-only", c)
        let q = queue()
        q.jobs = [a]
        q.recoverMerges()
        #expect(a.worktreeBusy)
        for _ in 0..<200 where a.worktreeBusy { try await Task.sleep(for: .milliseconds(50)) }
        #expect(a.merged && a.worktree == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
    }
}
