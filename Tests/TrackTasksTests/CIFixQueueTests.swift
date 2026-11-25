import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// «Исправить CI» through the real queue and git with a real remote; the agent and GitHub are fake.
@MainActor @Suite(.serialized) struct CIFixQueueTests {
    final class Box { var mode = DangerMode(); var on = false }
    let dir: URL, main: URL, wt: URL, bare: URL, task: URL
    let box = Box()
    let a = FakeAgent("fake", [.resume, .permissions, .bypass])
    let url = "https://github.com/o/r/pull/7"

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-cifix-\(UUID().uuidString)")
        main = dir.appendingPathComponent("main")
        wt = dir.appendingPathComponent("wt")
        bare = dir.appendingPathComponent("remote.git")
        task = main.appendingPathComponent("tasks/20261124-000000-x.md")
        try FileManager.default.createDirectory(at: task.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\ntitle: \"x\"\nstatus: done\n---\n\nтекст\n".utf8).write(to: task)
        try Data("old\n".utf8).write(to: main.appendingPathComponent("a.txt"))
        for a in [["init", "-q", "-b", "main"], ["config", "user.name", "t"], ["config", "user.email", "t@t"],
                  ["config", "commit.gpgsign", "false"], ["add", "-A"], ["commit", "-q", "-m", "base"],
                  ["init", "-q", "--bare", bare.path], ["remote", "add", "origin", bare.path],
                  ["worktree", "add", "-q", "-b", "tracktasks/x", wt.path]] { git(a) }
        try commit("new\n")
        push()
    }

    @discardableResult private func git(_ args: [String], _ d: URL? = nil) -> String {
        let r = Worktrees.git(args, in: d ?? main)
        #expect(r.ok, "\(args): \(r.err)")
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func commit(_ text: String) throws {
        try Data(text.utf8).write(to: wt.appendingPathComponent("a.txt"))
        git(["commit", "-q", "-am", "job"], wt)
    }
    /// The person's own push.
    private func push() { git(["push", "-q", "origin", "tracktasks/x"]) }
    private var tip: String { git(["rev-parse", "refs/heads/tracktasks/x"]) }
    private var remote: [String] {
        [git(["for-each-ref"], bare), git(["rev-parse", "refs/remotes/origin/tracktasks/x"])]
    }
    private func queue() -> JobQueue {
        let box = box, a = a
        let q = JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([a]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "F", agent: a.id, model: "m")], defaultID: "fake") },
                         dangerMode: { box.mode }, recordSpend: { _, _, _, _ in })
        q.paused = false
        q.ciAutoFix = { _ in box.on }
        q.ciLog = { _, _, _ in .success("boom\n##[error]exit 1\n") }
        return q
    }
    private func red(_ j: Job, head: String? = nil, pending: Bool = false) {
        var l = PullRequestLink(pr: PullRequest(number: 7, url: url, headOid: tip), remote: "origin", pushedOid: tip)
        var checks = [PullRequestCheck(name: "CI / test", state: .fail, link: "https://github.com/o/r/actions/runs/1/job/2"),
                      PullRequestCheck(name: "circle", state: .fail, link: "https://circleci.com/1")]
        if pending { checks.append(PullRequestCheck(name: "slow", state: .pending)) }
        l.status = PullRequestStatus(checks: checks, review: nil, conflict: false, headOid: head ?? tip, updated: Date(), deployments: nil)
        j.pullRequest = l
    }
    private func job(_ q: JobQueue) -> Job {
        let j = Job(kind: .runTask, title: "x", projectID: nil, projectName: "p", cwd: main, prompt: "x", systemPrompt: "", taskPath: task.path)
        j.agent = a.id
        j.state = .done
        j.committed = true
        j.sessionID = "s1"
        j.worktree = .init(path: wt, main: main, branch: "tracktasks/x")
        j.baseCommit = git(["rev-parse", "main"])
        j.verifyCommand = "true"
        red(j)
        q.jobs.append(j)
        return j
    }
    private func wait(_ what: String = "", _ done: () -> Bool) async throws {
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(done(), "\(what)")
    }
    /// Ends the reply and whatever review it caused.
    private func settle(_ q: JobQueue, _ n: Int) async throws {
        try await wait("запуск") { a.runs.count >= n && a.runs.last?.request != nil }
        a.runs.last?.finish()
        try await wait("ответ") { q.jobs.filter { $0.kind == .reply }.allSatisfy { !$0.isActive } }
        for r in q.jobs where r.kind == .review { q.cancel(r) }
        try await wait("ревью") { !q.jobs.contains(where: \.isActive) }
    }
    private func cleanUp(_ qs: JobQueue...) {
        for q in qs {
            q.paused = true
            for j in q.jobs where j.isActive { q.cancel(j) }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func goesToTheSameSessionWithVerifyAndReviewWithoutPush() async throws {
        let q = queue(), j = job(q), before = remote, pushed = tip
        defer { cleanUp(q) }
        let ok = box.mode.enable(main.path, name: "p", typed: "p", .hour, autopilot: true, verify: "true", now: Date().addingTimeInterval(-1))
        #expect(ok && q.allows(.fullAccess, j) && q.onAutopilot(j))
        let d = try await q.prepareCIFix(j).get()
        #expect(a.runs.isEmpty && d.items.map { $0.log != nil } == [true, false] && d.items[1].problem == CIFix.external)
        #expect(await q.sendCIFix(j, d, chosen: [0, 1]) == nil)
        try await wait { a.runs.first?.request != nil }
        let r = try #require(a.runs.first?.request)
        #expect(r.resume == "s1" && !r.bypassPermissions && r.prompt.contains(q.ciFixText(j, d, chosen: [0, 1])))
        // A second one meanwhile doesn't go.
        #expect(await q.sendCIFix(j, d, chosen: [0]) != nil)
        let reply = try #require(q.jobs.first { $0.kind == .reply })
        #expect(reply.verifyCommand == "true" && reply.foreignLog && j.ciFixTries.count(url) == 0)
        #expect(!q.allows(.fullAccess, j) && !q.allows(.answerRequest, reply) && !q.onAutopilot(j))
        try Data("fixed\n".utf8).write(to: wt.appendingPathComponent("a.txt"))
        j.verdict = .ok
        a.runs[0].finish()
        try await wait { !reply.isActive }
        // Checked; the old verdict is about other code.
        #expect(reply.state == .done && !reply.verifyNote.isEmpty && j.verdict != .ok)
        #expect(!JobQueue.autoReview || q.jobs.contains { $0.kind == .review && $0.parentID == j.id })
        // Committed to the branch, pushed nowhere.
        #expect(tip != pushed && remote == before && j.pullRequest?.pushedOid == pushed)
        for c in q.jobs where c.kind == .review { q.cancel(c) }
        try await wait { !q.hasActiveChild(j) }
        // The fix isn't in the pull request: the old red is not sent again.
        box.on = true
        await q.autoCIFix(j)?.value
        #expect(q.jobs.filter { $0.kind == .reply }.count == 1)
        guard case .failure(let e) = await q.prepareCIFix(j) else { Issue.record("собрано по старому коммиту"); return }
        #expect(e.text.contains("Обновить PR"))
        // The limits are kept over a restart.
        #expect(Job(j.record).foreignLog && remote == before)
    }

    @Test func anotherCommitIsNotSent() async throws {
        let q = queue(), j = job(q)
        defer { cleanUp(q) }
        box.on = true
        red(j, head: "0000")
        if case .success = await q.prepareCIFix(j) { Issue.record("собрано по чужому коммиту") }
        #expect(q.autoCIFix(j) == nil)
        red(j)
        let d = try await q.prepareCIFix(j).get()
        // Pushed after the logs were collected.
        try commit("more\n")
        red(j)
        #expect(await q.sendCIFix(j, d, chosen: [0]) != nil)
        // A log GitHub gives for another commit.
        q.ciLog = { _, _, _ in .failure(.init(text: "лог относится к другому коммиту")) }
        await q.autoCIFix(j)?.value
        #expect(a.runs.isEmpty && q.jobs.count == 1 && !j.foreignLog && j.ciFixTries.count(url) == 0)
    }

    @Test func pushDuringCollecting() async throws {
        let q = queue(), j = job(q)
        defer { cleanUp(q) }
        box.on = true
        q.ciLog = { _, _, _ in Thread.sleep(forTimeInterval: 0.5); return .success("boom") }
        let t = q.autoCIFix(j)
        #expect(t != nil && q.autoCIFix(j) == nil)
        try await Task.sleep(for: .milliseconds(150))
        j.pullRequest?.pushedOid = "newer"
        await t?.value
        #expect(q.jobs.count == 1 && j.ciFixTries.count(url) == 0 && q.ciFixing.isEmpty)
    }

    @Test func atMostTwoAutomaticOverRestarts() async throws {
        var q = queue(), j = job(q)
        defer { cleanUp(q) }
        // Off by default.
        #expect(q.autoCIFix(j) == nil)
        box.on = true
        red(j, pending: true)
        #expect(q.autoCIFix(j) == nil)
        red(j)
        for n in 1...2 {
            let before = remote
            await q.autoCIFix(j)?.value
            #expect(j.ciFixTries.count(url) == n && q.jobs.contains { $0.kind == .reply && $0.isActive })
            // On disk before the agent is asked.
            #expect((try? String(contentsOf: dir.appendingPathComponent("queue.json"), encoding: .utf8))?.contains(tip) == true)
            try await settle(q, n)
            #expect(remote == before)
            // Once per commit.
            await q.autoCIFix(j)?.value
            #expect(j.ciFixTries.count(url) == n)
            // Restart, then the person pushes another commit (it makes a new link).
            q.saveNow()
            q.paused = true
            q = queue()
            j = try #require(q.jobs.first { $0.kind == .runTask })
            #expect(j.ciFixTries.count(url) == n && j.foreignLog)
            // It checks for interrupted merges first.
            try await wait("проверка слияний") { !j.worktreeBusy }
            try commit("try \(n)\n")
            push()
            red(j)
        }
        #expect(q.autoCIFix(j) == nil && a.runs.count == 2)
        // A retry of the job doesn't start counting anew.
        q.paused = true
        j.state = .failed
        q.retry(j)
        let k = try #require(q.jobs.last)
        #expect(k !== j && k.ciFixTries.count(url) == 2 && k.foreignLog)
    }

    @Test func automaticRefusals() async throws {
        let q = queue(), j = job(q)
        defer { cleanUp(q) }
        box.on = true
        q.paused = true
        #expect(q.autoCIFix(j) == nil)
        q.paused = false
        j.foreignSource = true
        #expect(q.autoCIFix(j) == nil)
        j.foreignSource = false
        j.scheduled = true
        #expect(q.autoCIFix(j) == nil)
        j.scheduled = false
        j.rolledBack = "c"
        #expect(q.autoCIFix(j) == nil)
        j.rolledBack = ""
        // The queue can't be written: nothing is sent and nothing is counted.
        let store = dir.appendingPathComponent("queue.json")
        try await Task.sleep(for: .milliseconds(700))
        try? FileManager.default.removeItem(at: store)
        try FileManager.default.createDirectory(at: store.appendingPathComponent("x"), withIntermediateDirectories: true)
        await q.autoCIFix(j)?.value
        #expect(q.jobs.count == 1 && j.ciFixTries.count(url) == 0 && !j.foreignLog)
    }

    @Test func oldRecordsAreRead() throws {
        let q = queue(), j = job(q)
        defer { cleanUp(q) }
        let r = try JSONDecoder().decode(JobRecord.self, from: JSONEncoder().encode(j.record))
        #expect(r.foreignLog == nil && r.ciFixTries == nil && !Job(r).foreignLog && Job(r).ciFixTries == CIFix.Tries())
    }
}
