import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// Comments to a diff stay drafts until the agent has them.
@MainActor @Suite(.serialized) struct DiffSendTests {
    let dir: URL, key = "/p\nmain..b", a = FakeAgent()
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A new one reads everything from disk, like after a restart.
    private func queue() -> JobQueue {
        let p = AgentProfiles(custom: [AgentProfile(id: "fake", title: "Fake", agent: AgentID(rawValue: "fake"), model: "m1")], defaultID: "fake")
        return JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([a]), profiles: { p },
                        dangerMode: { DangerMode() }, drafts: DiffDrafts(dir: dir.appendingPathComponent("drafts")),
                        recordSpend: { _, _, _, _ in })
    }

    private func comment(_ text: String) -> DiffComment {
        DiffComment(path: "a.swift", side: .new, start: 1, end: 2, snippet: ["x"], text: text)
    }

    /// A finished task with drafts of two comments.
    private func prepared() -> (JobQueue, Job) {
        let q = queue()
        let j = Job(kind: .runTask, title: "Задача", projectID: nil, projectName: "p", cwd: dir, prompt: "сделай", systemPrompt: "")
        q.add(j)
        a.runs[0].finish()
        q.openDrafts(key)
        q.drafts.change(key) { $0 = [comment("раз"), comment("два")] }
        return (q, j)
    }

    private func send(_ q: JobQueue, _ j: Job) -> Bool {
        let list = q.drafts.comments(key)
        return q.sendReply(j, text: DiffComments.format(list), comments: .init(key: key, list: list))
    }

    private func states(_ q: JobQueue) -> [DiffDelivery.State?] { q.drafts.comments(key).map { $0.delivery?.state } }

    private func edit(_ q: JobQueue, _ i: Int, _ text: String) {
        let old = q.drafts.comments(key)[i]
        var c = old
        c.text = text
        q.drafts.change(key) { DiffComments.upsert(c, original: old, in: &$0) }
    }

    @Test func removedOnlyWhenTheTurnStarts() {
        let (q, j) = prepared()
        #expect(send(q, j))
        // The process is up, the agent has said nothing.
        #expect(q.jobs.last?.state == .running && states(q) == [.sending, .sending])
        a.runs[1].onEvent?(.text("Контейнер готов"))
        #expect(states(q) == [.sending, .sending])
        a.runs[1].onTurnStarted?()
        #expect(states(q).isEmpty)
        a.runs[1].finish { $0.isError = true }
        #expect(states(q).isEmpty)
    }

    @Test func finishedTurnIsAccepted() {
        let (q, j) = prepared()
        #expect(send(q, j))
        a.runs[1].finish()
        #expect(states(q).isEmpty)
    }

    @Test func failedStartKeepsDrafts() {
        let (q, j) = prepared()
        a.startError = ClaudeError.notFound
        #expect(send(q, j))
        #expect(states(q) == [.failed, .failed] && j.replies.first?.state == .failed)
        // Repeated by hand from the card: the same drafts.
        a.startError = nil
        q.repeatReply(j, j.replies[0])
        #expect(states(q) == [.sending, .sending])
        a.runs.last?.onTurnStarted?()
        #expect(states(q).isEmpty)
        a.runs.last?.finish()
    }

    @Test(arguments: [true, false]) func diedBeforeTheTurnIsUnclear(stopped: Bool) {
        let (q, j) = prepared()
        #expect(send(q, j))
        a.runs[1].finish { $0.turns = 0; $0.gotResult = false; if stopped { $0.stopped = true } else { $0.isError = true } }
        #expect(states(q) == [.unclear, .unclear])
        // A later refusal to start doesn't make it certain.
        a.startError = ClaudeError.notFound
        #expect(send(q, j))
        #expect(states(q) == [.unclear, .unclear])
    }

    @Test func refusedMessageMarksNothing() {
        let (q, j) = prepared()
        #expect(send(q, j))
        q.drafts.change(key) { $0.append(comment("три")) }
        #expect(!send(q, j))
        #expect(states(q) == [.sending, .sending, nil])
        a.runs[1].finish()
    }

    @Test func editedAndNewStayDrafts() {
        let (q, j) = prepared()
        #expect(send(q, j))
        edit(q, 1, "два, иначе")
        q.drafts.change(key) { $0.append(comment("три")) }
        a.runs[1].onTurnStarted?()
        #expect(q.drafts.comments(key).map(\.text) == ["два, иначе", "три"])
        #expect(states(q) == [nil, nil])
        a.runs[1].finish()
        #expect(q.drafts.comments(key).count == 2)
    }

    /// Saved from an editor that was open while the draft was delivered.
    @Test func editorOutlivesItsDraft() {
        let (q, j) = prepared()
        #expect(send(q, j))
        let old = q.drafts.comments(key)[0]
        a.runs[1].onTurnStarted?()
        q.drafts.change(key) { DiffComments.upsert(old, original: old, in: &$0) }
        #expect(q.drafts.comments(key).isEmpty)
        var new = old
        new.text = "иначе"
        q.drafts.change(key) { DiffComments.upsert(new, original: old, in: &$0) }
        #expect(q.drafts.comments(key).map(\.text) == ["иначе"] && states(q) == [nil])
        a.runs[1].finish()
    }

    /// No window has the drafts: the queue alone removes them from the file.
    @Test func closedWindow() {
        let (q, j) = prepared()
        #expect(send(q, j))
        let file = dir.appendingPathComponent("drafts/" + DiffComments.fileName(forKey: key))
        #expect(FileManager.default.fileExists(atPath: file.path))
        a.runs[1].onTurnStarted?()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        a.runs[1].finish()
    }

    /// Nothing goes to the agent again by itself.
    @Test func restartBeforeTheTurnIsUnclear() async throws {
        let (q, j) = prepared()
        #expect(send(q, j))
        q.saveNow()
        let runs = a.runs.count
        let after = queue()
        after.openDrafts(key)
        #expect(states(after) == [.unclear, .unclear])
        try await Task.sleep(for: .milliseconds(300))
        after.pump()
        #expect(a.runs.count == runs)
        // Edited: a new text, certainly not sent.
        edit(after, 0, "раз, иначе")
        #expect(states(after) == [nil, .unclear])
    }

    /// Quit between the saved acceptance and the removal of the drafts.
    @Test func restartAfterAcceptanceRemovesDrafts() throws {
        let (q, j) = prepared()
        #expect(send(q, j))
        let file = dir.appendingPathComponent("drafts/" + DiffComments.fileName(forKey: key))
        let data = try Data(contentsOf: file)
        a.runs[1].onTurnStarted?()
        try data.write(to: file)
        let after = queue()
        after.openDrafts(key)
        #expect(after.drafts.comments(key).isEmpty)
    }

    /// A message that waits for its slot survives the restart and goes once.
    @Test func sentOnceWithoutAPerson() async throws {
        let (q, j) = prepared()
        q.paused = true
        #expect(send(q, j))
        #expect(a.runs.count == 1 && states(q) == [.sending, .sending])
        #expect(!send(q, j))
        q.saveNow()
        let after = queue()
        after.openDrafts(key)
        #expect(states(after) == [.sending, .sending])
        for _ in 0..<100 where a.runs.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(a.runs.count == 2 && a.runs[1].request?.prompt.contains("раз") == true)
        a.runs[1].finish { $0.turns = 0; $0.isError = true }
        #expect(states(after) == [.unclear, .unclear])
        after.pump()
        try await Task.sleep(for: .milliseconds(300))
        #expect(a.runs.count == 2)
    }

    @Test func mergeIsBlockedUntilTheTurnEnds() async {
        let (q, j) = prepared()
        j.worktree = Worktrees.Info(path: dir, main: dir, branch: "b")
        #expect(!q.hasActiveChild(j))
        j.worktree = nil
        #expect(send(q, j))
        j.worktree = Worktrees.Info(path: dir, main: dir, branch: "b")
        for started in [false, true] {
            if started { a.runs[1].onTurnStarted?() }
            #expect(q.hasActiveChild(j))
            j.worktreeNote = ""
            #expect(await q.mergeNow(j, ask: false) == false)
            #expect(j.worktreeNote.contains("идёт ответ"))
        }
        j.worktree = nil
        a.runs[1].finish()
        #expect(!q.hasActiveChild(j))
    }

    @Test func claudeTurnStartsWithTheModel() {
        let s = ClaudeStream(resume: "s1")
        var started = 0
        s.onTurnStarted = { started += 1 }
        func line(_ l: String) { s.consume(Data((l + "\n").utf8)) }
        line(#"{"type":"system","subtype":"init","session_id":"s1","model":"m"}"#)
        line(#"{"type":"assistant","session_id":"s1","message":{"model":"<synthetic>","content":[{"type":"text","text":"limit"}]}}"#)
        line(#"{"type":"result","is_error":true,"num_turns":0,"session_id":"s1"}"#)
        #expect(started == 0)
        line(#"{"type":"assistant","session_id":"s1","message":{"model":"claude-opus-5-5","content":[{"type":"thinking","thinking":""}]}}"#)
        #expect(started == 1)
    }
}
