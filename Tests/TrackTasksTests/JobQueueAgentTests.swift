import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

@MainActor final class FakeRun: AgentRun {
    var onEvent: ((AgentEvent) -> Void)?
    var onExit: ((AgentRunResult) -> Void)?
    var onPermission: ((AgentPermission) -> Void)?
    var onTurnStarted: (() -> Void)?
    var request: AgentRequest?
    var answers: [String] = []
    var startError: Error?

    func start(_ request: AgentRequest) throws {
        if let startError { throw startError }
        self.request = request
    }
    func respond(_ p: AgentPermission, allow: Bool, always: Bool) { answers.append("\(p.id) \(allow) \(always)") }
    func stop() { finish { $0.stopped = true } }
    func killTree() {}

    func finish(session: String? = "s1", cost: Double? = 0.5, _ edit: (inout AgentRunResult) -> Void = { _ in }) {
        var r = AgentRunResult(sessionID: session, program: "fake")
        r.costUSD = cost
        r.turns = 1
        r.outputTokens = 10
        r.gotResult = true
        r.resultText = "готово"
        edit(&r)
        onExit?(r)
    }
}

@MainActor final class FakeAgent: Agent {
    let id: AgentID
    let title = "Fake"
    let capabilities: AgentCapabilities
    var runs: [FakeRun] = []
    var startError: Error?

    init(_ id: String = "fake", _ capabilities: AgentCapabilities = [.resume, .fork, .resumeAt, .permissions]) {
        self.id = AgentID(rawValue: id)
        self.capabilities = capabilities
    }
    func makeRun() -> any AgentRun {
        let r = FakeRun()
        r.startError = startError
        runs.append(r)
        return r
    }
}

/// The real queue with fake agents: no claude, no files of the user.
@MainActor @Suite(.serialized) struct JobQueueAgentTests {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func queue(_ agents: [any Agent], _ profiles: AgentProfiles? = nil) -> JobQueue {
        let p = profiles ?? AgentProfiles(custom: [AgentProfile(id: "fake", title: "Fake", agent: AgentID(rawValue: "fake"), model: "m1")],
                                          defaultID: "fake")
        return JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry(agents), profiles: { p },
                        dangerMode: { DangerMode() }, recordSpend: { _, _, _, _ in })
    }

    private func job(_ title: String = "Задача", profile: String = "") -> Job {
        let j = Job(kind: .runTask, title: title, projectID: nil, projectName: "p", cwd: dir, prompt: "сделай", systemPrompt: "sys")
        j.profile = profile
        return j
    }

    @Test func limitGuardHoldsUnknownAgents() {
        let claude = FakeAgent("claude", [.guardedLimit]), other = FakeAgent()
        let q = queue([claude, other])
        #expect(!q.spendsGuardedLimit(job()))
        #expect(q.spendsGuardedLimit(job(profile: "no-such-profile")))
        let j = job()
        j.agent = AgentID(rawValue: "no-such-agent")
        #expect(q.spendsGuardedLimit(j))
        j.agent = AgentID(rawValue: "claude")
        #expect(q.spendsGuardedLimit(j))
    }

    @Test func finishedInMainFollowsWorktree() {
        let j = job()
        #expect(!j.finishedInMain)
        j.state = .done
        #expect(j.finishedInMain)
        #expect(Job(j.record).finishedInMain)
        // The worktree is gone and no base commit is known: still not the main folder's work.
        j.worktree = Worktrees.Info(path: dir.appendingPathComponent("w"), main: dir, branch: "b")
        j.worktree = nil
        #expect(j.baseCommit.isEmpty && !j.finishedInMain)
        #expect(!Job(j.record).finishedInMain)
        // Saved before the flag existed.
        var r = job().record
        r.state = .done; r.hadWorktree = nil
        #expect(Job(r).finishedInMain)
        r.baseCommit = "abc"
        #expect(!Job(r).finishedInMain)
    }

    @Test func runsTaskToTheEnd() throws {
        let a = FakeAgent(), q = queue([a]), j = job()
        q.add(j)
        let run = try #require(a.runs.first)
        #expect(j.state == .running)
        #expect(run.request?.prompt == "сделай")
        #expect(run.request?.model == "m1")
        #expect(run.request?.bypassPermissions == false)
        run.onEvent?(.text("думаю"))
        run.onEvent?(.tool("Читает a"))
        run.finish()
        #expect(j.state == .done)
        #expect(j.sessionID == "s1")
        #expect(j.cost == AgentCost(usd: 0.5))
        #expect(j.log.contains("думаю") && j.log.contains("⚙︎ Читает a"))
    }

    @Test func unknownCostIsNotZero() {
        let a = FakeAgent(), q = queue([a]), j = job()
        q.add(j)
        a.runs[0].finish(cost: nil)
        #expect(j.cost.text() == "нет данных")
        #expect(j.summary.contains("нет данных"))
        #expect(Job(j.record).cost == j.cost)
    }

    @Test func failureCancelsDependents() {
        let a = FakeAgent(), q = queue([a]), j = job(), next = job("Вторая")
        next.dependsOn = [j.id]
        q.add(j)
        q.add(next)
        a.runs[0].finish { $0.isError = true; $0.resultText = "сломалось" }
        #expect(j.state == .failed)
        #expect(j.lastLine == "сломалось")
        #expect(next.state == .cancelled)
        #expect(a.runs.count == 1)
    }

    /// App restart in the middle: queue.json is read again and «↻» goes on in the same worktree.
    @Test(arguments: [nil, "s1"]) func restartedTaskStaysInItsWorktree(session: String?) async throws {
        let main = dir.appendingPathComponent("main"), wt = dir.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        for args in [["init", "-q"], ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "base"],
                     ["worktree", "add", "-q", "-b", "tracktasks/x", wt.path]] {
            #expect(Worktrees.git(args, in: main).ok)
        }
        let old = Job(kind: .runTask, title: "Задача", projectID: nil, projectName: "p", cwd: main, prompt: "x", systemPrompt: "")
        old.state = .running
        old.alwaysWorktree = true
        old.sessionID = session
        old.agent = AgentID(rawValue: "fake")
        old.worktree = .init(path: wt, main: main, branch: "tracktasks/x")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode([old.record]).write(to: dir.appendingPathComponent("queue.json"))

        let a = FakeAgent(), q = queue([a])
        let restored = try #require(q.jobs.first)
        #expect(restored.alwaysWorktree && restored.interrupted)
        // An interrupted merge is looked for first.
        for _ in 0..<500 where restored.worktreeBusy { try await Task.sleep(for: .milliseconds(20)) }
        q.retry(restored)
        for _ in 0..<500 where a.runs.first?.request == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(a.runs.first?.request?.cwd == wt)
        #expect(a.runs.first?.request?.resume == session)
        a.runs.first?.finish { $0.stopped = true }
    }

    @Test func startErrorFailsTheJob() {
        let a = FakeAgent(), q = queue([a]), j = job()
        a.startError = ClaudeError.notFound
        q.add(j)
        #expect(j.state == .failed)
        #expect(j.lastLine == ClaudeError.notFound.localizedDescription)
    }

    @Test func cancelStopsTheRun() {
        let a = FakeAgent(), q = queue([a]), j = job()
        q.add(j)
        q.cancel(j)
        #expect(j.state == .cancelled)
    }

    @Test func permissionAnswersReachTheAgent() {
        let a = FakeAgent(), q = queue([a]), j = job()
        q.add(j)
        let run = a.runs[0]
        run.onPermission?(AgentPermission(id: "1", tool: "Bash", title: "ls"))
        run.onPermission?(AgentPermission(id: "2", tool: "Bash", title: "rm"))
        #expect(j.permissions.map(\.id) == ["1", "2"])
        q.answer(j, j.permissions[0], allow: true, always: true)
        q.answer(requestID: "2", allow: false)
        #expect(run.answers == ["1 true true", "2 false false"])
        #expect(j.permissions.isEmpty)
        run.finish()
    }

    @Test func replyResumesTheSessionOfTheSameAgent() {
        let a = FakeAgent(), q = queue([a]), j = job()
        q.add(j)
        a.runs[0].finish()
        #expect(q.sendReply(j, text: "ещё"))
        #expect(a.runs[1].request?.resume == "s1")
        #expect(a.runs[1].request?.prompt == "ещё")
        a.runs[1].finish()
        #expect(j.replies.first?.answer == "готово")
    }

    @Test func fixFallsBackToNewSession() {
        let a = FakeAgent(), q = queue([a]), j = job()
        q.add(j)
        a.runs[0].finish()
        j.review = "замечание"
        q.requestFix(j)
        #expect(a.runs[1].request?.resume == "s1")
        a.runs[1].finish { $0.isError = true; $0.turns = 0; $0.resultText = "no conversation" }
        #expect(a.runs.count == 3)
        #expect(a.runs[2].request?.resume == nil)
        a.runs[2].finish(session: "s2")
        #expect(j.reviewFixed)
    }

    @Test func agentWithoutResume() {
        let a = FakeAgent("fake", []), q = queue([a]), j = job()
        q.add(j)
        a.runs[0].finish()
        #expect(q.replyBlocked(j) != nil)
        #expect(!q.sendReply(j, text: "ещё"))
        #expect(q.forkBlocked(j) != nil)
        j.review = "замечание"
        q.requestFix(j)
        #expect(a.runs[1].request?.resume == nil)
        a.runs[1].finish()
        // A cancelled run starts over, its session is never passed.
        let c = job("Отмена")
        q.add(c)
        q.cancel(c)
        q.retry(c)
        #expect(a.runs.count == 4)
        #expect(a.runs[3].request?.resume == nil)
    }

    @Test func unknownProfileFailsWithoutFallback() {
        let claude = FakeAgent("claude"), q = queue([claude], AgentProfiles()), j = job(profile: "нет")
        q.add(j)
        #expect(j.state == .failed)
        #expect(j.lastLine.contains("нет"))
        #expect(claude.runs.isEmpty)
    }

    /// Asked for isolation: never runs on the host instead.
    @Test(arguments: ["docker", "doker"]) func executorNeverFallsBackToHost(value: String) throws {
        try "---\nname: P\nexecutor: \(value)\n---\n".write(to: dir.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
        let a = FakeAgent(), q = queue([a]), j = job()
        q.add(j)
        #expect(j.state == .failed)
        #expect(j.lastLine.contains("executor: \(value)"))
        #expect(a.runs.isEmpty)
    }

    /// The agent can edit the worktree's copy of about.md: only the project's own one counts.
    @Test func executorIsReadFromTheMainFolder() throws {
        let wt = dir.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        for (d, v) in [(dir, "docker"), (wt, "local")] {
            try "---\nname: P\nexecutor: \(v)\n---\n".write(to: d.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
        }
        let j = job()
        j.worktree = Worktrees.Info(path: wt, main: dir, branch: "b")
        #expect(JobQueue.executorRefusal(j) != nil)
        let follow = Job(kind: .fix, title: "t", projectID: nil, projectName: "p", cwd: j.cwd, prompt: "", systemPrompt: "")
        follow.worktree = j.worktree
        #expect(JobQueue.executorRefusal(follow) != nil)
    }

    @Test func unsupportedAgentFails() {
        let claude = FakeAgent("claude"), q = queue([claude]), j = job()
        q.add(j)
        #expect(j.state == .failed)
        #expect(claude.runs.isEmpty)
    }

    @Test func cheapModelPicksTheModel() {
        let a = FakeAgent("claude", [.autoModel, .resume]), q = queue([a], AgentProfiles()), j = job()
        q.add(j)
        // A short task is decided without asking; make sure the model reached the agent either way.
        if a.runs[0].request?.access == .answer { a.runs[0].finish(session: nil) { $0.resultText = "opus: сложно" } }
        let code = a.runs.last?.request
        #expect(code?.access == .coding)
        #expect(code?.model == j.model?.alias)
        a.runs.last?.finish()
    }
}

@MainActor @Suite struct OldQueueTests {
    /// Required fields of a queue.json written before agents.
    private func old(_ extra: String = "") -> Data {
        Data("""
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"runTask","title":"Старая","projectName":"p","cwd":"file:///tmp/p/",
        "prompt":"a","systemPrompt":"b","created":"2026-11-01T10:00:00Z","state":"done","lastLine":"","log":[],"diffStat":"",
        "summary":"","cost":0.25,"interrupted":false,"baseCommit":"","worktreeNote":"","merged":false,"committed":false,
        "mustUseMain":false,"modelReason":"","verifyAttempts":0,"verifyNote":"","verifyFailed":false,"review":"",
        "reviewFixed":false\(extra)}]
        """.utf8)
    }

    private func load(_ d: Data) throws -> Job {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return Job(try #require(try dec.decode([JobRecord].self, from: d).first))
    }

    @Test func readsOldRecord() throws {
        let j = try load(old(#","model":"opus","sessionID":"s","dependsOn":"00000000-0000-0000-0000-000000000001""#))
        #expect(j.agentID == .claude)
        #expect(j.agent == .claude)
        #expect(j.model == .opus)
        #expect(j.cost == AgentCost(usd: 0.25))
        #expect(j.dependsOn.count == 1)
        #expect(j.profile.isEmpty)
    }

    @Test func pendingOldRecordTakesDefaultProfile() throws {
        #expect(try load(old()).agent == nil)
    }

    @Test func unknownModelSurvives() throws {
        let j = try load(old(#","model":"future""#))
        #expect(j.model == nil)
        #expect(j.record.model == "future")
    }

    @Test func newFieldsRoundTripAndCostStaysNumber() throws {
        let j = try load(old())
        j.useAgent(of: { let t = Job(kind: .runTask, title: "", projectID: nil, projectName: "", cwd: URL(fileURLWithPath: "/"), prompt: "", systemPrompt: "")
            t.agent = AgentID(rawValue: "codex"); t.profile = "x"; t.profileModel = "m"; return t }())
        j.cost.add(nil)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode([j.record])
        let raw = try #require((JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
        #expect(raw["cost"] as? Double == 0.25)
        #expect(raw["agent"] as? String == "codex")
        let back = try load(data)
        #expect(back.agentID.rawValue == "codex")
        #expect(back.profile == "x" && back.profileModel == "m")
        #expect(back.cost == AgentCost(usd: 0.25, unknown: true))
    }
}

@MainActor @Suite struct ClaudeAdapterTests {
    @Test func codingRequest() {
        let o = ClaudeOptions(AgentRequest(cwd: URL(fileURLWithPath: "/p"), prompt: "x", model: "opus", access: .coding, isolated: true))
        #expect(o.allowedTools == ClaudeTools.coding)
        #expect(o.tools == nil)
        #expect(o.isolated)
    }

    @Test func answerRequestEqualsOneShot() {
        let cwd = URL(fileURLWithPath: "/p")
        let a = ClaudeOptions(AgentRequest(cwd: cwd, prompt: "x", model: "haiku", access: .answer, isolated: ClaudeOptions.isolateBackground))
        let b = ClaudeOptions.oneShot(cwd: cwd, prompt: "x", model: .haiku)
        #expect(a.tools == b.tools && a.allowedTools == b.allowedTools && a.model == b.model && a.isolated == b.isolated)
    }
}
