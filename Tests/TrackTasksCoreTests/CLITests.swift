import Foundation
import Testing
@testable import TrackTasksCore

/// `tt` on a temporary `<root>/cat/proj` folder.
private final class Sandbox {
    let root: URL
    let project: URL
    var tasks: URL { project.appendingPathComponent("tasks") }
    var stdin: String?
    private(set) var err = ""
    private(set) var sent: [QueueRequest] = []
    var reply: (QueueRequest) throws -> QueueResponse = { _ in throw QueueFailure(.unavailable, "TrackTasks не запущен") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("cat/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("tasks"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func run(_ args: String..., cwd: URL? = nil) -> (code: Int32, out: String) {
        var out = ""
        err = ""
        let cli = CLI(cwd: cwd ?? project, root: root, stdin: { self.stdin }, transport: { self.sent.append($0); return try self.reply($0) },
                      out: { out += $0 }, err: { self.err += $0 })
        let code = cli.run(args)
        return (code, out)
    }

    func put(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: tasks.appendingPathComponent(name))
    }

    func read(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: tasks.appendingPathComponent(name)), as: UTF8.self)
    }

    func files() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: tasks.path).sorted() }
}

private func object(_ s: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
}

private let a = "20261101-100000-alpha.md"
private let b = "20261101-100001-beta.md"
private let alpha = """
    ---
    title: "Альфа"
    status: todo        # todo | doing | done
    priority: medium
    created: 2026-11-01
    completed:
    tags: [x]
    ---

    Описание.

    - [ ] шаг

    ## Критерии готовности
    - [ ] проверка

    """
private let beta = "---\ntitle: \"Бета\"\nstatus: todo\npriority: high\ncreated: 2026-11-01\ncompleted:\ndepends: [\(a)]\n---\n\nтекст\n"

@Suite("tt: add / edit / done")
struct CLIWriteTests {
    @Test func verify() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        #expect(s.run("edit", "alpha", "--verify", "grep \"a # b\" x").code == 0)
        #expect(try s.read(a).contains("verify: \"grep \\\"a # b\\\" x\"\n"))
        #expect(s.run("show", "alpha").out.contains("проверка: grep \"a # b\" x"))
        #expect(s.run("edit", "alpha", "--verify", "a\nb").code == 2)
        #expect(s.run("edit", "alpha", "--verify", "none").code == 0)
        #expect(try s.read(a) == alpha)
        // A field that can't be read is replaced or removed too.
        let twice = alpha.replacingOccurrences(of: "completed:", with: "verify: x\nVerify: y\ncompleted:")
        try s.put(a, twice)
        #expect(s.run("edit", "alpha", "--verify", "z").code == 0)
        #expect(Codec.task(from: try s.read(a), url: URL(fileURLWithPath: a)).verify == "z")
        #expect(s.run("add", "С проверкой", "--verify", "npm test").code == 0)
    }

    @Test func repos() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        let git = s.root.appendingPathComponent("cat/api/.git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: x".utf8).write(to: git.appendingPathComponent("HEAD"))
        #expect(s.run("edit", "alpha", "--repos", "cat/api").code == 0)
        #expect(try s.read(a).contains("repos: [cat/api]\n"))
        #expect(s.run("edit", "alpha", "--repos", "../../etc").code != 0)
        #expect(s.run("add", "Чужая", "--repos", "/etc").code != 0)
        #expect(try s.files().count == 1)
        #expect(s.run("edit", "alpha", "--repos", "none").code == 0)
        #expect(try s.read(a) == alpha)
    }

    @Test func files() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        #expect(s.run("edit", "alpha", "--files", "Sources/A.swift, Tests/").code == 0)
        #expect(try s.read(a) == alpha.replacingOccurrences(of: "tags: [x]\n", with: "tags: [x]\nfiles: [Sources/A.swift, Tests/]\n"))
        let t = try #require(try object(s.run("show", "alpha", "--json").out)["task"] as? [String: Any])
        #expect(t["files"] as? [String] == ["Sources/A.swift", "Tests/"])
        #expect(s.run("edit", "alpha", "--files", "../x").code == 2)
        #expect(s.run("edit", "alpha", "--files", "none").code == 0)
        #expect(try s.read(a) == alpha)
        #expect(s.run("add", "Новая", "--files", "src/").code == 0)
        #expect(try s.files().contains { try s.read($0).contains("files: [src/]") })
    }

    @Test func addCreatesCanonicalFile() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        s.stdin = "Из stdin\n"
        let r = s.run("add", "Новая: \"задача\"", "--priority", "high", "--size=s", "--depends", "alpha", "--body", "-",
                      "--item", "раз", "--item", "два", "--criterion", "тест", "--json")
        #expect(r.code == 0)
        let t = try #require(try object(r.out)["task"] as? [String: Any])
        let name = try #require(t["file"] as? String)
        #expect(TaskLint.isValidFileName(name))
        #expect((t["problems"] as? [String]) == [])
        let today = Codec.today()
        #expect(try s.read(name) == """
            ---
            title: "Новая: \\"задача\\""
            status: todo
            priority: high
            created: \(today)
            completed:
            size: s
            depends: [\(a)]
            ---

            Из stdin

            - [ ] раз
            - [ ] два

            ## Критерии готовности

            - [ ] тест

            """)
        #expect(try s.files().count == 2)
    }

    @Test func addRefusesDuplicatesAndUnknownDepends() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        #expect(s.run("add", "альфа").code == 5)
        #expect(s.run("add", "x", "--depends", "nope").code == 3)
        #expect(s.run("add", "  ").code == 2)
        #expect(try s.files() == [a])
        #expect(s.run("add", "альфа", "--force").code == 0)
    }

    @Test func createNeverOverwrites() throws {
        let s = try Sandbox()
        let item = TaskItem(url: s.tasks, title: "x", status: .todo, priority: .low, created: "2026-11-01", completed: "", body: "")
        let now = Date()
        let one = try TaskFile.create(item, in: s.tasks, now: now), two = try TaskFile.create(item, in: s.tasks, now: now)
        #expect(one.url != two.url)
        #expect(try s.files().count == 2)
    }

    @Test func editTouchesOnlyChangedLines() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        #expect(s.run("edit", "alpha", "--status", "doing", "--check", "1").code == 0)
        #expect(try s.read(a) == alpha.replacingOccurrences(of: "status: todo        #", with: "status: doing #")
            .replacingOccurrences(of: "- [ ] шаг", with: "- [x] шаг"))
        #expect(try s.files() == [a])
    }

    @Test func editKeepsCRLFAndMode() throws {
        let s = try Sandbox()
        let crlf = alpha.replacingOccurrences(of: "\n", with: "\r\n")
        try s.put(a, crlf)
        let path = s.tasks.appendingPathComponent(a).path
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        #expect(s.run("edit", a, "--priority", "low").code == 0)
        #expect(try s.read(a) == crlf.replacingOccurrences(of: "priority: medium", with: "priority: low"))
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func editNoChange() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        let r = s.run("edit", "alpha", "--priority", "medium", "--json")
        #expect(r.code == 0)
        #expect(try object(r.out)["changed"] as? Bool == false)
        #expect(try s.read(a) == alpha)
    }

    @Test func editRepairsBadValue() throws {
        let s = try Sandbox()
        try s.put(a, alpha.replacingOccurrences(of: "priority: medium", with: "priority: urgent"))
        #expect(s.run("edit", "alpha", "--priority", "medium").code == 0)
        #expect(try s.read(a) == alpha)
    }

    @Test func editDepends() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        try s.put(b, beta)
        #expect(s.run("edit", "alpha", "--add-depend", "beta").code == 5)  // cycle
        #expect(s.run("edit", "alpha", "--add-depend", "alpha").code == 5)
        #expect(try s.read(a) == alpha)
        #expect(s.run("edit", "beta", "--rm-depend", "alpha").code == 0)
        #expect(try !s.read(b).contains("depends"))
    }

    @Test func editRefusesBrokenFrontmatter() throws {
        let s = try Sandbox()
        try s.put(a, "---\ntitle: x\nтекст без конца\n")
        #expect(s.run("edit", a, "--status", "doing").code == 5)
        #expect(try s.read(a) == "---\ntitle: x\nтекст без конца\n")
    }

    @Test func conflicts() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        let f = try TaskFile(reading: s.tasks.appendingPathComponent(a))
        #expect(s.run("edit", a, "--if-rev", f.rev, "--note", "раз").code == 0)
        let now = try s.read(a)
        #expect(throws: TaskFile.Failure.changed(a)) { try f.write("новое") }
        #expect(s.run("edit", a, "--if-rev", f.rev, "--note", "два").code == 4)
        #expect(s.run("done", a, "--if-rev", f.rev, "--force").code == 4)
        #expect(try s.read(a) == now)
        // A file deleted in the meantime is not brought back.
        try FileManager.default.removeItem(at: s.tasks.appendingPathComponent(a))
        #expect(throws: TaskFile.Failure.changed(a)) { try f.write("новое") }
        #expect(try s.files().isEmpty)
    }

    @Test func doneNeedsCriteria() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        #expect(s.run("done", "alpha").code == 5)
        #expect(s.run("edit", "alpha", "--status", "done").code == 5)
        #expect(try s.read(a) == alpha)
        #expect(s.run("edit", "alpha", "--check", "2").code == 0)
        #expect(s.run("done", "alpha", "--note", "итог").code == 0)
        let t = try #require(Codec.task(at: s.tasks.appendingPathComponent(a)))
        #expect(t.status == .done && t.completed == Codec.today())
        #expect(MD.notes(t.body).count == 1)
        #expect(t.problems.isEmpty)
        #expect(s.run("edit", "alpha", "--status", "todo").code == 0)
        #expect(Codec.task(at: s.tasks.appendingPathComponent(a))?.completed == "")
        #expect(s.run("edit", "alpha", "--uncheck", "2").code == 0)
        #expect(s.run("done", "alpha", "--force").code == 0)
    }

    @Test func doneKeepsCompletedDate() throws {
        let s = try Sandbox()
        let text = "---\ntitle: \"x\"\nstatus: done\npriority: low\ncreated: 2026-01-01\ncompleted: 2026-01-02\n---\n\nbody\n"
        try s.put(a, text)
        #expect(s.run("done", a).code == 0)
        #expect(try s.read(a) == text)
    }
}

@Suite("tt: reading and JSON")
struct CLIReadTests {
    @Test func listFilters() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        try s.put(b, beta)
        func names(_ r: (code: Int32, out: String)) throws -> [String] {
            (try object(r.out)["tasks"] as? [[String: Any]] ?? []).compactMap { $0["file"] as? String }
        }
        #expect(try names(s.run("list", "--json")) == [b, a])
        #expect(try names(s.run("list", "--ready", "--json")) == [a])
        #expect(try names(s.run("list", "--priority", "high,low", "--json")) == [b])
        #expect(try names(s.run("list", "--status", "done", "--json")).isEmpty)
        #expect(try names(s.run("search", "АЛЬФ", "шаг", "--json")) == [a])
        #expect(try names(s.run("list", "--all", "--json", cwd: s.root)) == [b, a])
        #expect(try names(s.run("list", "-p", "PROJ", "--json", cwd: s.root)) == [b, a])
        let nested = s.project.appendingPathComponent("src/tasks")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(try names(s.run("list", "--json", cwd: nested)) == [b, a])
    }

    @Test func showAndBoard() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        try s.put(b, beta)
        let t = try #require(try object(s.run("show", "tasks/" + a, "--json").out)["task"] as? [String: Any])
        #expect(t["blocks"] as? [String] == [b])
        #expect((t["criteriaItems"] as? [[String: Any]])?.first?["n"] as? Int == 2)
        #expect(t["size"] is NSNull)
        #expect((t["criteriaItems"] as? [[String: Any]])?.first?["evidence"] is NSNull)
        #expect(s.run("show", "alpha").out.contains("- [ ] проверка  #2"))
        let proven = "20261101-120000-proven.md"
        try s.put(proven, "---\ntitle: \"Гамма\"\nstatus: todo\n---\n\n## Критерии готовности\n- [x] один\n  - Доказательство: вывод\n    - [ ] не пункт\n- [ ] два\n")
        let p = try #require(try object(s.run("show", proven, "--json").out)["task"] as? [String: Any])
        let items = try #require(p["criteriaItems"] as? [[String: Any]])
        #expect(items.map { $0["n"] as? Int } == [1, 2])
        #expect(items[0]["evidence"] as? String == "вывод\n- [ ] не пункт")
        #expect(s.run("edit", proven, "--check", "2").code == 0)
        #expect(try String(contentsOf: s.tasks.appendingPathComponent(proven), encoding: .utf8).contains("    - [ ] не пункт\n- [x] два"))
        try FileManager.default.removeItem(at: s.tasks.appendingPathComponent(proven))
        let cols = try #require(try object(s.run("board", "--json").out)["columns"] as? [[String: Any]])
        #expect(cols.map { ($0["tasks"] as? [Any])?.count } == [2, 0, 0])
    }

    /// stdout with --json is one JSON document with schema 1, whatever happens.
    @Test func jsonAlwaysValid() throws {
        let s = try Sandbox()
        try s.put(a, alpha + "\u{0}\u{1B}[31m \"кавычки\" \u{2028}")
        try Data([0xFF, 0xFE]).write(to: s.tasks.appendingPathComponent(b))
        let cases: [([String], Int32)] = [
            (["list"], 0), (["board"], 0), (["search", "\""], 0), (["show", "alpha"], 0), (["instructions"], 0),
            ([], 0), (["--help"], 0), (["list", "-h"], 0), (["--version"], 0),
            (["nope"], 2), (["list", "--bad"], 2), (["list", "-x"], 2), (["list", "--status", "x"], 2), (["list", "extra"], 2),
            (["search", " "], 2), (["edit", "alpha"], 2), (["edit", "alpha", "--title"], 2), (["edit", "alpha", "--check", "9"], 2),
            (["edit", "alpha", "--body", "-"], 2), (["add", "y", "--watch"], 2),
            (["show", "zzz"], 3), (["show", "2026"], 0), (["show", "../x.md"], 3), (["show", b], 1), (["list", "-p", "none"], 3),
            (["done", "alpha"], 5),
        ]
        for (args, code) in cases {
            for argv in [args + ["--json"], ["--json"] + args] {
                var out = ""
                let cli = CLI(cwd: s.project, root: s.root, out: { out += $0 }, err: { _ in })
                #expect(cli.run(argv) == code, "\(argv)")
                let o = try object(out)
                #expect(o["schema"] as? Int == 1, "\(argv)")
                #expect((o["error"] != nil) == (code != 0), "\(argv)")
                if args == ["list"] { #expect((o["unreadable"] as? [String])?.count == 1) }
            }
        }
        #expect(!s.run("show", "alpha").out.contains("\u{1B}"))
    }

    @Test func worktreeUsesMainFolder() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        let fm = FileManager.default
        let wt = s.root.appendingPathComponent("wt/sub")
        try fm.createDirectory(at: wt, withIntermediateDirectories: true)
        try fm.createDirectory(at: s.project.appendingPathComponent(".git/worktrees/w"), withIntermediateDirectories: true)
        try "gitdir: \(s.project.path)/.git/worktrees/w\n".write(to: s.root.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)
        let top = s.root.appendingPathComponent("wt")
        #expect(ProjectScan.mainCheckout(top).path == s.project.standardizedFileURL.path)
        #expect(s.run("edit", "tasks/" + a, "--status", "doing", cwd: top).code == 0)
        #expect(try s.read(a).contains("status: doing"))
        #expect(s.run("list", cwd: wt).out.contains("Альфа"))
    }
}

@Suite struct CLIQueueTests {
    private let job = QueueJob(id: "ABCDEF12-0000", kind: "runTask", state: "pending", title: "Аль\u{1B}[31mфа", project: "proj",
                               projectPath: "/x", taskPath: "/x/tasks/" + a, waitReason: "ждёт")

    @Test func closedApp() throws {
        let s = try Sandbox()
        #expect(s.run("queue", "list").code == 6)
        #expect(s.err.contains("не запущен"))
        let r = s.run("queue", "open", "--json")
        #expect(r.code == 6)
        #expect((try object(r.out)["error"] as? [String: Any])?["code"] as? String == "unavailable")
        // Everything else works without the app.
        #expect(s.run("list").code == 0)
    }

    @Test func requests() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        s.reply = { _ in QueueResponse(jobs: [job], log: ["x\u{1B}[2J"]) }
        #expect(s.run("queue", "add", "alpha", "--with-deps").code == 0)
        #expect(s.sent.last?.tasks == [a] && s.sent.last?.withDeps == true)
        #expect(s.sent.last?.project.map { URL(fileURLWithPath: $0).lastPathComponent } == "proj")
        #expect(s.run("queue", "cancel", "abcdef12").code == 0)
        #expect(s.sent.last == QueueRequest(.cancel, job: "abcdef12"))
        s.stdin = "из stdin"
        #expect(s.run("queue", "answer", "abcdef12", "-").code == 0)
        #expect(s.sent.last == QueueRequest(.answer, job: "abcdef12", text: "из stdin"))
        let log = s.run("queue", "log", "abcdef12", "--tail", "3")
        #expect(s.sent.last == QueueRequest(.log, job: "abcdef12", tail: 3))
        #expect(log.out == "x[2J\n")
        let list = try object(s.run("queue", "list", "--json").out)
        #expect(list["command"] as? String == "queue" && list["action"] as? String == "list")
        #expect((list["jobs"] as? [[String: Any]])?.first?["file"] as? String == a)
        #expect(!s.run("queue", "list").out.contains("\u{1B}"))
        #expect(s.run("queue", "list", "-p", "proj").out == "Очередь пуста\n")
    }

    @Test func usage() throws {
        let s = try Sandbox()
        try s.put(a, alpha)
        for bad in [["queue"], ["queue", "merge", "x"], ["queue", "approve", "x"], ["queue", "allow", "x"], ["queue", "cancel"],
                    ["queue", "cancel", "x", "--with-deps"], ["queue", "log", "x", "--tail", "0"], ["queue", "answer", "x", " "],
                    ["queue", "list", "extra"]] {
            var out = ""
            let cli = CLI(cwd: s.project, root: s.root, out: { out += $0 }, err: { _ in })
            #expect(cli.run(bad) == 2, "\(bad)")
        }
        #expect(s.run("queue", "add", "нет-такой").code == 3)
        #expect(s.sent.isEmpty)
    }

    @Test func failures() throws {
        let s = try Sandbox()
        for (c, exit) in [(QueueFailure.Code.notFound, Int32(3)), (.conflict, 4), (.invalid, 5), (.version, 6)] {
            s.reply = { _ in throw QueueFailure(c, "m") }
            #expect(s.run("queue", "cancel", "x").code == exit)
        }
    }
}
