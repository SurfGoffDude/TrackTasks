import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// A task on two real repositories in a temporary projects root.
@MainActor @Suite(.serialized) struct JobQueueReposTests {
    let base: URL, root: URL, app: URL, api: URL, wts: URL
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("tt-group-\(UUID().uuidString)")
        root = base.appendingPathComponent("Projects")
        app = root.appendingPathComponent("app")
        api = root.appendingPathComponent("api")
        wts = base.appendingPathComponent("worktrees")
        for d in [app, api, base.appendingPathComponent("outside")] { try repo(d) }
    }

    private func repo(_ d: URL) throws {
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", at: d)
        for (k, v) in ["user.name": "t", "user.email": "t@t", "commit.gpgsign": "false"] { git("config", k, v, at: d) }
        try write("1\n", d, "f.txt")
        git("add", "-A", at: d)
        git("commit", "-q", "-m", "base", at: d)
    }
    @discardableResult private func git(_ args: String..., at dir: URL) -> String {
        let r = Worktrees.git(args, in: dir)
        #expect(r.ok, "\(args): \(r.err)")
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func write(_ text: String, _ dir: URL, _ name: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private func read(_ dir: URL, _ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    private func wait(_ what: String = "", _ until: () -> Bool) async throws {
        for _ in 0..<200 where !until() { try await Task.sleep(for: .milliseconds(50)) }
        try #require(until(), "\(what)")
    }

    private func queue(_ agent: FakeAgent) -> JobQueue {
        let r = root, w = wts
        let q = JobQueue(storeURL: base.appendingPathComponent("queue.json"), agents: AgentRegistry([agent]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "Fake", agent: AgentID(rawValue: "fake"), model: "m1")], defaultID: "fake") },
                         dangerMode: { DangerMode() }, projectsRoot: { r }, worktreesRoot: w, recordSpend: { _, _, _, _ in })
        q.paused = false
        return q
    }
    private func task(_ repos: [String]) -> Job {
        let j = Job(kind: .runTask, title: "Две папки", projectID: nil, projectName: "app", cwd: app, prompt: "сделай", systemPrompt: "sys")
        j.repos = repos
        return j
    }
    /// Runs the task; the agent writes `text` to f.txt of both.
    private func finished(_ q: JobQueue, _ agent: FakeAgent) async throws -> Job {
        let j = task(["api"])
        q.add(j)
        try await wait("start: \(j.lastLine)") { agent.runs.first?.request != nil }
        for m in j.members { try write("новое\n", try #require(m.worktree).path, "f.txt") }
        agent.runs[0].finish()
        try await wait { !j.isActive }
        // Automatic review, if it is on, ends at once.
        for c in q.jobs where c.parentID == j.id { q.cancel(c) }
        try await wait { !q.hasActiveChild(j) }
        return j
    }

    @Test func changesBothOnTheirBranches() async throws {
        let agent = FakeAgent(), q = queue(agent)
        let j = task(["api"])
        q.add(j)
        try await wait("start: \(j.lastLine)") { agent.runs.first?.request != nil }
        let part = try #require(j.parts.first)
        let w = try #require(j.worktree), pw = try #require(part.worktree)
        let r = try #require(agent.runs[0].request)
        #expect(r.cwd == w.path && r.addDirs.contains(pw.path))
        #expect(r.systemPrompt.contains(pw.branch) && r.systemPrompt.contains(pw.path.path))
        #expect(w.path.path.hasPrefix(wts.path) && pw.path.path.hasPrefix(wts.path))
        try write("a\n", w.path, "f.txt")
        try write("b\n", pw.path, "f.txt")
        agent.runs[0].finish()
        try await wait { !j.isActive }
        #expect(j.state == .done && j.committed && part.committed && j.awaitsMerge)
        #expect(git("show", "\(w.branch):f.txt", at: app) == "a")
        #expect(git("show", "\(pw.branch):f.txt", at: api) == "b")
        #expect(read(app, "f.txt") == "1\n" && read(api, "f.txt") == "1\n")
        #expect(DiffSource(job: part).folder == pw.path && DiffSource(job: part).jobID == j.id)
        #expect(q.forkBlocked(j) != nil)
        let orphans = await q.orphanWorktrees()
        #expect(Set(orphans.map(\.path)).isDisjoint(with: [w.path, pw.path]))
        for c in q.jobs where c.parentID == j.id { q.cancel(c) }
        try await wait { !q.hasActiveChild(j) }

        #expect(await q.mergeGroup(j, ask: false))
        #expect(read(app, "f.txt") == "a\n" && read(api, "f.txt") == "b\n")
        #expect(j.merged && part.merged && !j.hasWorktree && !j.awaitsMerge)
        #expect(!FileManager.default.fileExists(atPath: w.path.path) && !FileManager.default.fileExists(atPath: pw.path.path))
    }

    /// Only the extra repository changed: the folder of the session stays until that is merged.
    @Test func unchangedMainStays() async throws {
        let agent = FakeAgent(), q = queue(agent)
        let j = task(["api"])
        q.add(j)
        try await wait { agent.runs.first?.request != nil }
        try write("b\n", try #require(j.parts.first?.worktree).path, "f.txt")
        agent.runs[0].finish()
        try await wait { !j.isActive }
        #expect(j.worktree != nil && !j.committed && j.awaitsMerge)
        for c in q.jobs where c.parentID == j.id { q.cancel(c) }
        try await wait { !q.hasActiveChild(j) }
        #expect(await q.mergeGroup(j, ask: false))
        #expect(read(api, "f.txt") == "b\n" && !j.hasWorktree)
    }

    @Test func nothingChangedRemovesAll() async throws {
        let agent = FakeAgent(), q = queue(agent)
        let j = task(["api"])
        q.add(j)
        try await wait { agent.runs.first?.request != nil }
        let dirs = j.members.compactMap { $0.worktree?.path.path }
        agent.runs[0].finish()
        try await wait { !j.isActive }
        #expect(dirs.count == 2 && !j.hasWorktree)
        try await wait { !dirs.contains { FileManager.default.fileExists(atPath: $0) } }
    }

    @Test func outsideTheRootIsRefused() async throws {
        let agent = FakeAgent(), q = queue(agent)
        let j = task(["../outside"])
        q.add(j)
        try await wait { !j.isActive }
        #expect(j.state == .failed && j.lastLine.contains("внутри корня"))
        #expect(agent.runs.isEmpty && !FileManager.default.fileExists(atPath: wts.path))
        // Swapped for a symlink after the queue resolved it.
        let moved = JobQueue.makeGroup(cwd: app, title: "t", id: UUID(), repos: ["../outside"], expected: [api], projectsRoot: root, worktrees: wts)
        #expect(throws: TaskRepos.Failure.self) { try moved.get() }
        #expect(!FileManager.default.fileExists(atPath: wts.path))
    }

    /// A server has a copy of one repository only.
    @Test func agentOnServerIsRefused() async throws {
        let agent = FakeAgent("fake", [.resume, .remote]), q = queue(agent)
        let j = task(["api"])
        q.add(j)
        try await wait { !j.isActive }
        #expect(j.state == .failed && j.lastLine.contains("на сервере"))
        #expect(agent.runs.isEmpty && !FileManager.default.fileExists(atPath: wts.path))
    }

    /// The second worktree can't be made: the first one and its branch are gone.
    @Test func allOrNothing() throws {
        let id = UUID(), short = String(id.uuidString.prefix(6)).lowercased()
        git("branch", "tracktasks/t-\(short)", at: api)
        let r = JobQueue.makeGroup(cwd: app, title: "t", id: id, repos: ["api"], expected: [URL(fileURLWithPath: TaskRepos.canonical(api))],
                                   projectsRoot: root, worktrees: wts)
        guard case .failure(let f) = r else { Issue.record("must fail"); return }
        #expect(f.message.contains("«api»"))
        #expect(git("branch", "--list", "tracktasks/*", at: app).isEmpty)
        #expect(git("worktree", "list", at: app).split(separator: "\n").count == 1)
    }

    /// A conflict in one repository neither stops the other nor hides its state, also after a restart.
    @Test func failureOfOneKeepsTheOther() async throws {
        for conflictInMain in [true, false] {
            let agent = FakeAgent(), q = queue(agent)
            let j = try await finished(q, agent)
            let part = try #require(j.parts.first)
            let bad = conflictInMain ? j : part, good = conflictInMain ? part : j
            try write("чужое\n", bad.cwd, "f.txt")
            git("commit", "-qam", "other", at: bad.cwd)
            #expect(!(await q.mergeGroup(j, ask: false)))
            #expect(good.merged && !bad.merged && bad.mergeFailed && j.awaitsMerge)
            #expect(read(good.cwd, "f.txt") == "новое\n" && read(bad.cwd, "f.txt") == "чужое\n")
            #expect(j.worktree != nil && bad.worktreeNote.contains("Конфликт") && good.worktreeNote.contains("Слито"))
            #expect(j.groupSummary == "Слито 1 из 2 · \(bad.repoName): конфликт")
            #expect(q.resolvable.contains { $0 === bad } && q.notMergeable.contains { $0.job === j })

            let enc = JSONEncoder(), dec = JSONDecoder()
            let saved = Job(try dec.decode(JobRecord.self, from: enc.encode(j.record)))
            #expect(saved.groupSummary == j.groupSummary && saved.awaitsMerge && saved.repos == ["api"])
            #expect(saved.parts.first?.worktreeNote == part.worktreeNote && saved.parts.first?.home === saved)

            // The agent resolves it in that repository; the session stays in the project's worktree.
            let runs = agent.runs.count
            q.requestResolve(bad)
            try await wait { agent.runs.count > runs && agent.runs.last?.request != nil }
            let run = try #require(agent.runs.last), fix = try #require(q.jobs.last)
            #expect(run.request?.cwd == j.worktree?.path && fix.targetRepo == (conflictInMain ? nil : part.cwd.path))
            let badTree = try #require(bad.worktree), dir = badTree.path
            #expect(run.request?.prompt.contains(badTree.branch) == true)
            _ = Worktrees.git(["merge", "--no-edit", git("rev-parse", "HEAD", at: bad.cwd)], in: dir)
            try write("оба\n", dir, "f.txt")
            git("commit", "-qam", "resolved", at: dir)
            run.finish()
            try await wait { !fix.isActive }
            #expect(!bad.mergeFailed)
            #expect(await q.mergeGroup(j, ask: false))
            #expect(read(bad.cwd, "f.txt") == "оба\n" && !j.hasWorktree && j.groupSummary == "Слито 2 из 2")
            try write("1\n", app, "f.txt")
            try write("1\n", api, "f.txt")
            for d in [app, api] { git("commit", "-qam", "reset", at: d) }
        }
    }

    @Test func oldAndBrokenRecords() throws {
        let j = task([])
        let data = try JSONEncoder().encode(j.record)
        var o = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(o["repos"] == nil && o["extraRepos"] == nil)
        #expect(Job(try JSONDecoder().decode(JobRecord.self, from: data)).parts.isEmpty)
        // One bad value costs only itself.
        o["extraRepos"] = [["main": app.absoluteString, "committed": "да", "merged": true], 5]
        let odd = Job(try JSONDecoder().decode(JobRecord.self, from: JSONSerialization.data(withJSONObject: o)))
        #expect(odd.parts.count == 1 && odd.parts[0].merged && !odd.parts[0].committed)
        o["extraRepos"] = "x"
        #expect(Job(try JSONDecoder().decode(JobRecord.self, from: JSONSerialization.data(withJSONObject: o))).parts.isEmpty)
    }

    /// Full access only when the mode is on in every repository; the autopilot never merges a group.
    @Test func dangerNeedsEveryRepository() {
        var mode = DangerMode()
        let on = mode.enable(app.path, name: "a", typed: "a", .hour, autopilot: true, now: Date())
        #expect(on)
        var current = mode
        let r = root
        let q = JobQueue(storeURL: base.appendingPathComponent("q2.json"), agents: AgentRegistry([FakeAgent()]),
                         dangerMode: { current }, projectsRoot: { r }, worktreesRoot: wts, recordSpend: { _, _, _, _ in })
        let j = task(["api"])
        q.resolveRepos(j)
        #expect(!q.allows(.fullAccess, j))
        let both = current.enable(TaskRepos.canonical(api), name: "b", typed: "b", .hour, autopilot: true, now: Date())
        #expect(both)
        #expect(q.allows(.fullAccess, j) && !q.onAutopilot(j))
    }

    @Test func checkpointRollsBackTogether() async throws {
        let agent = FakeAgent(), q = queue(agent)
        let j = try await finished(q, agent)
        let part = try #require(j.parts.first), w = try #require(j.worktree)
        let first = try #require(try await q.checkpoints(w).get().first)
        #expect(await q.rollback(j, to: first, talk: false) == nil)
        let pw = try #require(part.worktree)
        #expect(read(w.path, "f.txt") == "1\n" && read(pw.path, "f.txt") == "1\n")
        #expect(!j.rolledBack.isEmpty && !part.rolledBack.isEmpty)
        #expect(!(await q.mergeGroup(j, ask: true)) && !j.merged && !part.merged)
        #expect(await q.commitRollback(j) == nil)
        #expect(j.rolledBack.isEmpty && part.rolledBack.isEmpty)
    }

    /// Restart with nothing, one or the other repository landed: the task never stays busy and nothing is lost.
    @Test func recoveryFreesTheTask() async throws {
        for landed in ["none", "main", "part"] {
            let agent = FakeAgent(), q = queue(agent)
            let j = try await finished(q, agent)
            let part = try #require(j.parts.first)
            let m = landed == "main" ? j : part
            if landed != "none" {
                let b = try #require(m.worktree).branch
                let c = git("commit-tree", "-p", "HEAD", "-p", b, "-m", "c", "\(b)^{tree}", at: m.cwd)
                git("update-ref", "refs/tracktasks/merge-land/\(b)", c, at: m.cwd)
                git("merge", "-q", "--ff-only", c, at: m.cwd)
            }
            q.recoverMerges()
            #expect(j.worktreeBusy && part.worktreeBusy)
            try await wait("busy: \(landed)") { !j.worktreeBusy && !part.worktreeBusy }
            #expect(j.merged == (landed == "main") && part.merged == (landed == "part"), "\(landed)")
            #expect(j.worktree != nil && j.awaitsMerge)
            #expect(await q.mergeGroup(j, ask: false), "\(landed)")
            #expect(!j.hasWorktree && !j.worktreeBusy && read(app, "f.txt") == "новое\n" && read(api, "f.txt") == "новое\n")
            for d in [app, api] {
                try write("1\n", d, "f.txt")
                git("commit", "-qam", "reset", at: d)
            }
        }
    }

    /// Both pull requests are merged and pulled; settled one after another, the session's folder goes last.
    @Test func pullRequestsSettleSeparately() async throws {
        for together in [true, false] {
            let agent = FakeAgent(), q = queue(agent)
            let j = try await finished(q, agent)
            let part = try #require(j.parts.first), folder = try #require(j.worktree).path.path
            for m in j.members {
                let b = try #require(m.worktree).branch, tip = git("rev-parse", b, at: m.cwd)
                var link = PullRequestLink(pr: PullRequest(number: 1, url: "https://example.invalid/1", headOid: tip, base: "main"), remote: "origin", pushedOid: tip)
                m.pullRequest = link
                // An open one: not merged locally past the review.
                #expect(m.hasLivePR)
                git("merge", "-q", "--no-ff", "-m", "pr", b, at: m.cwd)
                link.pr.state = .merged
                link.pr.mergeOid = git("rev-parse", "HEAD", at: m.cwd)
                m.pullRequest = link
            }
            if together {
                q.settlePR(j)
                q.settlePR(part)
            } else {
                q.settlePRs(in: app.path)
                try await wait { j.merged && !j.worktreeBusy }
                #expect(!part.merged && j.worktree != nil && FileManager.default.fileExists(atPath: folder))
                q.settlePRs(in: api.path)
            }
            try await wait("settled, together: \(together)") { j.merged && part.merged && !j.hasWorktree && !j.worktreeBusy }
            #expect(!FileManager.default.fileExists(atPath: folder) && !j.awaitsMerge)
            for d in [app, api] {
                try write("1\n", d, "f.txt")
                git("commit", "-qam", "reset", at: d)
            }
        }
    }

    @Test func openPullRequestHoldsOnlyItsRepository() async throws {
        let agent = FakeAgent(), q = queue(agent)
        let j = try await finished(q, agent)
        let part = try #require(j.parts.first)
        part.pullRequest = PullRequestLink(pr: PullRequest(number: 7, url: "https://example.invalid/7"), remote: "origin", pushedOid: "")
        #expect(!(await q.mergeGroup(j, ask: true)))
        #expect(j.merged && !part.merged && part.worktreeNote.contains("PR #7"))
        #expect(j.worktree != nil && j.groupSummary == "Слито 1 из 2 · api: открыт PR")
    }

    /// `verify` of the extra repository fails: its name goes to the agent, then it is fixed.
    @Test func verifyOfTheExtraRepository() async throws {
        try write("---\nverify: grep -q ok f.txt\n---\n", api, "about.md")
        git("add", "-A", at: api)
        git("commit", "-qm", "about", at: api)
        let agent = FakeAgent(), q = queue(agent)
        let j = task(["api"])
        q.add(j)
        try await wait("start: \(j.lastLine)") { agent.runs.first?.request != nil }
        let dir = try #require(j.parts.first?.worktree).path
        try write("плохо\n", dir, "f.txt")
        agent.runs[0].finish()
        try await wait("second run") { agent.runs.count > 1 && agent.runs[1].request != nil }
        let prompt = try #require(agent.runs[1].request).prompt
        #expect(prompt.contains("grep -q ok f.txt") && prompt.contains("«api»") && prompt.contains(dir.path))
        try write("ok\n", dir, "f.txt")
        agent.runs[1].finish()
        try await wait { !j.isActive }
        #expect(j.state == .done && !j.verifyFailed && j.verifyAttempts == 1 && j.verifyNote.contains("api: grep"))

        // Broken in main meanwhile: the check with main is red only there.
        for c in q.jobs where c.parentID == j.id { q.cancel(c) }
        try await wait { !q.hasActiveChild(j) }
        try write("---\nverify: \"false\"\n---\n", api, "about.md")
        git("commit", "-qam", "red", at: api)
        #expect(!(await q.mergeGroup(j, ask: false)))
        let part = try #require(j.parts.first)
        #expect(part.mergeCheck?.state == .red && j.mergeCheck?.state != .red && j.groupSummary.contains("api: проверка красная"))
    }

    /// A pipeline over both repositories: a step that changed only the extra one counts, the review watches it,
    /// nothing is merged before the end.
    @Test func pipelineCoversEveryRepository() async throws {
        let agent = FakeAgent(), q = queue(agent)
        let j = task(["api"])
        var w = Workflow(steps: [.init(title: "Код", type: .code), .init(title: "Ревью", type: .review)])
        for i in w.steps.indices { w.steps[i].agent = "fake" }
        q.beginPipeline(j, name: "main", workflow: w)
        q.add(j)
        try await wait("start: \(j.lastLine)") { agent.runs.first?.request != nil }
        let part = try #require(j.parts.first), pw = try #require(part.worktree)
        try write("b\n", pw.path, "f.txt")
        agent.runs[0].finish()
        try await wait("review") { agent.runs.count > 1 && agent.runs[1].request != nil }
        #expect(part.committed && !j.committed && j.worktree != nil && part.pipelineOpen)
        #expect(agent.runs[1].request?.prompt.contains(pw.path.path) == true)
        #expect(!(await q.mergeNow(part, ask: false)) && !part.merged)
        // The reviewer touched the other repository.
        try write("подмена\n", pw.path, "f.txt")
        agent.runs[1].finish { $0.resultText = "ВЕРДИКТ: ОК" }
        try await wait("stopped") { j.pipeline?.gate != nil }
        #expect(j.verdict == nil && j.pipelineOpen && !part.merged)
        #expect(!(await q.mergeNow(part, ask: false)) && part.worktreeNote.contains(JobQueue.pipelineUnfinished))
        #expect(Job(j.record).pipeline == j.pipeline && Job(j.record).parts.count == 1)
    }
}
