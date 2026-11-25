import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

@MainActor @Suite struct SnapshotTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(args: [String], input: String?)] = []
        func add(_ a: [String], _ i: String?) { lock.lock(); items.append((a, i)); lock.unlock() }
        var all: [(args: [String], input: String?)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("tt-snap-\(UUID().uuidString)/snapshots.json")

    private func make(_ answer: Worktrees.Result) -> (SnapshotStore, SnapshotDraft, Calls) {
        let calls = Calls()
        let s = SnapshotStore(url: file) { calls.add($0, $1); return answer }
        let d = SnapshotDraft(job: UUID(), title: "Задача", store: s, redactor: Redactor(home: "/Users/ivan"))
        d.show(Redactor().clean("текст"))
        return (s, d, calls)
    }

    private nonisolated static let created = Worktrees.Result(ok: true, out: #"{"id":"ab12","html_url":"https://gist.github.com/u/ab12"}"#, err: "")

    @Test func nothingIsPublishedWithoutConfirmation() async {
        let (s, d, calls) = make(Self.created)
        await d.confirm("текст")
        d.ask()
        d.cancel()
        await d.confirm("текст")
        // Another text than the one in the question.
        d.ask()
        await d.confirm("другой")
        #expect(calls.all.isEmpty && s.items.isEmpty)
    }

    @Test func confirmedTextGoesOutOnce() async {
        let (s, d, calls) = make(Self.created)
        d.ask()
        d.asking = false    // the alert closes before its button acts
        await d.confirm("текст")
        await d.confirm("текст")
        #expect(calls.all.count == 1)
        #expect(calls.all.first?.args == GistAPI.createArgs)
        #expect(calls.all.first?.input == GistAPI.createBody("текст"))
        #expect(s.items.map(\.id) == ["ab12"])
        #expect(SnapshotStore(url: file) { _, _ in Self.created }.items.map(\.id) == ["ab12"])
    }

    @Test func editsAreCleanedBeforeTheQuestion() async {
        let (_, d, calls) = make(Self.created)
        d.text = "cd /Users/ivan/x"
        d.ask()
        #expect(d.asked == nil && d.text == "cd ~/x" && !d.error.isEmpty)
        d.ask()
        #expect(d.asked == "cd ~/x")
        #expect(calls.all.isEmpty)
    }

    @Test func deleteKeepsTheLinkOnFailure() async {
        let (s, d, _) = make(Self.created)
        d.ask()
        await d.confirm("текст")
        let g = s.items[0]
        let bad = SnapshotStore(url: file) { _, _ in .init(ok: false, out: "", err: "gh: Not Found (HTTP 404)") }
        #expect(await bad.delete(g) != nil)
        #expect(bad.items.map(\.id) == [g.id])
        let calls = Calls()
        let good = SnapshotStore(url: file) { calls.add($0, $1); return .init(ok: true, out: "", err: "") }
        #expect(await good.delete(g) == nil)
        #expect(good.items.isEmpty)
        #expect(calls.all.first?.args == GistAPI.deleteArgs("ab12"))
    }

    @Test func snapshotFallsBackToTheQueueLog() {
        let j = Job(kind: .runTask, title: "Т", projectID: nil, projectName: "p", cwd: file, prompt: "сделай", systemPrompt: "sys")
        j.log = ["⚙︎ $ cat secret", "готово"]
        let t = j.snapshotSource(agent: "Codex", kind: "Выполнение").make()
        #expect(t.partial)
        #expect(t.messages == [.init(.user, "сделай"), .init(.agent, "готово")])
    }
}
