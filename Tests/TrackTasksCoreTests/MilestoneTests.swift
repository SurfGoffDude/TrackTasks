import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Milestones")
struct MilestoneTests {
    static let url = URL(fileURLWithPath: "/t/20261116-120000-x.md")

    static func text(_ line: String) -> String {
        "---\ntitle: \"x\"\nstatus: todo # todo | doing\npriority: medium\ncreated: 2026-11-16\ncompleted:\n\(line)tags: [a, b]\n---\n\nbody\n"
    }

    static func item(_ name: String, _ milestone: String, _ status: TaskStatus = .todo) -> TaskItem {
        var t = TaskItem(url: URL(fileURLWithPath: "/t/\(name)"), title: name, status: status, priority: .medium,
                         created: "2026-11-16", completed: "", body: "")
        t.milestone = milestone
        return t
    }

    @Test(arguments: [("milestone: \"v1.0\"\n", "v1.0"), ("milestone: v1.0 # веха\n", "v1.0"),
                      ("milestone: \"a #1\" # \"b\"\n", "a #1"), ("milestone: \"a \\\"b\\\"\"\n", "a \"b\""),
                      ("milestone:\n", ""), ("", ""), ("milestone: [a]\n", ""), ("milestone: \"a\n", "")])
    func parsesAndSavesUntouched(_ line: String, _ name: String) {
        let text = Self.text(line)
        var t = Codec.task(from: text, url: Self.url)
        #expect(t.milestone == name)
        #expect(Codec.serialize(t, updating: text) == text)
        // Another field changes: the milestone line and unknown fields stay.
        t.priority = .high
        #expect(Codec.serialize(t, updating: text) == text.replacingOccurrences(of: "priority: medium", with: "priority: high"))
    }

    @Test func editTouchesOnlyMilestone() {
        let text = Self.text("milestone: \"v1\" # веха\n")
        var t = Codec.task(from: text, url: Self.url)
        t.milestone = " v2\n#x "
        let out = Codec.serialize(t, updating: text)
        #expect(out == Self.text("milestone: \"v2 #x\" # веха\n"))
        #expect(Codec.task(from: out, url: Self.url).milestone == "v2 #x")
        t.milestone = ""
        #expect(Codec.serialize(t, updating: text) == Self.text(""))
        t.milestone = "v3"
        #expect(Codec.task(from: Codec.serialize(t, updating: Self.text("")), url: Self.url).milestone == "v3")
    }

    @Test(arguments: ["v1.0", "Бета \"2\" #1", "a\\b"])
    func canonicalRoundTrip(_ name: String) {
        var t = Self.item("20261116-120000-x.md", name)
        t.depends = ["a.md"]
        let text = Codec.serialize(t)
        let back = Codec.task(from: text, url: t.url)
        #expect(back == t)
        #expect(Codec.serialize(back) == text)
    }

    @Test func lint() {
        func bad(_ line: String) -> Bool { TaskLintTests.kinds(Self.text(line)).contains(.field("milestone")) }
        #expect(bad("milestone: [a, b]\n"))
        #expect(bad("milestone: \"a\n"))
        #expect(!bad("milestone: \"v1.0\" # c\n"))
        #expect(!bad("milestone:\n"))
    }

    @Test func progressIsShareOfDone() {
        let all = Milestone.all(in: [Self.item("a", "v1.10"), Self.item("b", "v1.2", .done), Self.item("c", "v1.2", .doing),
                                     Self.item("d", "v1.2"), Self.item("e", "v1.2", .done), Self.item("f", "", .done)])
        #expect(all == [Milestone(name: "v1.2", done: 2, total: 4), Milestone(name: "v1.10", done: 0, total: 1)])
        #expect(all.map(\.progress) == [0.5, 0])
        #expect(Milestone(name: "x", done: 199, total: 200).percent == 99)
        #expect(Milestone(name: "x", done: 3, total: 3).progress == 1)
    }

    @Test func filter() {
        let tasks = [Self.item("a", "v1"), Self.item("b", "")]
        #expect(tasks.filter(MilestoneFilter.named("v1").matches).map(\.title) == ["a"])
        #expect(tasks.filter(MilestoneFilter.none.matches).map(\.title) == ["b"])
        #expect(MilestoneFilter.named("gone").valid(in: tasks) == .all)
        #expect(MilestoneFilter.none.valid(in: [tasks[1]]) == .all)
    }

    @Test func graphGroups() {
        let g = Milestone.groups(["a", "b", "c", "d"], milestone: ["a": "", "b": "v10", "c": "v2", "d": "v10"])
        #expect(g.map(\.milestone) == ["v2", "v10", ""])
        #expect(g.map(\.tasks) == [["c"], ["b", "d"], ["a"]])
    }

    /// The filtered graph shows what queuing the milestone would run, and only its errors.
    @Test func filteredGraph() {
        typealias T = TaskGraph.Task
        let tasks = [T(name: "a", status: .todo, priority: .high, depends: ["b", "d"]),
                     T(name: "b", status: .todo, priority: .low, depends: []),
                     T(name: "c", status: .todo, priority: .high, depends: ["gone"]),
                     T(name: "d", status: .done, priority: .low, depends: []),
                     T(name: "e", status: .done, priority: .low, depends: [])]
        let g = TaskGraph.build(tasks, only: ["a", "e"])
        #expect(g.columns.map(\.kind) == [.done, .wave(1, .high)])
        #expect(g.columns.map(\.tasks) == [["e"], ["b", "a"]])
        #expect(g.edges == [.init(from: "b", to: "a")])
        #expect(g.errors.isEmpty)
        #expect(!TaskGraph.build(tasks).errors.isEmpty)
    }
}
