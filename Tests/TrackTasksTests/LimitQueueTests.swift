import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// Events made from the schema of the CLI (2.1): no live refusal of the five-hour window was recorded.
@MainActor @Suite struct ClaudeLimitStreamTests {
    private func run(_ lines: String...) -> AgentRunResult {
        let s = ClaudeStream(resume: "s1")
        for l in lines { s.consume(Data((l + "\n").utf8)) }
        return s.stats
    }
    private let rejected = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":1800000000},"session_id":"s1"}"#
    private func result(_ status: String = #","api_error_status":429"#, error: Bool = true, text: String = "x") -> String {
        #"{"type":"result","subtype":"success","is_error":\#(error),"num_turns":0,"result":"\#(text)","session_id":"s1"\#(status)}"#
    }

    @Test func refusalWith429IsALimit() {
        #expect(run(rejected, result()).limit == RunLimit(window: "five_hour", resetsAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let unknown = rejected.replacingOccurrences(of: #","resetsAt":1800000000"#, with: "")
        #expect(run(unknown, result()).limit == RunLimit(window: "five_hour"))
    }

    @Test func otherErrorsAreNot() {
        let allowed = rejected.replacingOccurrences(of: "rejected", with: "allowed")
        // The agent's text is never looked at.
        #expect(run(result("", text: "Claude usage limit reached, resets 3pm")).limit == nil)
        #expect(run(result()).limit == nil)
        #expect(run(allowed, result()).limit == nil)
        #expect(run(rejected, allowed, result()).limit == nil)
        #expect(run(rejected, result(#","api_error_status":500"#)).limit == nil)
        #expect(run(rejected, result("")).limit == nil)
        #expect(run(rejected, result(error: false)).limit == nil)
        #expect(run(rejected.replacingOccurrences(of: #""session_id""#, with: #""parent_tool_use_id":"t1","session_id""#), result()).limit == nil)
    }
}

/// The real queue with a fake agent, its own store, clock and limits.
@MainActor @Suite(.serialized) struct LimitQueueTests {
    final class Box {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var limits = Limits.Snapshot()
    }
    let dir: URL
    let box = Box()
    let a = FakeAgent("claude", [.resume, .guardedLimit, .permissions])
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private var store: URL { dir.appendingPathComponent("queue.json") }
    private var reset: Date { Date(timeIntervalSince1970: 1_800_003_600) }
    private func queue() -> JobQueue {
        let box = box
        return JobQueue(storeURL: store, agents: AgentRegistry([a]),
                        profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "Fake", agent: .claude, model: "m1")], defaultID: "fake") },
                        dangerMode: { DangerMode() }, limits: { box.limits }, now: { box.now }, recordSpend: { _, _, _, _ in })
    }
    private func job(_ title: String = "Задача", kind: Job.Kind = .runTask) -> Job {
        Job(kind: kind, title: title, projectID: nil, projectName: "p", cwd: dir, prompt: "сделай", systemPrompt: "sys")
    }
    private func refuse(_ n: Int, reset: Date?, session: String? = "s1", window: String = "five_hour", turns: Int = 1) {
        a.runs[n].finish(session: session) { $0.isError = true; $0.resultText = "лимит"; $0.turns = turns; $0.limit = RunLimit(window: window, resetsAt: reset) }
    }
    private func pass(_ q: JobQueue, to d: Date? = nil) {
        box.now = (d ?? reset).addingTimeInterval(LimitWait.grace)
        q.holdTick()
    }
    /// A queue whose first job waits for the limit.
    private func waiting() -> (JobQueue, Job) {
        let q = queue(), j = job()
        q.add(j)
        refuse(0, reset: reset)
        return (q, j)
    }

    @Test func continuesTheSameSessionOnce() {
        let (q, j) = waiting()
        let next = job("Вторая")
        next.dependsOn = [j.id]
        q.add(next)
        #expect(j.state == .pending && j.limitWait?.session == "s1" && j.finishedAt == nil)
        #expect(next.state == .pending)
        #expect(q.waitReason(j).contains("после сброса"))
        #expect(q.holdTimer != nil)
        box.now = reset.addingTimeInterval(-1)
        q.holdTick()
        q.pump()
        #expect(a.runs.count == 1)
        pass(q)
        #expect(a.runs.count == 2 && j.state == .running && j.limitWait == nil)
        let r = a.runs[1].request
        #expect(r?.resume == "s1" && r?.fork == false && r?.model == "m1")
        #expect(r?.prompt.contains("сделай") == true)
        #expect(q.holdTimer == nil)
        q.holdTick()
        q.pump()
        #expect(a.runs.count == 2)
        a.runs[1].finish()
        #expect(j.state == .done)
        // The dependent one starts only now.
        #expect(a.runs.count == 3 && next.state == .running)
        #expect(a.runs[2].request?.resume == nil)
    }

    @Test func secondRefusalOfTheSameWindowFails() {
        let (q, j) = waiting()
        pass(q)
        refuse(1, reset: box.now.addingTimeInterval(120))
        #expect(j.state == .failed && j.interrupted && j.lastLine.contains("уже был"))
        pass(q, to: box.now.addingTimeInterval(600))
        #expect(a.runs.count == 2)
        // ↻ by hand continues the session; the window's retry stays used.
        q.retry(j)
        #expect(a.runs.count == 3 && a.runs[2].request?.resume == "s1")
        #expect(q.jobs.last?.limitRetried == reset)
        a.runs[2].finish()
    }

    @Test func nextWindowHasItsOwnRetry() {
        let (q, j) = waiting()
        pass(q)
        let second = reset.addingTimeInterval(5 * 3600)
        refuse(1, reset: second)
        #expect(j.state == .pending)
        pass(q, to: second)
        #expect(a.runs.count == 3 && a.runs[2].request?.resume == "s1")
        a.runs[2].finish()
    }

    @Test func unknownResetAndOtherWindowsAreNotRepeated() {
        for (d, w, text) in [(nil, "five_hour", "время сброса неизвестно"), (nil, "", "время сброса неизвестно"),
                             (reset, "seven_day", "Недельный лимит")] as [(Date?, String, String)] {
            let q = queue(), j = job()
            q.add(j)
            let n = a.runs.count - 1
            refuse(n, reset: d, window: w)
            #expect(j.state == .failed && j.interrupted && j.lastLine.contains(text))
            pass(q)
            #expect(a.runs.count == n + 1)
            #expect(q.holdTimer == nil)
            q.jobs = []
        }
    }

    @Test func ordinaryErrorIsNotALimit() {
        let q = queue(), j = job()
        q.add(j)
        a.runs[0].finish { $0.isError = true; $0.resultText = "Claude usage limit reached. 429 rate_limit" }
        #expect(j.state == .failed && j.limitWait == nil && !j.interrupted)
        #expect(q.holdTimer == nil)
    }

    @Test func restartKeepsTheWait() async throws {
        let (first, old) = waiting()
        let id = old.id
        first.paused = true
        let q = queue(), j = try #require(q.jobs.first)
        #expect(j.id == id && j.state == .pending && j.limitWait == old.limitWait)
        q.pump()
        #expect(a.runs.count == 1 && q.holdTimer != nil)
        pass(q)
        #expect(a.runs.count == 2 && a.runs[1].request?.resume == "s1")
        // The app is closed during the retry: no second one by itself.
        q.saveNow()
        let third = queue()
        third.pump()
        #expect(third.jobs.first?.state == .failed && third.jobs.first?.interrupted == true)
        box.now = box.now.addingTimeInterval(6 * 3600)
        third.holdTick()
        third.pump()
        #expect(a.runs.count == 2)
        a.runs[1].finish()
        q.paused = true
    }

    /// Closed between the mark and the process.
    @Test func restartAfterTheMarkDoesNotRunTwice() throws {
        let (_, j) = waiting()
        j.limitRetried = reset
        let back = Job(j.record)
        #expect(back.state == .failed && back.interrupted && back.limitWait == nil && back.sessionID == "s1")
    }

    @Test func pauseForbidsTheRetry() {
        let (q, j) = waiting()
        q.paused = true
        #expect(q.holdTimer == nil)
        pass(q)
        #expect(a.runs.count == 1 && j.state == .pending)
        q.paused = false
        #expect(a.runs.count == 2 && a.runs[1].request?.resume == "s1")
        a.runs[1].finish()
    }

    @Test func cancelForbidsTheRetry() {
        let (q, j) = waiting()
        q.cancel(j)
        #expect(j.state == .cancelled && j.limitWait == nil && q.holdTimer == nil)
        pass(q)
        q.pump()
        #expect(a.runs.count == 1)
        #expect(Job(j.record).state == .cancelled)
    }

    @Test func stopAskedBeatsTheRefusal() {
        let q = queue(), j = job()
        q.add(j)
        // SIGTERM caught by the CLI: the run ends by itself, not as `stopped`.
        j.stopAsked = true
        refuse(0, reset: reset)
        #expect(j.state == .cancelled && j.limitWait == nil)
    }

    @Test func stopAllCancelsTheWait() {
        let (q, j) = waiting()
        var mode = DangerMode()
        let now = Date()
        q.cancelLimitWaits(mode, now: now)
        #expect(j.state == .pending)
        let on = mode.enable(dir.path, name: "p", typed: "p", .hour, now: now)
        #expect(on)
        q.cancelLimitWaits(mode, now: now)
        #expect(j.state == .cancelled && j.limitWait == nil)
    }

    @Test func replyKeepsItsSessionAndWaits() {
        let q = queue(), j = job()
        q.add(j)
        a.runs[0].finish()
        #expect(q.sendReply(j, text: "ещё"))
        refuse(1, reset: reset, turns: 0)
        let reply = q.jobs.last
        #expect(reply?.state == .pending && j.sessionID == "s1" && j.replies.first?.state != .failed)
        #expect(!q.sendReply(j, text: "два"))
        pass(q)
        #expect(a.runs.count == 3 && a.runs[2].request?.resume == "s1")
        #expect(a.runs[2].request?.prompt.contains("ещё") == true)
        a.runs[2].finish()
        #expect(j.replies.first?.answer == "готово")
    }

    /// A refused resume of the task's session isn't a missing session: no new one is started.
    @Test func fixDoesNotStartANewSession() {
        let q = queue(), j = job()
        q.add(j)
        a.runs[0].finish()
        j.review = "замечание"
        q.requestFix(j)
        refuse(1, reset: reset, turns: 0)
        #expect(a.runs.count == 2)
        pass(q)
        #expect(a.runs.count == 3 && a.runs[2].request?.resume == "s1")
        // Not even after the retry couldn't resume.
        a.runs[2].finish { $0.isError = true; $0.turns = 0; $0.resultText = "no conversation" }
        #expect(a.runs.count == 3)
    }

    @Test func pipelineStepWaits() throws {
        let q = queue(), j = job()
        var w = Workflow.template
        w.steps = [Workflow.Step(title: "Код", type: .code)]
        // Like a task already at its code step, in its own folder.
        j.pipeline = PipelineState(name: "main", workflow: w, taskProfile: "")
        q.pipelineEvent(j, .begin)
        let wt = dir.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        j.worktree = .init(path: wt, main: dir, branch: "b")
        j.state = .running
        j.sessionID = "s1"
        j.agent = .claude
        let status = j.pipeline?.status
        q.jobs = [j]
        q.paused = true
        q.limitRefused(j, AgentRunResult(sessionID: "s1"), RunLimit(window: "five_hour", resetsAt: reset))
        #expect(j.state == .pending && j.limitWait != nil && j.pipeline?.status == status && j.worktree?.path == wt)
        let back = Job(j.record)
        #expect(back.state == .pending && back.pipeline?.status == status && back.worktree?.path == wt)
        q.cancel(j)
    }

    @Test func planBaselineSurvivesARestart() {
        let q = queue(), j = job()
        j.planPhase = .planning
        j.planBaseline = "base"
        j.sessionID = "s1"
        j.agent = .claude
        q.paused = true
        q.jobs = [j]
        q.limitRefused(j, AgentRunResult(sessionID: "s1"), RunLimit(window: "five_hour", resetsAt: reset))
        #expect(Job(j.record).planBaseline == "base")
        let code = job("Код")
        q.folderUsed(by: code)
        #expect(Job(j.record).planFolderShared)
    }

    private func window(_ used: Double, _ status: String = "allowed", reset: Date) -> Limits.Window {
        .init(utilization: used, resetsAt: reset, status: status)
    }

    @Test func rejectedWindowHoldsTheQueueUntilTheReset() {
        box.limits.fiveHour = window(1, "rejected", reset: reset)
        let q = queue(), j = job()
        q.add(j)
        #expect(a.runs.isEmpty && q.limitHold?.contains("5 часов") == true && q.waitReason(j) == q.limitHold)
        #expect(q.holdTimer != nil)
        // Past its reset the cached window is unknown.
        pass(q)
        #expect(a.runs.count == 1 && q.holdTimer == nil)
        a.runs[0].finish()
        // No reset time: nothing to wait for.
        box.limits.fiveHour = window(1, "rejected", reset: .distantFuture)
        #expect(q.limitHold == nil)
    }

    @Test func fiveHourGuardIsOffByDefault() {
        let key = JobQueue.fiveHourGuardKey, saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        box.limits.fiveHour = window(0.97, reset: reset)
        let q = queue()
        UserDefaults.standard.removeObject(forKey: key)
        #expect(q.limitHold == nil)
        UserDefaults.standard.set(5, forKey: key)
        #expect(q.limitHold?.contains("порог 5%") == true)
        box.limits.fiveHour = window(0.5, reset: reset)
        #expect(q.limitHold == nil)
    }

    @Test func noTimerWithoutALimit() {
        let q = queue(), j = job()
        q.add(j)
        #expect(q.holdTimer == nil)
        a.runs[0].finish()
        #expect(q.holdTimer == nil)
    }

    @Test func oldAndBrokenRecords() throws {
        let j = job(), enc = JSONEncoder(), dec = JSONDecoder()
        enc.dateEncodingStrategy = .iso8601
        dec.dateDecodingStrategy = .iso8601
        var raw = try #require(JSONSerialization.jsonObject(with: try enc.encode(j.record)) as? [String: Any])
        // Nothing is written for a job that doesn't wait.
        #expect(raw["limitWait"] == nil && raw["limitRetried"] == nil)
        #expect(Job(try dec.decode(JobRecord.self, from: JSONSerialization.data(withJSONObject: raw))).state == .pending)
        raw["limitWait"] = ["window": 5]
        let broken = Job(try dec.decode(JobRecord.self, from: JSONSerialization.data(withJSONObject: raw)))
        #expect(broken.state == .failed && broken.interrupted)
    }
}
