import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Архив и черновики")
struct TaskFolderTests {
    static let a = "20261101-100000-alpha.md", b = "20261101-100001-beta.md", c = "20261101-100002-gamma.md"
    let project = FileManager.default.temporaryDirectory.appendingPathComponent("folders-\(UUID().uuidString)", isDirectory: true)
    var tasks: URL { project.appendingPathComponent("tasks", isDirectory: true) }

    func text(_ title: String, _ status: String = "todo", _ extra: String = "") -> String {
        "---\ntitle: \"\(title)\"\nstatus: \(status)\npriority: low\ncreated: 2026-11-01\ncompleted: \(status == "done" ? "2026-11-02" : "")\n\(extra)---\n\nТело\n"
    }

    @discardableResult
    func put(_ name: String, _ text: String, _ folder: TaskFolder = .active) throws -> URL {
        let dir = folder.url(in: tasks)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func load() -> Project { Codec.project(at: project, category: "c") }
    func cleanup() { try? FileManager.default.removeItem(at: project) }

    @Test func movesKeepNameAndBytes() throws {
        defer { cleanup() }
        let raw = "---\r\ntitle: \"A\"\r\nstatus: done # готово\r\ncompleted: 2026-11-02\r\ncustom: [x]  \r\n---\r\n\r\nТело  \r\n\r\n"
        var url = try put(Self.a, raw)
        for f in [TaskFolder.archive, .active, .drafts, .archive, .drafts, .active] {
            url = try TaskFile.move(url, to: f)
            #expect(url.lastPathComponent == Self.a)
            #expect(TaskFolder(of: url) == f)
            #expect(try Data(contentsOf: url) == Data(raw.utf8))
            let p = load()
            for g in TaskFolder.allCases { #expect(p[g].map(\.fileName) == (g == f ? [Self.a] : [])) }
        }
    }

    @Test func nameClashOverwritesNothing() throws {
        defer { cleanup() }
        let live = try put(Self.a, text("Живая"))
        let old = try put(Self.a, text("Старая", "done"), .archive)
        for (from, to) in [(live, TaskFolder.archive), (old, .active)] {
            #expect(throws: TaskFile.Failure.exists(Self.a)) { try TaskFile.move(from, to: to) }
        }
        #expect(try String(contentsOf: live, encoding: .utf8) == text("Живая"))
        #expect(try String(contentsOf: old, encoding: .utf8) == text("Старая", "done"))
        #expect(load().tasks[0].problems.map(\.kind) == [.nameClash(.archive)])
    }

    @Test func lintOfArchiveLinks() throws {
        defer { cleanup() }
        try put(Self.a, text("A", "todo", "depends: [\(Self.b), \(Self.c), nope.md]\n"))
        try put(Self.b, text("B", "done"), .archive)
        try put(Self.c, text("C"), .archive)
        #expect(load().tasks[0].problems.map(\.kind) == [.parkedDepend(Self.c), .brokenDepend("nope.md")])
        #expect(Codec.tasks(in: tasks)[0].problems == load().tasks[0].problems)
        #expect(try TaskFile.all(in: tasks).files[0].item.problems == load().tasks[0].problems)
    }

    @Test func draftLinks() throws {
        defer { cleanup() }
        try put(Self.a, text("A", "todo", "depends: [\(Self.b)]\n"))
        try put(Self.b, text("B", "done"), .drafts)
        try put(Self.c, text("C", "todo", "depends: [\(Self.a), \(Self.b), nope.md]\n"), .drafts)
        let p = load()
        #expect(p.tasks[0].problems.map(\.kind) == [.parkedDepend(Self.b)])
        #expect(p.drafts.first { $0.fileName == Self.c }?.problems.map(\.kind) == [.brokenDepend("nope.md")])
        #expect(p.openCount == 1)
    }

    @Test func queueOrder() throws {
        defer { cleanup() }
        try put(Self.a, text("A", "todo", "depends: [\(Self.b)]\n"))
        try put(Self.b, text("B", "done", "depends: [gone.md]\n"), .archive)
        try put(Self.c, text("C"), .drafts)
        let nodes = load().dependencyNodes
        #expect(DependencyPlan.order(targets: [Self.a], nodes: nodes) == .success([Self.a]))
        // A draft is never queued, even when asked for.
        #expect(DependencyPlan.order(targets: [Self.c, Self.a], nodes: nodes) == .success([Self.a]))

        for f in [TaskFolder.archive, .drafts] {
            let n = [Self.a: DependencyPlan.Node(done: false, depends: [Self.b]), Self.b: .init(done: false, depends: [], parked: f)]
            #expect(DependencyPlan.order(targets: [Self.a], nodes: n) == .failure(.parked(task: Self.a, dependency: Self.b, folder: f)))
        }
    }

    @Test func graph() throws {
        defer { cleanup() }
        try put(Self.a, text("A", "todo", "depends: [\(Self.b)]\n"))
        try put(Self.b, text("B", "done"), .archive)
        func build() -> TaskGraph.Layout {
            let p = load()
            return TaskGraph.build(p.tasks.map(TaskGraph.Task.init), parked: p.dependencyNodes.filter { $0.value.parked != nil })
        }
        #expect(build().nodes[Self.a]?.state == .ready)
        #expect(build().errors.isEmpty && build().nodes.count == 1)
        try put(Self.b, text("B"), .archive)
        #expect(build().nodes[Self.a]?.state == .error)
    }

    @Test func milestoneCountsArchivedDone() throws {
        defer { cleanup() }
        try put(Self.a, text("A", "todo", "milestone: \"v1\"\n"))
        try put(Self.b, text("B", "done", "milestone: \"v1\"\n"), .archive)
        try put(Self.c, text("C", "done", "milestone: \"v0\"\n"), .archive)
        let p = load()
        #expect(Milestone.all(in: p.tasks, archive: p.archive) == [Milestone(name: "v1", done: 1, total: 2)])
    }

    @Test func cli() throws {
        defer { cleanup() }
        try put(Self.a, text("A", "todo", "depends: [\(Self.b)]\n"))
        try put(Self.b, text("B", "done"), .archive)
        try put(Self.c, text("C"), .drafts)
        func tt(_ args: String...) -> (Int32, String) {
            var out = ""
            let code = CLI(cwd: project, root: project.deletingLastPathComponent(), out: { out += $0 }, err: { _ in }).run(args + ["--project", project.path])
            return (code, out)
        }
        let list = tt("list", "--ready").1
        #expect(list.contains(Self.a) && !list.contains(Self.b) && !list.contains(Self.c) && !list.contains("ждёт"))
        #expect(tt("edit", Self.a, "--depends", Self.b + "," + Self.c).0 == 0)
        #expect(!tt("list", "--ready").1.contains(Self.a))
        #expect(tt("edit", Self.b, "--title", "X").0 == 3)
        #expect(CLI.matters(.init(path: tasks.path + "/archive/" + Self.b, flags: 0)))
    }
}
