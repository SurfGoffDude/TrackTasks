import Foundation
import Testing
@testable import TrackTasksCore

@Suite("AgentReply")
struct AgentReplyTests {
    func blocked(active: Bool = false, session: Bool = true, ranInWorktree: Bool = false, worktree: Bool = false,
                 merged: Bool = false, busy: Bool = false, child: Bool = false) -> String? {
        AgentReply.blocked(isActive: active, hasSession: session, ranInWorktree: ranInWorktree, hasWorktree: worktree,
                           merged: merged, worktreeBusy: busy, hasActiveChild: child)
    }

    @Test func availability() {
        #expect(blocked() == nil)
        #expect(blocked(ranInWorktree: true, worktree: true) == nil)
        #expect(blocked(active: true) != nil)
        #expect(blocked(session: false) != nil)
        #expect(blocked(busy: true) != nil)
        #expect(blocked(child: true) != nil)
    }

    @Test func removedWorktreeIsExplained() {
        #expect(blocked(ranInWorktree: true)?.contains("worktree удалён") == true)
        #expect(blocked(ranInWorktree: true, merged: true)?.contains("слита") == true)
    }

    @Test func restartKeepsTextAndState() throws {
        let waiting = AgentReply(id: UUID(), text: "ждёт")
        let running = AgentReply(id: UUID(), text: "шло")
        let done = AgentReply(id: UUID(), text: "готово", state: .done, answer: "ок")
        let data = try JSONEncoder().encode([waiting, running, done])
        let r = AgentReply.restored(try JSONDecoder().decode([AgentReply].self, from: data), activeJobs: [waiting.id])
        #expect(r.map(\.text) == ["ждёт", "шло", "готово"])
        #expect(r.map(\.state) == [.active, .failed, .done])
        #expect(r[1].canRepeat && !r[1].error.isEmpty)
        #expect(r[2].answer == "ок")
    }

    /// The child job shares its parent's folder and must never run there next to another job.
    @Test func replyWaitsForItsFolder() {
        typealias J = QueuePlanner.Job
        let s = QueuePlanner.Settings(limit: 3, dirtyFiles: ["/p": []])
        let main = J(state: .running), mainReply = J(mustUseMain: true)
        #expect(QueuePlanner.decide(jobs: [main, mainReply], settings: s)[mainReply.id] == .wait(.sameFolder(.plain)))
        let wt = J(state: .running, worktree: "/wt"), wtReply = J(worktree: "/wt")
        #expect(QueuePlanner.decide(jobs: [wt, wtReply], settings: s)[wtReply.id] == .wait(.worktreeBusy))
        let a = J(worktree: "/wt"), b = J(worktree: "/wt")
        let d = QueuePlanner.decide(jobs: [a, b], settings: s)
        #expect(d[a.id] == .start && d[b.id] == .wait(.worktreeBusy))
    }
}
