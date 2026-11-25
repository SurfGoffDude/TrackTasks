import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Subtask limits")
struct SubtaskLimitTests {
    private func fits(_ parent: String, _ t: [(file: String, parent: String)]) -> Bool {
        (try? SubtaskLimit.check(parent: parent, t)) != nil
    }

    @Test func depth() {
        let t = [("a", ""), ("b", "a"), ("c", "b")].map { (file: $0.0, parent: $0.1) }
        #expect(fits("a", t))
        #expect(fits("b", t))
        #expect(!fits("c", t))
    }

    @Test func children() {
        var t = [(file: "a", parent: "")] + (0..<9).map { (file: "c\($0)", parent: "a") }
        #expect(fits("a", t))
        t.append((file: "c9", parent: "a"))
        #expect(!fits("a", t))
        #expect(fits("c9", t))
    }

    @Test func tree() {
        var t = [(file: "a", parent: ""), (file: "other", parent: "")]
        for i in 0..<5 {
            t.append((file: "b\(i)", parent: "a"))
            for j in 0..<5 where t.count < 31 { t.append((file: "c\(i)-\(j)", parent: "b\(i)")) }
        }
        t = Array(t.prefix(31)) // root, other and 29 below the root
        #expect(fits("a", t))
        t.append((file: "last", parent: "a"))
        #expect(!fits("a", t))
        #expect(!fits("b0", t))
        #expect(fits("other", t))
    }

    @Test func brokenChainAndCycle() {
        #expect(!fits("a", [(file: "a", parent: "gone")]))
        #expect(!fits("a", [(file: "a", parent: "b"), (file: "b", parent: "a")]))
        #expect(!fits("gone", []))
    }

    @Test func lint() {
        func task(_ name: String, _ parent: String) -> TaskItem {
            var t = TaskItem(url: URL(fileURLWithPath: "/p/tasks/\(name)"), title: name, status: .todo, priority: .medium,
                             created: "2026-11-24", completed: "", body: "")
            t.parent = parent
            return t
        }
        var tasks = [task("ok", "archived"), task("self", "self"), task("missing", "no"), task("x", "y"), task("y", "x")]
        TaskLint.crossCheck(&tasks, others: [task("archived", "")])
        func bad(_ t: TaskItem) -> Bool { t.problems.contains { $0.kind == .badParent(t.parent) } }
        #expect(tasks.map(bad) == [false, true, true, true, true])
    }
}
