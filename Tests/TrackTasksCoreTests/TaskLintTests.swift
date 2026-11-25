import Foundation
import Testing
@testable import TrackTasksCore

@Suite("TaskLint")
struct TaskLintTests {
    static let good = "20261116-150000-good.md"

    static func file(_ fields: String) -> String { "---\ntitle: \"T\"\n\(fields)\n---\n\nТело\n" }

    static func kinds(_ text: String, name: String = good) -> [TaskProblem.Kind] {
        TaskLint.fileProblems(text: text, fileName: name).map(\.kind)
    }

    @Test func validFileHasNoProblems() {
        let text = Self.file("status: todo        # todo | doing | done\npriority: high\ncreated: 2026-11-16\ncompleted:\nsize: m")
        #expect(Self.kinds(text).isEmpty)
    }

    @Test func badStatusPrioritySize() {
        let k = Self.kinds(Self.file("status: in-progress\npriority: urgent\nsize: xl\ncreated: 2026-11-16"))
        #expect(k.contains(.field("status")))
        #expect(k.contains(.field("priority")))
        #expect(k.contains(.field("size")))
    }

    @Test func missingStatus() {
        #expect(Self.kinds(Self.file("priority: low")).contains(.field("status")))
    }

    @Test func badDate() {
        #expect(Self.kinds(Self.file("status: todo\ncreated: 16.11.2026")).contains(.field("created")))
    }

    @Test func doneRequiresCompleted() {
        #expect(Self.kinds(Self.file("status: done\ncompleted:")).contains(.missingCompleted))
        #expect(!Self.kinds(Self.file("status: done\ncompleted: 2026-11-16")).contains(.missingCompleted))
    }

    @Test func frontmatterMissingOrUnclosed() {
        #expect(Self.kinds("# Просто заметка\n") == [.frontmatter])
        #expect(Self.kinds("---\ntitle: x\nstatus: todo\n\nтело") == [.frontmatter])
    }

    @Test func fileNames() {
        #expect(TaskLint.isValidFileName("20261116-150000-proverka-zadach.md"))
        #expect(TaskLint.isValidFileName("20261116-150000.md"))
        #expect(!TaskLint.isValidFileName("todo.md"))
        #expect(!TaskLint.isValidFileName("20261116-150000-Big_Name.md"))
        #expect(!TaskLint.isValidFileName("2026-11-16-x.md"))
        #expect(Self.kinds(Self.file("status: todo"), name: "my task.md") == [.fileName])
    }

    static func task(_ name: String, title: String, depends: [String] = []) -> TaskItem {
        TaskItem(url: URL(fileURLWithPath: "/p/tasks/\(name)"), title: title, status: .todo, priority: .medium,
                 created: "2026-11-16", completed: "", body: "", depends: depends)
    }

    @Test func brokenAndSelfDepends() {
        var ts = [
            Self.task("20261116-000001-a.md", title: "A"),
            Self.task("20261116-000002-b.md", title: "B",
                      depends: ["20261116-000001-a.md", "nope.md", "20261116-000002-b.md"]),
        ]
        TaskLint.crossCheck(&ts)
        #expect(ts[0].problems.isEmpty)
        #expect(ts[1].problems.map(\.kind) == [.brokenDepend("nope.md"), .brokenDepend("20261116-000002-b.md")])
    }

    @Test func duplicateTitles() {
        var ts = [
            Self.task("20261116-000001-a.md", title: "Сделать X"),
            Self.task("20261116-000002-b.md", title: " сделать x "),
            Self.task("20261116-000003-c.md", title: "Другое"),
        ]
        TaskLint.crossCheck(&ts)
        #expect(ts[0].problems.map(\.kind) == [.duplicate("20261116-000002-b.md")])
        #expect(ts[1].problems.map(\.kind) == [.duplicate("20261116-000001-a.md")])
        #expect(ts[2].problems.isEmpty)
    }

    @Test func crossCheckReplacesOldCrossProblemsKeepsFieldOnes() {
        var t = Self.task("20261116-000001-a.md", title: "A", depends: ["nope.md"])
        t.problems = [TaskProblem(.field("status"), "x"), TaskProblem(.brokenDepend("old.md"), "y")]
        var ts = [t]
        TaskLint.crossCheck(&ts)
        #expect(ts[0].problems.map(\.kind) == [.field("status"), .brokenDepend("nope.md")])
    }

    /// Same steps as Store.removeDepend: warning on load, drop the entry, write, re-read clean.
    @Test func brokenDependFixOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(Self.good)
        try "---\ntitle: \"T\"\nstatus: todo\npriority: medium\ncreated: 2026-11-16\ncompleted:\ndepends: [nope.md]\n---\n\nТело\n"
            .write(to: url, atomically: true, encoding: .utf8)
        var t = try #require(Codec.tasks(in: dir).first)
        #expect(t.problems.map(\.kind) == [.brokenDepend("nope.md")])
        t.depends.removeAll { $0 == "nope.md" }
        try Codec.serialize(t).write(to: url, atomically: true, encoding: .utf8)
        let back = try #require(Codec.tasks(in: dir).first)
        #expect(back.depends.isEmpty)
        #expect(back.problems.isEmpty)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("nope.md"))
    }

    /// Tasks of this repository are well-formed: zero warnings.
    @Test(.enabled(if: hasOwnTasks)) func thisProjectTasksAreClean() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tasks")
        let tasks = Codec.tasks(in: dir)
        try #require(!tasks.isEmpty)
        let found = tasks.flatMap { t in t.problems.map { "\(t.fileName): \($0.message)" } }
        #expect(found.isEmpty, "\(found)")
    }
}
