import Foundation
import Testing
@testable import TrackTasksCore

@Suite("TaskRepos")
struct TaskReposTests {
    let base: URL, root: URL, project: URL
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("tt-repos-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Projects", isDirectory: true)
        project = root.appendingPathComponent("work/app", isDirectory: true)
        for d in ["Projects/work/app", "Projects/work/api", "Projects/work/web", "Projects-evil/x", "outside"] { try repo(d) }
    }

    private func repo(_ path: String) throws {
        let git = base.appendingPathComponent(path + "/.git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
    }
    private func link(_ path: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent(path), withDestinationURL: base.appendingPathComponent(target))
    }
    private func names(_ e: String...) -> [String]? {
        guard case .success(let u) = TaskRepos.resolve(e, root: root, project: project) else { return nil }
        return u.map(\.lastPathComponent)
    }
    private func why(_ e: String...) -> String {
        guard case .failure(let f) = TaskRepos.resolve(e, root: root, project: project) else { return "" }
        return f.message
    }

    @Test func inside() throws {
        #expect(names("work/api", "work/web") == ["api", "web"])
        #expect(names(root.appendingPathComponent("work/api").path) == ["api"])
        #expect(names("work/app/../api") == ["api"])
        try link("Projects/alias", to: "Projects/work/api")
        #expect(names("alias") == ["api"])
        // The root itself may be reached through a symlink.
        try link("Root", to: "Projects")
        let r = TaskRepos.resolve(["work/api"], root: base.appendingPathComponent("Root"), project: project)
        #expect((try? r.get())?.count == 1)
    }

    @Test func outsideIsRefused() throws {
        for p in ["../outside", "work/../../outside", base.appendingPathComponent("outside").path, "../Projects-evil/x", "/", "work/none"] {
            #expect(why(p).contains("нет такой папки внутри корня"), "\(p)")
        }
        try link("Projects/out", to: "outside")
        #expect(why("out").contains("нет такой папки внутри корня"))
        #expect(why(".").contains("сам корень"))
        #expect(why("~/x").contains("нужен путь"))
        #expect(names("work/api", "../outside") == nil)
    }

    @Test func notARepository() throws {
        #expect(why("work").contains("не верхняя папка"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work/api/sub"), withIntermediateDirectories: true)
        #expect(why("work/api/sub").contains("не верхняя папка"))
        // A linked worktree belongs to another repository.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("wt"), withIntermediateDirectories: true)
        try Data("gitdir: /x/.git/worktrees/wt\n".utf8).write(to: root.appendingPathComponent("wt/.git"))
        #expect(why("wt").contains("не верхняя папка"))
    }

    @Test func repeatsAndNesting() throws {
        #expect(why("work/api", "work/api/").contains("дважды"))
        #expect(why("work/app").contains("самого проекта"))
        let sub = root.appendingPathComponent("work/app/packages/a")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let r = TaskRepos.resolve(["work/app"], root: root, project: sub)
        #expect(throws: TaskRepos.Failure.self) { try r.get() }
        try repo("Projects/work/app/inner")
        #expect(why("work/app/inner").contains("вложен"))
        try repo("Projects/work/api/inner")
        #expect(why("work/api", "work/api/inner").contains("вложен"))
        #expect(why("work/api/inner", "work/api").contains("вложен"))
    }

    @Test func letterCase() throws {
        // Only where the disk doesn't tell the cases apart.
        guard FileManager.default.fileExists(atPath: root.path.uppercased()) || FileManager.default.fileExists(atPath: root.appendingPathComponent("WORK/API").path) else { return }
        #expect(names("WORK/API") == ["api"])
        #expect(why("work/api", "WORK/Api").contains("дважды"))
        #expect(why("Work/App").contains("самого проекта"))
    }

    @Test func fileFieldAndLint() throws {
        let text = "---\ntitle: \"T\"\nstatus: todo\npriority: low\ncreated: 2026-11-24\ncompleted:\nrepos: [work/api, \"work/web\"]\n---\n\nТело\n"
        let url = project.appendingPathComponent("tasks/20261124-100000-t.md")
        var t = Codec.task(from: text, url: url)
        #expect(t.repos == ["work/api", "work/web"] && t.problems.isEmpty)
        #expect(Codec.serialize(t, updating: text) == text)
        t.repos = ["work/api"]
        #expect(Codec.serialize(t, updating: text).contains("repos: [work/api]\n"))
        #expect(Codec.task(from: Codec.serialize(t), url: url).repos == ["work/api"])
        t.repos = []
        #expect(!Codec.serialize(t, updating: text).contains("repos"))
        #expect(Codec.task(from: text.replacingOccurrences(of: "work/api", with: "~/x"), url: url).problems.map(\.kind) == [.field("repos")])
        #expect(Codec.task(from: text.replacingOccurrences(of: "repos:", with: "worktree: never\nrepos:"), url: url).problems.map(\.kind) == [.field("repos")])

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.replacingOccurrences(of: "work/api", with: "../outside").write(to: url, atomically: true, encoding: .utf8)
        var p = Codec.project(at: project, category: "work")
        TaskRepos.lint(&p, root: root)
        #expect(p.tasks.first?.problems.map(\.kind) == [.badRepo])
    }
}
