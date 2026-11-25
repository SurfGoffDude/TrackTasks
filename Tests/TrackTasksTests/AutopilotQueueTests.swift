import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// The real queue, git and worktrees; only the agent is fake.
@MainActor @Suite(.serialized) struct AutopilotQueueTests {
    let dir: URL
    let main: URL
    let wt: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-auto-\(UUID().uuidString)")
        main = dir.appendingPathComponent("main")
        wt = dir.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: main.appendingPathComponent("tasks"), withIntermediateDirectories: true)
    }

    func git(_ args: [String], _ d: URL) -> Bool {
        Worktrees.git(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args, in: d).ok
    }

    /// A reviewed task with a commit in its branch.
    func setUp(verify: String, autopilot: Bool = true) throws -> (JobQueue, Job) {
        try Data("---\nverify: \(verify)\n---\n".utf8).write(to: main.appendingPathComponent("about.md"))
        try Data("old\n".utf8).write(to: main.appendingPathComponent("a.txt"))
        let task = main.appendingPathComponent("tasks/20261124-000000-x.md")
        try Data("---\ntitle: \"x\"\nstatus: done\n---\n".utf8).write(to: task)
        #expect(git(["init", "-q", "-b", "main"], main))
        #expect(git(["config", "user.name", "t"], main) && git(["config", "user.email", "t@t"], main) && git(["config", "commit.gpgsign", "false"], main))
        #expect(git(["add", "-A"], main) && git(["commit", "-q", "-m", "base"], main))
        #expect(git(["worktree", "add", "-q", "-b", "tracktasks/x", wt.path], main))
        try Data("new\n".utf8).write(to: wt.appendingPathComponent("a.txt"))
        #expect(git(["commit", "-q", "-am", "job"], wt))
        var mode = DangerMode()
        let on = mode.enable(main.path, name: "p", typed: "p", .hour, autopilot: autopilot, verify: verify, now: Date().addingTimeInterval(-1))
        #expect(on)
        let m = mode
        let q = JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([FakeAgent()]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "Fake", agent: AgentID(rawValue: "fake"), model: "m1")], defaultID: "fake") },
                         dangerMode: { m }, recordSpend: { _, _, _, _ in })
        let j = Job(kind: .runTask, title: "x", projectID: nil, projectName: "p", cwd: main, prompt: "x", systemPrompt: "", taskPath: task.path)
        j.agent = AgentID(rawValue: "fake")
        j.state = .done
        j.committed = true
        j.worktree = .init(path: wt, main: main, branch: "tracktasks/x")
        j.verdict = .ok
        j.review = "ВЕРДИКТ: ОК"
        q.jobs.append(j)
        return (q, j)
    }
    func text() -> String { (try? String(contentsOf: main.appendingPathComponent("a.txt"), encoding: .utf8)) ?? "" }
    func wait(_ done: () -> Bool) async throws {
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func mergesReviewedBranch() async throws {
        let (q, j) = try setUp(verify: "grep -q new a.txt")
        q.pump()
        try await wait { j.merged }
        #expect(j.merged && text() == "new\n")
    }

    @Test func withoutAutopilotNothingMerges() async throws {
        let (q, j) = try setUp(verify: "true", autopilot: false)
        q.pump()
        try await Task.sleep(for: .milliseconds(800))
        #expect(!j.merged && text() == "old\n")
    }

    @Test func scheduledWorkWaitsForThePerson() async throws {
        let (q, j) = try setUp(verify: "true")
        j.scheduled = true
        q.pump()
        try await Task.sleep(for: .milliseconds(800))
        #expect(!j.merged && text() == "old\n" && !q.onAutopilot(j))
        // Kept by a restart of the app, a retry and follow-ups.
        let data = try JSONEncoder().encode(j.record)
        let back = Job(try JSONDecoder().decode(JobRecord.self, from: data))
        #expect(back.scheduled && !q.onAutopilot(back))
        q.paused = true
        j.state = .failed
        q.retry(j)
        #expect(q.jobs.last?.scheduled == true)
        let fix = Job(kind: .fix, title: "f", projectID: nil, projectName: "p", cwd: main, prompt: "x", systemPrompt: "", taskPath: j.taskPath)
        q.add(fix)
        #expect(fix.scheduled)
    }

    @Test func scheduleFieldOfTheTaskForbidsMerge() async throws {
        let (q, j) = try setUp(verify: "true")
        let task = main.appendingPathComponent("tasks/20261124-000000-x.md")
        try Data("---\ntitle: \"x\"\nstatus: done\nautomation: a.md\n---\n".utf8).write(to: task)
        q.pump()
        try await Task.sleep(for: .milliseconds(800))
        #expect(!j.merged && text() == "old\n")
    }

    @Test func redCheckGoesToTheAgentAndMainIsUntouched() async throws {
        let (q, j) = try setUp(verify: "false")
        q.pump()
        try await wait { q.jobs.contains { $0.kind == .fix } }
        #expect(q.jobs.contains { $0.kind == .fix && $0.fixesMergeCheck && $0.parentID == j.id })
        #expect(!j.merged && text() == "old\n" && j.auto.repairs == 1)
    }

    @Test func uncommittedWorkInMainIsNotTouched() async throws {
        let (q, j) = try setUp(verify: "true")
        try Data("mine\n".utf8).write(to: main.appendingPathComponent("a.txt"))
        q.pump()
        try await wait { j.autoHold != nil }
        #expect(!j.merged && text() == "mine\n" && j.auto.parked == nil)
    }

    @Test func waitsForAnswersAndGoesOn() async throws {
        let (q, j) = try setUp(verify: "true")
        j.sessionID = "s1"
        j.auto.fixes = 1
        let path = try #require(j.taskPath), url = URL(fileURLWithPath: path)
        try Data("---\ntitle: \"x\"\nstatus: doing\n---\n\n## Вопросы\n1. A?\n".utf8).write(to: url)
        q.pump()
        try await wait { j.auto.parked != nil }
        #expect(j.auto.parked == "ждёт ответов" && !j.merged)
        #expect(await q.submitAnswers(j, [("A?", "да")]) == .continued)
        #expect(j.auto.parked == nil && j.worktreeNote.isEmpty && j.auto.fixes == 1)
        try await wait { (q.agents[.init(rawValue: "fake")] as? FakeAgent)?.runs.first?.request != nil }
        let run = try #require((q.agents[.init(rawValue: "fake")] as? FakeAgent)?.runs.first)
        #expect(run.request?.resume == "s1" && run.request?.prompt.contains("A? — да") == true)
        try Data(try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "status: doing", with: "status: done").utf8).write(to: url)
        run.finish()
        try await wait { j.merged }
        #expect(j.merged)
    }

    @Test func pausedQueueDoesNotMerge() async throws {
        let (q, j) = try setUp(verify: "true")
        q.paused = true
        q.pump()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!j.merged)
    }
}
