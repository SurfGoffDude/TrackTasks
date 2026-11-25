import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// `verify:` of a task in the real queue and git; every command leaves a marker outside of the repository.
@MainActor @Suite(.serialized) struct TaskVerifyQueueTests {
    let root: URL, main: URL, task: URL, mark: URL
    let store: TaskVerifyStore
    let agent = FakeAgent()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-tverify-\(UUID().uuidString)")
        main = root.appendingPathComponent("main")
        task = main.appendingPathComponent("tasks/20261124-000000-x.md")
        mark = root.appendingPathComponent("mark")
        store = TaskVerifyStore(nil)
        try FileManager.default.createDirectory(at: task.deletingLastPathComponent(), withIntermediateDirectories: true)
        try about("true")
        try "1\n".write(to: main.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try "tasks/\n".write(to: main.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        git("init", "-q", "-b", "main")
        for (k, v) in ["user.name": "t", "user.email": "t@t", "commit.gpgsign": "false"] { git("config", k, v) }
        git("add", "-A")
        git("commit", "-q", "-m", "base")
    }

    private func git(_ args: String..., at dir: URL? = nil) {
        let r = Worktrees.git(args, in: dir ?? main)
        #expect(r.ok, "\(args): \(r.err)")
    }
    private func about(_ verify: String) throws {
        try "---\nverify: \(verify)\n---\n".write(to: main.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
    }
    private func put(_ verify: String, _ extra: String = "") throws {
        let line = verify.isEmpty ? "" : "verify: \(Frontmatter.quote(verify))\n"
        try "---\ntitle: \"x\"\nstatus: done\ncompleted: 2026-11-24\n\(extra)\(line)---\n\nт\n".write(to: task, atomically: true, encoding: .utf8)
    }
    private var touch: String { "touch '\(mark.path)'" }
    private var marked: Bool { FileManager.default.fileExists(atPath: mark.path) }
    private func has(_ f: String) -> Bool { FileManager.default.fileExists(atPath: main.appendingPathComponent(f).path) }
    private func approve(_ c: String) { store.approve(c, main, task.lastPathComponent) }
    private func wait(_ what: String = "", _ done: () -> Bool) async throws {
        for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(25)) }
        try #require(done(), "\(what)")
    }

    private func queue(autopilot: Bool = false) throws -> JobQueue {
        var mode = DangerMode()
        if autopilot {
            let on = mode.enable(main.path, name: "p", typed: "p", .hour, autopilot: true, verify: "true", now: Date().addingTimeInterval(-1))
            #expect(on)
        }
        let m = mode
        let q = JobQueue(storeURL: root.appendingPathComponent("queue.json"), agents: AgentRegistry([agent]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "Fake", agent: AgentID(rawValue: "fake"), model: "m1")], defaultID: "fake") },
                         dangerMode: { m }, taskVerifyStore: store, worktreesRoot: root.appendingPathComponent("wts"), recordSpend: { _, _, _, _ in })
        q.paused = false
        return q
    }

    /// A finished task with a commit in its branch.
    private func done(queued: String?) -> Job {
        let wt = root.appendingPathComponent("wt")
        git("worktree", "add", "-q", "-b", "tracktasks/x", wt.path)
        try? "new".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("add", "-A", at: wt)
        git("commit", "-q", "-m", "x", at: wt)
        let j = Job(kind: .runTask, title: "x", projectID: nil, projectName: "p", cwd: main, prompt: "x", systemPrompt: "", taskPath: task.path)
        j.agent = AgentID(rawValue: "fake")
        j.sessionID = "s1"
        j.state = .done
        j.committed = true
        j.worktree = .init(path: wt, main: main, branch: "tracktasks/x")
        j.taskVerify = queued
        j.verdict = .ok
        return j
    }

    /// A task of the main folder, queued.
    private func start(_ q: JobQueue, project: String = "") async throws -> Job {
        let j = Job(kind: .runTask, title: "x", projectID: nil, projectName: "p", cwd: main, prompt: "x", systemPrompt: "", taskPath: task.path)
        j.mustUseMain = true
        j.verifyCommand = project
        q.add(j)
        try await wait("старт \(j.lastLine)") { agent.runs.first?.request != nil }
        return j
    }

    // MARK: Merge

    @Test func withoutTheFieldNothingChanges() async throws {
        try put("")
        let q = try queue(), j = done(queued: nil)
        q.jobs = [j]
        #expect(!q.hasTaskCheck(j))
        #expect(await q.mergeNow(j))
        #expect(has("a.txt") && j.mergeCheck?.state == .passed && j.mergeCheck?.taskCommand == nil)
        // A record of an older version.
        var o = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(j.record)) as? [String: Any])
        o["taskVerify"] = nil
        let back = Job(try JSONDecoder().decode(JobRecord.self, from: JSONSerialization.data(withJSONObject: o)))
        #expect(back.taskVerify == nil && !q.hasTaskCheck(back))
        j.taskVerify = "a"
        #expect(Job(j.record).taskVerify == "a")
    }

    @Test func bothChecksPassAndMerge() async throws {
        try put("test -f a.txt && " + touch)
        approve("test -f a.txt && " + touch)
        let q = try queue(), j = done(queued: "")
        q.jobs = [j]
        #expect(await q.mergeNow(j))
        #expect(marked && has("a.txt") && j.mergeCheck?.state == .passed)
    }

    @Test func redTaskCheckStopsAndGoesToTheAgent() async throws {
        try put("false")
        approve("false")
        let q = try queue(), j = done(queued: "false")
        q.jobs = [j]
        #expect(await !q.mergeNow(j))
        #expect(!has("a.txt") && j.mergeCheck?.state == .red && j.worktreeNote.contains("(false)"))
        #expect(!q.mergeable.contains { $0 === j })
        q.requestMergeFix(j)
        let fix = try #require(q.jobs.first { $0.fixesMergeCheck })
        #expect(fix.verifyCommand == "true" && fix.prompt.contains("`false`") && fix.taskVerify == "false")
    }

    /// The task can't weaken the project's check.
    @Test func redProjectCheckStaysRed() async throws {
        try about("\"false\"")
        try put("true || " + touch)
        approve("true || " + touch)
        let q = try queue(), j = done(queued: "")
        q.jobs = [j]
        #expect(await !q.mergeNow(j))
        #expect(!has("a.txt") && j.mergeCheck?.state == .red && j.mergeCheck?.taskFailed == nil)
        try about("")
        #expect(await q.mergeNow(j))
        #expect(j.mergeCheck?.state == .unverified && j.worktreeNote.contains("не проверено"))
    }

    enum Case: String, CaseIterable { case unapproved, changed, removed, missing, invalid }

    /// Not run, not passed, not merged — with the autopilot and dangerous mode on too.
    @Test(arguments: Case.allCases, [false, true]) func unapprovedIsNeverRun(_ c: Case, autopilot: Bool) async throws {
        switch c {
        case .unapproved: try put(touch)
        case .changed: try put(touch); approve("true")
        case .removed: try put(""); approve(touch)
        case .missing: approve(touch)
        case .invalid:
            try put(touch)
            let t = try String(contentsOf: task, encoding: .utf8)
            try t.replacingOccurrences(of: "status:", with: "Verify: true\nstatus:").write(to: task, atomically: true, encoding: .utf8)
            approve(touch)
        }
        let q = try queue(autopilot: autopilot), j = done(queued: touch)
        q.jobs = [j]
        if autopilot {
            q.pump()
            if c == .missing { try await Task.sleep(for: .milliseconds(300)) }
            else { try await wait { j.auto.parked != nil } ; #expect(j.auto.parked?.hasPrefix(Autopilot.taskCheckReason) == true) }
        }
        #expect(await !q.mergeNow(j))
        #expect(await !q.mergeNow(j, force: true))
        _ = await q.mergeAll()
        #expect(!marked && !has("a.txt") && !j.merged && j.worktreeNote.contains("проверка задачи не запущена"))
        #expect(j.taskCheckRefusal != nil && (j.taskCheckRefusal?.ask == nil) == (c == .missing || c == .invalid))
    }

    @Test(arguments: ["source: https://x/1\n", "automation: a.md\n"]) func outsideTasksNeedApprovalToo(_ extra: String) async throws {
        try put(touch, extra)
        let q = try queue(autopilot: true), j = done(queued: nil)
        q.jobs = [j]
        q.pump()
        #expect(await !q.mergeNow(j))
        #expect(!marked && !has("a.txt"))
    }

    /// The command is edited while the check runs: what has passed is not what is written now.
    @Test func changeDuringTheMergeStopsIt() async throws {
        let cmd = "sed -i '' 's/^verify:.*/verify: \"true\"/' '\(task.path)'"
        try put(cmd)
        approve(cmd)
        let q = try queue(), j = done(queued: cmd)
        q.jobs = [j]
        #expect(await !q.mergeNow(j))
        #expect(!has("a.txt") && j.worktreeNote.contains("проверка задачи"))
    }

    @Test func approvalTakesExactlyWhatWasShownAndUnparks() async throws {
        try put("true")
        let q = try queue(autopilot: true), j = done(queued: "true")
        q.jobs = [j]
        q.pump()
        try await wait { j.auto.parked != nil }
        let shown = try #require(j.taskCheckRefusal)
        #expect(shown.ask == "true")
        // Edited after it was shown: the new text is not approved.
        try put(touch)
        q.approveTaskCheck(j, shown)
        #expect(j.auto.parked != nil && j.taskCheckRefusal?.ask == touch && j.taskCheckRefusal?.approved == "true" && !marked)
        q.approveTaskCheck(j, try #require(j.taskCheckRefusal))
        #expect(j.auto.parked == nil)
        try await wait("слияние: \(j.worktreeNote)") { j.merged }
        #expect(marked && has("a.txt"))
        // Nothing of it in the task file or in the queue.
        #expect(!String(decoding: try JSONEncoder().encode(j.record), as: UTF8.self).contains("pproved"))
    }

    @Test func anotherPauseIsNotTakenOff() async throws {
        try put("true")
        let q = try queue(autopilot: true), j = done(queued: "true")
        j.auto.parked = "открыт PR"
        q.jobs = [j]
        q.refreshTaskChecks()
        q.approveTaskCheck(j, try #require(j.taskCheckRefusal))
        #expect(j.auto.parked == "открыт PR")
    }

    @Test func approvedRemovalMerges() async throws {
        try put("")
        let q = try queue(), j = done(queued: touch)
        q.jobs = [j]
        #expect(await !q.mergeNow(j))
        q.approveTaskCheck(j, try #require(j.taskCheckRefusal))
        #expect(await q.mergeNow(j))
        #expect(!marked && has("a.txt"))
    }

    @Test func severalRepositoriesAreRefused() async throws {
        try put(touch)
        approve(touch)
        let q = try queue(), j = done(queued: touch)
        j.repos = ["api"]
        q.jobs = [j]
        #expect(await !q.mergeNow(j))
        #expect(!marked && j.worktreeNote.contains("repos"))
        let t = try #require(Codec.task(at: task))
        var p = Codec.project(at: main, category: "c")
        var withRepos = t
        withRepos.status = .todo
        withRepos.repos = ["api"]
        p.tasks = [withRepos]
        q.jobs = []
        guard case .failed(let why) = q.tryEnqueue([withRepos], project: p, ensureGit: { _ in nil }) else { Issue.record("поставлена"); return }
        #expect(why.contains("verify") && q.jobs.isEmpty)
    }

    // MARK: After the agent

    @Test func unapprovedDoesNotStopTheAgent() async throws {
        try put(touch)
        let q = try queue(), j = try await start(q, project: "test -f f.txt")
        #expect(j.taskVerify == touch && j.taskCheckRefusal?.ask == touch)
        agent.runs[0].finish()
        try await wait { !j.isActive }
        #expect(j.state == .done && j.verifyFailed && j.verifyAttempts == 0 && !marked)
        #expect(j.verifyNote.hasPrefix(JobQueue.taskCheckRefused) && j.verifyNote.contains("test -f f.txt"))
        for x in q.jobs where x !== j { q.cancel(x) }
        try await wait { !q.hasActiveChild(j) }
        // The main folder: both run after the approval, without the agent.
        let runs = agent.runs.count
        q.approveTaskCheck(j, try #require(j.taskCheckRefusal))
        try await wait("\(j.verifyNote)") { !j.verifyFailed }
        #expect(marked && j.verifyNote.contains("Проверка прошла") && agent.runs.count == runs)
    }

    @Test func redTaskCheckGoesToTheSameSession() async throws {
        let cmd = "test -f \(mark.path)"
        try put(cmd)
        approve(cmd)
        // No project check at all.
        let q = try queue(), j = try await start(q)
        agent.runs[0].finish()
        try await wait { agent.runs.count == 2 && agent.runs[1].request != nil }
        #expect(agent.runs[1].request?.resume == "s1" && agent.runs[1].request?.prompt.contains("Проверка задачи `\(cmd)`") == true)
        try Data().write(to: mark)
        agent.runs[1].finish()
        try await wait { !j.isActive }
        #expect(j.state == .done && !j.verifyFailed && j.verifyAttempts == 1 && j.verifyNote.contains(cmd))
    }

    /// The agent rewrote or erased the line while it worked.
    @Test(arguments: ["true", ""]) func agentCantReplaceTheCommand(_ new: String) async throws {
        try put("false")
        approve("false")
        let q = try queue(), j = try await start(q)
        try put(new)
        agent.runs[0].finish()
        try await wait { !j.isActive }
        #expect(j.verifyFailed && j.verifyAttempts == 0 && j.taskCheckRefusal?.ask == new && j.taskCheckRefusal?.approved == "false")
    }

    @Test func secondIsNotRunWhenTheFirstIsRed() throws {
        try put(touch)
        approve(touch)
        let g = TaskVerifyGate(project: main, task: task, queued: nil, severalRepos: false, folder: main, store: store)
        let p = Verify.pair("false", g, in: main)
        #expect(!p.ok && !p.isTask && p.command == "false" && !marked)
        let both = Verify.pair("true # комментарий", g, in: main)
        #expect(both.ok && both.passed.count == 2 && marked)
    }

    @Test func snapshotIsCarriedOver() throws {
        try put(touch)
        let q = try queue()
        q.paused = true
        let j = done(queued: "старое")
        j.state = .failed
        q.jobs = [j]
        let fix = Job(kind: .fix, title: "f", projectID: nil, projectName: "p", cwd: main, prompt: "x", systemPrompt: "", taskPath: task.path)
        fix.parentID = j.id
        q.add(fix)
        #expect(fix.taskVerify == "старое")
        q.cancel(fix)
        q.retry(j)
        #expect(q.jobs.last?.taskVerify == "старое")
    }
}
