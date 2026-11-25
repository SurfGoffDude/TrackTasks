import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Docker: аргументы и обмен файлами")
struct DockerArgsTests {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt docker-\(UUID().uuidString)")
        for n in ["main/tasks", "wt", "out", "conflicts"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(n), withIntermediateDirectories: true)
        }
    }

    private func spec(_ wt: String = "/a b/wt") -> ContainerSpec {
        ContainerSpec(image: "img", worktree: URL(fileURLWithPath: wt), gitSeal: URL(fileURLWithPath: "/s/seal"),
                      command: ["run", "it"], instance: "i", job: "j", uid: 501, gid: 20)
    }

    @Test func mountsOnlyWorktree() throws {
        let a = try spec().createArgs()
        let mounts = a.indices.filter { a[$0] == "--mount" }.map { a[$0 + 1] }
        #expect(mounts == ["type=bind,source=/a b/wt,target=/workspace",
                           "type=bind,source=/s/seal,target=/workspace/.git,readonly"])
        #expect(!a.contains("-v") && !a.contains("--volume") && !a.contains("--privileged"))
        #expect(!a.joined(separator: " ").contains("docker.sock"))
        #expect(a.suffix(3) == ["tracktasks", "run", "it"])
        for (k, v) in [("--network", "none"), ("--cap-drop", "ALL"), ("--user", "501:20"), ("--pull", "never"),
                       ("--security-opt", "no-new-privileges")] {
            let i = try #require(a.firstIndex(of: k))
            #expect(a[i + 1] == v)
        }
        #expect(a.contains("--read-only") && a.contains("--rm") && a.contains("--pids-limit") && a.contains("--memory"))
    }

    @Test(arguments: ["/a,b", "/", "/a\"b", "/a\nb"]) func badPath(p: String) {
        #expect(throws: ContainerSpec.Problem.self) { try spec(p).createArgs() }
    }

    @Test func badValues() {
        var s = spec(); s.uid = 0
        #expect(throws: ContainerSpec.Problem.root) { try s.createArgs() }
        s = spec(); s.image = "--privileged"
        #expect(throws: ContainerSpec.Problem.self) { try s.createArgs() }
        for n in ["host", "container:x", "bridge"] {
            s = spec(); s.network = .named(n)
            #expect(throws: ContainerSpec.Problem.self) { try s.createArgs() }
        }
        s = spec(); s.secrets = ["TOKEN=abc"]
        #expect(throws: ContainerSpec.Problem.self) { try s.createArgs() }
    }

    @Test func secretHasNoValue() throws {
        var s = spec(); s.secrets = ["TOKEN"]
        let a = try s.createArgs()
        let i = try #require(a.firstIndex(of: "TOKEN"))
        #expect(a[i - 1] == "-e")
    }

    @Test func sessionsVolume() throws {
        var s = spec(); s.sessions = "tracktasks-abc"
        #expect(try s.createArgs().contains("type=volume,source=tracktasks-abc,target=/home/agent/.claude"))
        s.sessions = "/Users"
        #expect(throws: ContainerSpec.Problem.self) { try s.createArgs() }
    }

    @Test func restoreBringsWorktreeFilesBack() throws {
        let main = dir.appendingPathComponent("main"), wt = dir.appendingPathComponent("wt")
        func put(_ u: URL, _ t: String) throws { try t.write(to: u, atomically: true, encoding: .utf8) }
        try put(main.appendingPathComponent("tasks/t.md"), "---\nstatus: todo\n---\n")
        try put(main.appendingPathComponent("about.md"), "new")
        try put(wt.appendingPathComponent("about.md"), "old")
        let x = try DockerExchange.begin(main: main, worktree: wt, taskFile: "t.md", extra: ["tasks/d.diff": Data("d".utf8)])
        #expect(try String(contentsOf: wt.appendingPathComponent("about.md"), encoding: .utf8) == "new")
        x.restore()
        #expect(try String(contentsOf: wt.appendingPathComponent("about.md"), encoding: .utf8) == "old")
        for n in ["tasks/t.md", "tasks/d.diff"] { #expect(!FileManager.default.fileExists(atPath: wt.appendingPathComponent(n).path)) }
    }

    /// Fails halfway: what was already copied is taken back.
    @Test func failedBeginRestores() throws {
        let main = dir.appendingPathComponent("main"), wt = dir.appendingPathComponent("wt")
        try "---\nstatus: todo\n---\n".write(to: main.appendingPathComponent("tasks/t.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: main.appendingPathComponent("about.md"), withIntermediateDirectories: true)
        #expect(throws: SafeFolder.Failure.self) { try DockerExchange.begin(main: main, worktree: wt, taskFile: "t.md") }
        #expect(!FileManager.default.fileExists(atPath: wt.appendingPathComponent("tasks/t.md").path))
    }

    @Test func executorChoice() {
        #expect(Executor.resolve(project: "", task: "") == .use(.local))
        #expect(Executor.resolve(project: "", task: "docker") == .use(.docker))
        #expect(Executor.resolve(project: "docker", task: "local") == .use(.docker))
        #expect(Executor.resolve(project: "docker", task: "x") == .invalid("x"))
        #expect(Executor.resolve(project: "Docker ", task: "") == .invalid("Docker "))
    }

    @Test func lint() {
        func problems(_ f: String) -> [TaskProblem.Kind] {
            TaskLint.fileProblems(text: "---\ntitle: T\nstatus: todo\n\(f)\n---\n", fileName: "20261123-142040-docker.md").map(\.kind)
        }
        #expect(problems("executor: docker").isEmpty)
        #expect(problems("executor: vm") == [.field("executor")])
        #expect(problems("executor: docker\nworktree: never") == [.field("executor")])
    }

    // MARK: Exchange

    private var main: URL { dir.appendingPathComponent("main") }
    private var wt: URL { dir.appendingPathComponent("wt") }
    private var out: URL { dir.appendingPathComponent("out") }
    private static let task = "---\ntitle: T\nstatus: doing\n---\n"
    private func put(_ s: String, _ u: URL) throws { try Data(s.utf8).write(to: u) }
    private func text(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }

    private func begin() throws -> DockerExchange {
        try put(Self.task, main.appendingPathComponent("tasks/t.md"))
        try put("about", main.appendingPathComponent("about.md"))
        return try DockerExchange.begin(main: main, worktree: wt, taskFile: "t.md")
    }

    @Test func taskGoesThereAndBack() throws {
        let x = try begin()
        #expect(text(wt.appendingPathComponent("about.md")) == "about")
        #expect(try x.finish(conflicts: out) == .unchanged)
        try put(Self.task + "итог", wt.appendingPathComponent("tasks/t.md"))
        try put("evil", wt.appendingPathComponent("about.md"))
        try put("evil", wt.appendingPathComponent("tasks/other.md"))
        #expect(try x.finish(conflicts: out) == .updated)
        #expect(text(main.appendingPathComponent("tasks/t.md")) == Self.task + "итог")
        #expect(text(main.appendingPathComponent("about.md")) == "about")
        #expect(text(main.appendingPathComponent("tasks/other.md")) == nil)
    }

    @Test(arguments: [true, false]) func changedOriginalStays(deleted: Bool) throws {
        let x = try begin(), orig = main.appendingPathComponent("tasks/t.md")
        try put(Self.task + "агент", wt.appendingPathComponent("tasks/t.md"))
        if deleted { try FileManager.default.removeItem(at: orig) } else { try put(Self.task + "человек", orig) }
        guard case .conflict(let u) = try x.finish(conflicts: dir.appendingPathComponent("conflicts")) else {
            Issue.record("conflict expected"); return
        }
        #expect(text(u) == Self.task + "агент")
        #expect(text(orig) == (deleted ? nil : Self.task + "человек"))
    }

    @Test func symlinksAreNotFollowed() throws {
        let x = try begin(), fm = FileManager.default
        let secret = out.appendingPathComponent("t.md")
        try put(Self.task + "секрет", secret)
        let inside = wt.appendingPathComponent("tasks/t.md")
        try fm.removeItem(at: inside)
        try fm.createSymbolicLink(at: inside, withDestinationURL: secret)
        #expect(throws: SafeFolder.Failure.self) { try x.finish(conflicts: out) }
        // Parent folder.
        try fm.removeItem(at: wt.appendingPathComponent("tasks"))
        try fm.createSymbolicLink(at: wt.appendingPathComponent("tasks"), withDestinationURL: out)
        #expect(throws: SafeFolder.Failure.self) { try x.finish(conflicts: out) }
        #expect(throws: SafeFolder.Failure.self) { try begin() }
        #expect(text(secret) == Self.task + "секрет")
        #expect(text(main.appendingPathComponent("tasks/t.md")) == Self.task)
        // A symlink in place of about.md is replaced, its target is not written.
        try fm.removeItem(at: wt.appendingPathComponent("tasks"))
        try fm.removeItem(at: wt.appendingPathComponent("about.md"))
        try fm.createSymbolicLink(at: wt.appendingPathComponent("about.md"), withDestinationURL: secret)
        _ = try begin()
        #expect(text(secret) == Self.task + "секрет")
        #expect(text(wt.appendingPathComponent("about.md")) == "about")
    }

    @Test func oddFilesAreRefused() throws {
        let x = try begin(), inside = wt.appendingPathComponent("tasks/t.md")
        try Data(count: DockerExchange.limit + 1).write(to: inside)
        #expect(throws: SafeFolder.Failure.self) { try x.finish(conflicts: out) }
        try put("без frontmatter", inside)
        #expect(throws: SafeFolder.Failure.self) { try x.finish(conflicts: out) }
        try FileManager.default.removeItem(at: inside)
        #expect(mkfifo(inside.path, 0o644) == 0)
        #expect(throws: SafeFolder.Failure.self) { try x.finish(conflicts: out) }
        #expect(throws: SafeFolder.Failure.self) { try SafeFolder(wt).read("../main/about.md", limit: 10) }
    }

    @Test func seal() throws {
        let git = wt.appendingPathComponent(".git")
        try put("gitdir: /m/.git/worktrees/x\n", git)
        let sealed = try #require(WorktreeSeal.read(wt))
        #expect(WorktreeSeal.problem(wt, sealed: sealed) == nil)
        let nested = wt.appendingPathComponent("a/node_modules/.GIT")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(WorktreeSeal.problem(wt, sealed: sealed) != nil)
        try FileManager.default.removeItem(at: wt.appendingPathComponent("a"))
        try put("gitdir: evil\n", git)
        #expect(WorktreeSeal.problem(wt, sealed: sealed) != nil)
    }
}
