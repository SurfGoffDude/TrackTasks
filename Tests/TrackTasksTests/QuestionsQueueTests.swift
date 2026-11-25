import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// Questions of the agent through the real queue, files and git; only the agent is fake.
@MainActor @Suite(.serialized) struct QuestionsQueueTests {
    final class Box {
        var mode = DangerMode()
        var notices = 0
        /// What queue.json said when the person was told.
        var savedNotified: [String]?
    }
    let dir: URL, main: URL, task: URL
    let box = Box()
    let a = FakeAgent("claude", [.resume, .permissions, .bypass])

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-questions-\(UUID().uuidString)")
        main = dir.appendingPathComponent("main")
        task = main.appendingPathComponent("tasks/20261124-000000-x.md")
        try FileManager.default.createDirectory(at: task.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: main.appendingPathComponent("a.txt"))
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "t"], ["config", "user.email", "t@t"],
                     ["config", "commit.gpgsign", "false"], ["add", "-A"], ["commit", "-q", "-m", "base"]] {
            #expect(Worktrees.git(args, in: main).ok)
        }
        try write("")
    }

    private var store: URL { dir.appendingPathComponent("queue.json") }
    private func queue() -> JobQueue {
        let box = box, a = a, store = store
        let q = JobQueue(storeURL: store, agents: AgentRegistry([a]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "F", agent: .claude, model: "m")], defaultID: "fake") },
                         dangerMode: { box.mode }, questionNotice: { j in
                             box.notices += 1
                             let dec = JSONDecoder()
                             dec.dateDecodingStrategy = .iso8601
                             let recs = (try? Data(contentsOf: store)).flatMap { try? dec.decode([JobRecord].self, from: $0) }
                             box.savedNotified = recs?.first { $0.id == j.id }?.questions?.value.notified
                         }, recordSpend: { _, _, _, _ in })
        q.paused = false
        return q
    }
    private func danger() {
        let ok = box.mode.enable(main.path, name: "p", typed: "p", .hour, now: Date().addingTimeInterval(-1))
        #expect(ok)
    }
    private func write(_ body: String, status: String = "doing") throws {
        try Data("---\ntitle: \"x\"\nstatus: \(status)\n---\n\nтекст\n\(body)".utf8).write(to: task)
    }
    private var text: String { (try? String(contentsOf: task, encoding: .utf8)) ?? "" }
    private let plan = "\n## План\n1. шаг\n"
    private func asks(_ questions: String...) -> String { "\n## Вопросы\n" + questions.enumerated().map { "\($0 + 1). \($1)\n" }.joined() }
    private func job(_ phase: Job.PlanPhase? = nil) -> Job {
        let j = Job(kind: .runTask, title: "x", projectID: main.path, projectName: "p", cwd: main, prompt: "сделай", systemPrompt: "", taskPath: task.path)
        j.planPhase = phase
        return j
    }
    private func wait(_ what: String = "", _ done: () -> Bool) async throws {
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(done(), "\(what)")
    }
    private func run(_ n: Int) async throws -> FakeRun {
        try await wait("запуск \(n)") { a.runs.count > n && a.runs[n].request != nil }
        return a.runs[n]
    }
    /// Nothing starts by itself.
    private func quiet(_ n: Int) async throws {
        try await Task.sleep(for: .milliseconds(300))
        #expect(a.runs.count == n)
    }
    private func planned(_ q: JobQueue, _ body: String) async throws -> Job {
        let j = job(.planning)
        q.add(j)
        let r = try await run(0)
        try write(body)
        r.finish(session: "plan")
        try await wait("план") { j.awaitingPlan && j.state == .pending }
        return j
    }
    /// A finished job of the main folder.
    private func finished(_ q: JobQueue, _ body: String) throws -> Job {
        try write(body)
        let j = job()
        j.agent = .claude
        j.state = .done
        j.sessionID = "s1"
        q.jobs.append(j)
        q.refreshQuestions(j)
        return j
    }
    private func project() throws -> Project {
        Project(url: main, folderName: "main", category: "", displayName: "p", stack: [], status: .active, updated: "", summary: "",
                aboutBody: "", hasAbout: false, tasks: [try #require(Codec.task(at: task))])
    }
    private func stopAll(_ q: JobQueue) {
        q.paused = true
        for j in q.jobs where j.isActive { q.cancel(j) }
        let key = main.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "__")
        try? FileManager.default.removeItem(at: Worktrees.root.appendingPathComponent(key))
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Plan

    @Test func planWithQuestionsIsNotApproved() async throws {
        danger()
        let q = queue(), j = try await planned(q, plan + asks("A?"))
        defer { stopAll(q) }
        #expect(j.lastLine == "План ждёт ответов" && q.waitReason(j) == "ждёт ответов" && box.notices == 1)
        q.dangerChanged()
        try await quiet(1)
        #expect(j.awaitingPlan)
        // Another task goes on.
        let other = Job(kind: .runTask, title: "y", projectID: nil, projectName: "p", cwd: dir, prompt: "y", systemPrompt: "")
        q.add(other)
        _ = try await run(1)
    }

    @Test func turningTheModeOnOrRestartingDoesNotApprove() async throws {
        let q = queue(), j = try await planned(q, plan + asks("A?"))
        q.saveNow()
        danger()
        q.dangerChanged()
        #expect(j.awaitingPlan)
        // A restart, twice: neither approval nor another notification.
        for _ in 0..<2 {
            let q2 = queue()
            try await Task.sleep(for: .milliseconds(200))
            let k = try #require(q2.jobs.first)
            #expect(k.awaitingPlan && k.state == .pending && box.notices == 1 && k.questions?.open.map(\.text) == ["A?"])
            q2.saveNow()
            q2.paused = true
        }
        // The state is on disk before the notification.
        #expect(box.savedNotified == ["A?"])
        stopAll(q)
    }

    @Test func unreadableFileIsNotApproved() async throws {
        let q = queue(), j = try await planned(q, plan)
        defer { stopAll(q) }
        danger()
        try FileManager.default.removeItem(at: task)
        q.dangerChanged()
        #expect(j.awaitingPlan)
        try write(plan)
        q.dangerChanged()
        #expect(!j.awaitingPlan)
    }

    @Test func answersReworkThePlanThenItIsApproved() async throws {
        danger()
        let q = queue(), j = try await planned(q, plan + asks("A?", "B?"))
        defer { stopAll(q) }
        #expect(await q.submitAnswers(j, [("A?", "да")]) == .saved(left: 1))
        try await quiet(1)
        #expect(text.contains("Ответ: да"))
        async let first = q.submitAnswers(j, [("B?", "нет")])
        async let second = q.submitAnswers(j, [("B?", "другое")])
        let both = await [first, second]
        #expect(both.contains(.continued) && both.contains(.busy))
        let r = try await run(1)
        #expect(r.request?.access == .planning && r.request?.resume == "plan")
        #expect(r.request?.prompt.contains("A? — да") == true && r.request?.prompt.contains("B? — ") == true)
        #expect(await q.submitAnswers(j, [("B?", "ещё")]) == .busy)
        // New questions stop it again.
        try Data((text + "3. C?\n").utf8).write(to: task)
        r.finish(session: "plan")
        try await wait { j.awaitingPlan && j.state == .pending }
        try await quiet(2)
        #expect(box.notices == 2 && j.questions?.open.map(\.text) == ["C?"])
        #expect(await q.submitAnswers(j, [("C?", "три")]) == .continued)
        let r2 = try await run(2)
        #expect(r2.request?.prompt.contains("A? — да") == false)
        r2.finish(session: "plan")
        let code = try await run(3)
        #expect(code.request?.access == .coding && j.planPhase == .approved && j.questions == nil)
    }

    @Test func answersWrittenByHandDoNotApproveTheOldPlan() async throws {
        danger()
        let q = queue(), j = try await planned(q, plan + asks("A?"))
        defer { stopAll(q) }
        try write(plan + asks("A?") + "   Ответ: да\n")
        q.syncQuestions([try project()])
        q.dangerChanged()
        try await quiet(1)
        #expect(j.awaitingPlan && j.questions?.written == ["A?"])
        #expect(q.continueWithAnswers(j) == .continued)
        #expect(try await run(1).request?.prompt.contains("A? — да") == true)
    }

    @Test func onlyQuestionsAreNoFailure() async throws {
        let q = queue(), j = try await planned(q, asks("A?"))
        defer { stopAll(q) }
        #expect(j.awaitingPlan && j.state == .pending)
    }

    @Test func cancelledPlanIsPlannedAgainNotCoded() async throws {
        let q = queue(), j = try await planned(q, plan + asks("A?"))
        defer { stopAll(q) }
        q.cancel(j)
        #expect(await q.submitAnswers(j, [("A?", "да")]) == .continued)
        let r = try await run(1)
        #expect(r.request?.access == .planning && r.request?.resume == nil)
    }

    // MARK: Pipeline

    private func flow(stop: Workflow.Stop) -> Workflow {
        var w = Workflow.template
        w.steps[0].stop = stop
        #expect(w.lint().isEmpty)
        return w
    }
    private func pipeline(_ q: JobQueue) -> Job {
        let j = job()
        q.beginPipeline(j, name: "main", workflow: flow(stop: .none))
        q.add(j)
        return j
    }

    @Test func pipelineWithoutAStopWaitsAcrossARestart() async throws {
        let q0 = queue(), j0 = pipeline(q0)
        let r = try await run(0)
        try write(plan + asks("A?"))
        r.finish(session: "plan")
        try await wait { j0.awaitingPlan && j0.state == .pending }
        try await quiet(1)
        #expect(j0.pipeline?.status == .running && j0.pipeline?.current == 0)
        q0.saveNow()
        q0.paused = true
        let q = queue()
        defer { stopAll(q) }
        try await quiet(1)
        let j = try #require(q.jobs.first)
        #expect(j.awaitingPlan)
        #expect(await q.submitAnswers(j, [("A?", "да")]) == .continued)
        let again = try await run(1)
        #expect(again.request?.access == .planning)
        again.finish(session: "plan")
        let code = try await run(2)
        #expect(code.request?.access == .coding && j.pipeline?.current == 1)
        // The code step asks too: no review, the pipeline stops; an empty worktree is gone, so the step is repeated.
        try write(plan + asks("B?"))
        code.finish(session: "code")
        try await wait { j.pipeline?.gate != nil && !j.worktreeBusy }
        #expect(j.pipeline?.gate?.reason == "ждёт ответов" && !q.jobs.contains { $0.kind == .review })
        #expect(await q.submitAnswers(j, [("B?", "да")]) == .continued)
        let code2 = try await run(3)
        #expect(code2.request?.access == .coding && j.pipeline?.visits[1] == 2 && j.pipeline?.visits[0] == 1)
    }

    @Test func personMayApproveAPipelinePlanWithoutAnswers() async throws {
        let q = queue(), j = pipeline(q)
        defer { stopAll(q) }
        let r = try await run(0)
        try write(plan + asks("A?"))
        r.finish(session: "plan")
        try await wait { j.awaitingPlan && j.state == .pending }
        q.approvePlan(j)
        #expect(try await run(1).request?.access == .coding)
    }

    // MARK: Finished run

    @Test func sessionGoesOnAndDependentsWait() async throws {
        let q = queue(), j = try finished(q, asks("A?", "B?"))
        defer { stopAll(q) }
        #expect(q.blockingJob(forTask: task.path) === j)
        let dep = Job(kind: .runTask, title: "dep", projectID: nil, projectName: "p", cwd: dir, prompt: "dep", systemPrompt: "")
        dep.dependsOn = [j.id]
        q.add(dep)
        #expect(q.waitReason(dep).hasPrefix("ждёт ответов"))
        #expect(await q.submitAnswers(j, [("B?", "бэ")]) == .saved(left: 1))
        #expect(await q.submitAnswers(j, [("A?", "а")]) == .continued)
        let r = try await run(0)
        #expect(r.request?.resume == "s1" && r.request?.prompt.contains("A? — а") == true && r.request?.prompt.contains("B? — бэ") == true)
        // Nobody needs to be asked, but the agent hasn't finished with the answers.
        #expect(q.waitReason(dep).hasPrefix("ждёт ответов"))
        r.finish()
        try await wait { j.questions == nil }
        try await wait { a.runs.contains { $0.request?.prompt.contains("dep") == true } }
    }

    @Test func reviewWaitsForTheAnswers() async throws {
        let q = queue(), j = job()
        defer { stopAll(q) }
        j.alwaysWorktree = true
        q.add(j)
        let r = try await run(0)
        try Data("new\n".utf8).write(to: try #require(r.request).cwd.appendingPathComponent("a.txt"))
        try write(asks("A?"))
        r.finish()
        try await wait { j.state == .done }
        try await quiet(1)
        #expect(box.notices == 1 && j.committed)
        #expect(await q.submitAnswers(j, [("A?", "да")]) == .continued)
        try write(asks("A?") + "   Ответ: да\n", status: "done")
        try await run(1).finish()
        // The reply changed nothing, the code still has no verdict.
        try await wait { q.jobs.contains { $0.kind == .review } || !JobQueue.autoReview }
    }

    @Test func failedReplyKeepsTheAnswersToSend() async throws {
        let q = queue(), j = try finished(q, asks("A?"))
        defer { stopAll(q) }
        #expect(await q.submitAnswers(j, [("A?", "да")]) == .continued)
        try await run(0).finish { $0.isError = true }
        try await wait { j.replies.last?.state == .failed }
        #expect(j.questions?.written == ["A?"] && q.awaitsAnswers(j))
        #expect(q.continueWithAnswers(j) == .continued)
        try await run(1).finish()
        try await wait { j.questions == nil }
    }

    @Test func newRunWhenSessionAndWorktreeAreGone() async throws {
        let q = queue(), j = try finished(q, asks("A?"))
        defer { stopAll(q) }
        j.hadWorktree = true
        j.baseCommit = "abc"
        j.interrupted = true
        #expect(await q.submitAnswers(j, [("A?", "да")]) == .continued)
        let r = try await run(0)
        #expect(r.request?.resume == nil && r.request?.access == .coding && q.jobs.filter { $0.kind == .runTask }.count == 1)
        r.finish()
        let k = try #require(q.jobs.first { $0.kind == .runTask })
        try await wait { k.state == .done }
        #expect(k.questions == nil)
    }

    @Test func worktreeWithWorkIsNotLost() async throws {
        let q = queue(), j = try finished(q, asks("A?"))
        defer { stopAll(q) }
        let wt = dir.appendingPathComponent("wt")
        #expect(Worktrees.git(["worktree", "add", "-q", "-b", "tracktasks/x", wt.path], in: main).ok)
        j.worktree = .init(path: wt, main: main, branch: "tracktasks/x")
        j.committed = true
        j.sessionID = nil
        guard case .refused(let why) = await q.submitAnswers(j, [("A?", "да")]) else { Issue.record("не отказано"); return }
        #expect(why.contains("worktree") && text.contains("Ответ: да") && j.questions?.written == ["A?"])
        try await quiet(0)
        // What passes by itself is refused too; repeated later it goes on.
        j.sessionID = "s1"
        j.worktreeBusy = true
        guard case .refused = q.continueWithAnswers(j) else { Issue.record("не отказано"); return }
        j.worktreeBusy = false
        #expect(q.continueWithAnswers(j) == .continued)
        #expect(try await run(0).request?.cwd.path == wt.path)
    }

    @Test func failedWriteStartsNothing() async throws {
        let q = queue(), j = try finished(q, asks("A?"))
        defer { stopAll(q) }
        let before = text, tasks = task.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tasks)
        let out = await q.submitAnswers(j, [("A?", "да")])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tasks)
        guard case .writeFailed = out else { Issue.record("\(out)"); return }
        guard case .writeFailed = await q.submitAnswers(j, [("Нет такого?", "да")]) else { Issue.record("записано"); return }
        #expect(text == before && !j.answering)
        try await quiet(0)
    }

    @Test func withoutAJobOnlyTheFileIsWritten() async throws {
        let q = queue()
        defer { stopAll(q) }
        try write(asks("A?"))
        #expect(await q.submitAnswers(taskPath: task.path, [("A?", "да")]) == .saved(left: 0))
        #expect(text.contains("Ответ: да") && q.jobs.isEmpty)
    }

    // MARK: What the person sees

    @Test func statusAndCounter() async throws {
        let q = queue(), j = try finished(q, asks("A?", "B?"))
        defer { stopAll(q) }
        #expect(q.questionStatus(j) == .ask(2) && q.waitingAnswers == "Ждут ответа: 1")
        j.state = .failed
        #expect(q.questionStatus(j) == .ask(2))
        j.state = .cancelled
        #expect(q.questionStatus(j) == .none)
        j.state = .done
        j.merged = true
        #expect(q.questionStatus(j) == .none)
        j.merged = false
        j.worktreeBusy = true
        guard case .refused = await q.submitAnswers(taskPath: task.path, [("A?", "да"), ("B?", "нет")]) else { Issue.record("не отказано"); return }
        #expect(q.questionStatus(j) == .send && q.waitingAnswers != nil)
        j.worktreeBusy = false
        #expect(q.continueWithAnswers(j) == .continued)
        #expect(q.questionStatus(j) == .none && q.waitingAnswers == nil)
    }

    @Test func waitingPlanAsks() async throws {
        let q = queue(), j = try await planned(q, plan + asks("A?"))
        defer { stopAll(q) }
        #expect(q.questionStatus(j) == .ask(1))
    }

    @Test func draftIsKeptUntilWritten() {
        let d = QuestionDrafts()
        var typed = QuestionDraft()
        typed.type("A?", "мой ответ")
        func after(_ o: JobQueue.AnswerOutcome, submitted: Bool = true) -> QuestionDrafts.Entry {
            d["x"] = .init(draft: typed, sending: true)
            d.finish("x", o, submitted: submitted)
            return d["x"]
        }
        for o in [JobQueue.AnswerOutcome.writeFailed("нет места"), .busy] {
            let e = after(o)
            #expect(e.draft == typed && !e.note.isEmpty && !e.sending)
        }
        #expect(after(.writeFailed("нет места")).note.contains("нет места"))
        let refused = after(.refused("папка удалена"))
        #expect(refused.draft == QuestionDraft() && refused.note.contains("папка удалена"))
        #expect(after(.saved(left: 0)).note.isEmpty && after(.continued).draft == QuestionDraft())
        #expect(after(.refused("x"), submitted: false).draft == typed)
    }

    @Test func staleDraftsAreDropped() throws {
        let d = QuestionDrafts()
        var typed = QuestionDraft()
        typed.type("A?", "мой")
        try write(asks("A?"))
        d[task.path] = .init(draft: typed)
        d["/нет/такого.md"] = .init(draft: typed)
        #expect(d[task.path].draft == typed)
        d["/ещё.md"] = .init(closed: true)
        #expect(d.paths == [task.path, "/ещё.md"])
        d["/ещё.md"] = .init()
        #expect(d.paths == [task.path])
        try write(asks("A?"), status: "done")
        d["/новый.md"] = .init(draft: typed)
        #expect(d.paths == ["/новый.md"])
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Notifications and storage

    @Test func everyNewQuestionOnce() async throws {
        let q = queue(), j = try finished(q, "")
        defer { stopAll(q) }
        try write(asks("A?"))
        q.syncQuestions([try project()])
        q.syncQuestions([try project()])
        #expect(box.notices == 1)
        try write(asks("A?", "B?"))
        q.syncQuestions([try project()])
        #expect(box.notices == 2)
        #expect(await q.submitAnswers(j, [("A?", "да")]) == .saved(left: 1))
        q.syncQuestions([try project()])
        #expect(box.notices == 2)
        try write(asks("A?", "B?"), status: "done")
        q.syncQuestions([try project()])
        #expect(j.questions == nil && !q.awaitsAnswers(j))
        #expect(PushPolicy.message(.permission, detail: .brief, project: "p", task: "x") == PushMessage(title: "Агент ждёт ответа", body: "TrackTasks"))
    }

    @Test func damagedStateHoldsThePlan() throws {
        var r = job(.awaiting).record
        r.questions = .init(JobQuestions(open: [.init(text: "A?")]))
        var o = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        #expect(Job(try JSONDecoder().decode(JobRecord.self, from: JSONEncoder().encode(r))).questions?.open.first?.text == "A?")
        o["questions"] = ["open": 5]
        let back = try JSONDecoder().decode(JobRecord.self, from: JSONSerialization.data(withJSONObject: o))
        #expect(Job(back).questions?.waits == true)
        o["questions"] = nil
        #expect(Job(try JSONDecoder().decode(JobRecord.self, from: JSONSerialization.data(withJSONObject: o))).questions == nil)
    }
}
