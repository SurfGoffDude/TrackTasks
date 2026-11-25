import Foundation
import Testing
@testable import TrackTasksCore

private final class Box {
    let root: URL
    let project: URL
    let outside: URL
    var sent: [QueueRequest] = []
    var reply: (QueueRequest) throws -> QueueResponse = { _ in throw QueueFailure(.unavailable, "TrackTasks не запущен") }
    var tasks: URL { project.appendingPathComponent("tasks") }
    private(set) lazy var server = make()

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        project = root.appendingPathComponent("cat/proj", isDirectory: true)
        outside = base.appendingPathComponent("outside/proj", isDirectory: true)
        for d in [project, outside] {
            try FileManager.default.createDirectory(at: d.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func make(cwd: URL? = nil, max: Int = MCPTools.maxCreated) -> MCPServer {
        MCPServer(CLI(cwd: cwd ?? project, root: root, stdin: { Issue.record("stdin carries the protocol"); return nil },
                      transport: { [unowned self] in self.sent.append($0); return try self.reply($0) }, out: { _ in }, err: { _ in }),
                  maxCreated: max)
    }

    func put(_ name: String, _ extra: String = "", body: String = "текст", in dir: URL? = nil) throws {
        let dir = dir ?? tasks
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("---\ntitle: \"\(name)\"\nstatus: todo\npriority: medium\ncreated: 2026-11-01\ncompleted:\n\(extra)---\n\n\(body)\n".utf8)
            .write(to: dir.appendingPathComponent(name))
    }

    func call(_ tool: String, _ args: [String: Any] = [:], on s: MCPServer? = nil) throws -> (error: String?, message: String, out: [String: Any]) {
        let m: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": args, "_meta": meta()]]
        let line = try #require((s ?? server).handle(try JSONSerialization.data(withJSONObject: m)))
        #expect(!line.contains("\n"))
        let r = try #require(try object(line)["result"] as? [String: Any])
        let out = try #require(r["structuredContent"] as? [String: Any])
        let text = try #require(((r["content"] as? [[String: Any]])?.first)?["text"] as? String)
        #expect(try object(text) as NSDictionary == out as NSDictionary)
        let e = out["error"] as? [String: Any]
        #expect((e != nil) == (r["isError"] as? Bool))
        return (e?["code"] as? String, e?["message"] as? String ?? "", out)
    }
}

private func meta(_ version: String = "2026-07-28") -> [String: Any] {
    ["io.modelcontextprotocol/protocolVersion": version, "io.modelcontextprotocol/clientCapabilities": [String: Any]()]
}

private func object(_ s: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
}

private func ask(_ s: MCPServer, _ text: String) throws -> [String: Any] {
    try object(try #require(s.handle(Data(text.utf8))))
}

private func code(_ r: [String: Any]) -> Int? { (r["error"] as? [String: Any])?["code"] as? Int }

private let a = "20261101-100000-alpha.md"

@Suite("MCP: protocol")
struct MCPProtocolTests {
    @Test func verifyField() throws {
        let b = try Box()
        #expect(try b.call("create_task", ["title": "С проверкой", "verify": "npm test"]).error == nil)
        let name = try #require(FileManager.default.contentsOfDirectory(atPath: b.tasks.path).first)
        let url = b.tasks.appendingPathComponent(name)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("verify: \"npm test\"\n"))
        #expect(try b.call("update_task", ["task": name, "verify": "x\ny"]).error != nil)
        #expect(try b.call("update_task", ["task": name, "verify": "none"]).error == nil)
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("verify"))
        // Nothing here approves a command.
        #expect(!MCPTools.names.contains { $0.contains("approve") })
    }

    @Test func reposOnlyInsideTheRoot() throws {
        let b = try Box()
        let git = b.root.appendingPathComponent("cat/api/.git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: x".utf8).write(to: git.appendingPathComponent("HEAD"))
        #expect(try b.call("create_task", ["title": "Чужая", "repos": [b.outside.path]]).error != nil)
        #expect(try b.call("create_task", ["title": "Своя", "repos": ["cat/api"]]).error == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: b.tasks.path)
        #expect(files.count == 1)
        #expect(try String(contentsOf: b.tasks.appendingPathComponent(files[0]), encoding: .utf8).contains("repos: [cat/api]"))
    }

    @Test func legacyClient() throws {
        let b = try Box()
        try b.put(a)
        let s = b.server
        #expect(code(try ask(s, #"{"jsonrpc":"2.0","id":0,"method":"tools/list"}"#)) == -32602)
        let i = try ask(s, #"{"jsonrpc":"2.0","id":"i","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        #expect(i["id"] as? String == "i")
        let r = try #require(i["result"] as? [String: Any])
        #expect(r["protocolVersion"] as? String == "2025-06-18")
        #expect((r["serverInfo"] as? [String: Any])?["name"] as? String == "tracktasks")
        #expect(s.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
        #expect((try ask(s, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)["result"] as? [String: Any])?.isEmpty == true)
        let l = try #require(try ask(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"_meta":{"progressToken":1}}}"#)["result"] as? [String: Any])
        #expect((l["tools"] as? [Any])?.count == MCPTools.names.count)
        #expect(l["ttlMs"] == nil && l["resultType"] == nil)
        let c = try #require(try ask(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_tasks"}}"#)["result"] as? [String: Any])
        #expect(c["isError"] as? Bool == false)
        #expect(((c["structuredContent"] as? [String: Any])?["tasks"] as? [Any])?.count == 1)
        let u = try ask(s, #"{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        #expect((u["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
    }

    @Test func modernClient() throws {
        let b = try Box()
        try b.put(a)
        func send(_ method: String, _ m: [String: Any], _ more: [String: Any] = [:]) throws -> [String: Any] {
            let o: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": method, "params": more.merging(["_meta": m]) { $1 }]
            return try object(try #require(b.server.handle(try JSONSerialization.data(withJSONObject: o))))
        }
        for method in ["server/discover", "tools/list"] {
            let r = try #require(try send(method, meta())["result"] as? [String: Any])
            #expect(r["resultType"] as? String == "complete")
            #expect(r["ttlMs"] is Int && r["cacheScope"] as? String == "public")
            #expect((r["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] != nil)
            if method == "server/discover" { #expect(r["supportedVersions"] as? [String] == ["2026-07-28"]) }
        }
        let c = try #require(try send("tools/call", meta(), ["name": "show_task", "arguments": ["task": "alpha"]])["result"] as? [String: Any])
        #expect(c["resultType"] as? String == "complete" && c["ttlMs"] == nil)
        let bad = try send("tools/list", meta("1900-01-01"))
        #expect(code(bad) == -32022)
        let data = try #require((bad["error"] as? [String: Any])?["data"] as? [String: Any])
        #expect(data["requested"] as? String == "1900-01-01" && data["supported"] as? [String] == ["2026-07-28"])
        #expect(code(try send("tools/list", ["io.modelcontextprotocol/protocolVersion": "2026-07-28"])) == -32602)
        #expect(code(try send("server/discover", [:])) == -32602)
        #expect(code(try send("ping", meta())) == -32601)
        #expect(code(try send("tools/call", meta(), ["name": "merge"])) == -32602)
        #expect(code(try send("tools/call", meta(), ["name": "list_tasks", "arguments": [1]])) == -32602)
        #expect(code(try send("tools/list", meta(), ["cursor": "x"])) == -32602)
    }

    @Test func malformed() throws {
        let s = try Box().server
        #expect(code(try ask(s, "{")) == -32700)
        #expect(code(try object(try #require(s.handle(Data([0xFF, 0xFE]))))) == -32700)
        #expect(code(try ask(s, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)) == -32600)
        #expect(code(try ask(s, #"{"id":1,"method":"ping"}"#)) == -32600)
        for id in ["null", "true", "1.5", "{}"] {
            #expect(code(try ask(s, #"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#)) == -32600)
        }
        #expect(code(try ask(s, #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)) == -32601)
        #expect(code(try ask(s, #"{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}"#)) == -32602)
        #expect(s.handle(Data(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"create_task"}}"#.utf8)) == nil)
        #expect(s.handle(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) == nil)
        #expect(s.handle(Data(" \r".utf8)) == nil)
    }

    @Test func lines() {
        var l = MCPLines(limit: 4)
        #expect(l.feed(Data("ab".utf8)).isEmpty)
        #expect(l.feed(Data("c\nd\n\nlong".utf8)) == [.text(Data("abc".utf8)), .text(Data("d".utf8))])
        #expect(l.feed(Data("er".utf8)) == [.tooLong])
        #expect(l.feed(Data("rest\nok\ntail".utf8)) == [.text(Data("ok".utf8))])
        #expect(l.finish() == [.text(Data("tail".utf8))])
    }

    @Test func command() throws {
        let b = try Box()
        var input = [Data(#"{"jsonrpc":"2.0","id":1,"#.utf8), Data("\"method\":\"ping\"}\n".utf8)]
        var out = ""
        let cli = CLI(cwd: b.project, root: b.root, out: { out += $0 }, err: { _ in },
                      input: { input.isEmpty ? nil : input.removeFirst() }, executable: "/a b/\"tt\"")
        #expect(cli.run(["mcp"]) == 0)
        #expect(out == #"{"id":1,"jsonrpc":"2.0","result":{}}"# + "\n")
        out = ""
        #expect(cli.run(["mcp", "--config"]) == 0)
        #expect(out.contains(#"claude mcp add --scope user tracktasks -- '/a b/"tt"' mcp"#))
        #expect(out.contains(#"codex mcp add tracktasks -- '/a b/"tt"' mcp"#))
        #expect(out.contains(#"command = "/a b/\"tt\"""#))
        for bad in ["--json", "--watch", "--project=x"] { #expect(cli.run(["mcp", bad]) == 2) }
    }
}

@Suite("MCP: project boundary")
struct MCPBoundaryTests {
    private let fm = FileManager.default

    @Test func pathsOutside() throws {
        let b = try Box()
        try b.put(a)
        try b.put(a, in: b.outside.appendingPathComponent("tasks"))
        let before = try fm.subpathsOfDirectory(atPath: b.outside.path).sorted()
        for p in [b.outside.path, "../../../outside/proj", "/", "/no/such", b.root.path, b.tasks.path] {
            for (tool, args) in [("list_tasks", [:]), ("create_task", ["title": "x"]), ("show_task", ["task": a])] as [(String, [String: Any])] {
                #expect(try b.call(tool, args.merging(["project": p]) { $1 }).error == "invalid", "\(tool) \(p)")
            }
        }
        for ref in [b.outside.path + "/tasks/" + a, "../../../outside/proj/tasks/" + a] {
            #expect(try b.call("show_task", ["task": ref]).error == "invalid")
            #expect(try b.call("update_task", ["task": ref, "note": "x"]).error == "invalid")
            #expect(try b.call("create_subtask", ["parent": ref, "title": "x"]).error == "invalid")
            #expect(try b.call("queue_add", ["tasks": [ref]]).error == "invalid")
        }
        #expect(b.sent.isEmpty)
        #expect(try b.call("list_tasks", on: b.make(cwd: b.outside)).error == "invalid")
        #expect(try fm.subpathsOfDirectory(atPath: b.outside.path).sorted() == before)
        #expect(try b.call("show_task", ["task": b.tasks.path + "/" + a]).error == nil)
        #expect(try b.call("list_tasks", ["project": b.project.path]).error == nil)
    }

    @Test func symlinks() throws {
        let b = try Box()
        let secret = b.outside.appendingPathComponent("tasks")
        try b.put(a, in: secret)
        // A project.
        let linked = b.root.appendingPathComponent("cat/linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: b.outside)
        for p in [linked.path, "linked"] { #expect(try b.call("list_tasks", ["project": p]).error != nil) }
        // A task file.
        try fm.createSymbolicLink(at: b.tasks.appendingPathComponent(a), withDestinationURL: secret.appendingPathComponent(a))
        #expect((try b.call("list_tasks").out["tasks"] as? [Any])?.isEmpty == true)
        #expect(try b.call("show_task", ["task": a]).error == "io")
        #expect(try b.call("update_task", ["task": a, "note": "x"]).error == "io")
        // Its tasks/, also pointing to nothing.
        try fm.removeItem(at: b.tasks)
        for target in [secret, b.outside.appendingPathComponent("new")] {
            try fm.createSymbolicLink(at: b.tasks, withDestinationURL: target)
            #expect(try b.call("list_tasks").error == "invalid")
            #expect(try b.call("create_task", ["title": "x"]).error == "invalid")
            #expect(try b.call("list_tasks", ["all": true]).error == nil)
            try fm.removeItem(at: b.tasks)
        }
        #expect(try fm.contentsOfDirectory(atPath: b.outside.path) == ["tasks"])
        #expect(try fm.contentsOfDirectory(atPath: secret.path) == [a])
    }

    @Test func worktrees() throws {
        let b = try Box()
        try b.put(a)
        let admin = b.project.appendingPathComponent(".git/worktrees/w")
        try fm.createDirectory(at: admin, withIntermediateDirectories: true)
        let git = b.outside.appendingPathComponent(".git")
        try Data("gitdir: \(admin.path)\n".utf8).write(to: git)
        // The repository does not know this folder: a forged .git.
        #expect(try b.call("list_tasks", on: b.make(cwd: b.outside)).error == "invalid")
        #expect(try b.call("list_tasks", ["project": b.outside.path]).error == "invalid")
        try Data("\(git.path)\n".utf8).write(to: admin.appendingPathComponent("gitdir"))
        #expect((try b.call("list_tasks", on: b.make(cwd: b.outside)).out["tasks"] as? [Any])?.count == 1)
    }
}

@Suite("MCP: tools")
struct MCPToolTests {
    @Test func closedList() {
        #expect(MCPTools.names == ["list_projects", "list_tasks", "search_tasks", "show_task", "create_task", "create_subtask",
                                   "update_task", "complete_task", "queue_list", "queue_add", "queue_log"])
        for t in MCPTools.list {
            let props = (t["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            #expect(props["force"] == nil)
            let name = t["name"] as? String ?? ""
            let reads = ["list_projects", "list_tasks", "search_tasks", "show_task", "queue_list", "queue_log"].contains(name)
            #expect((t["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == reads)
        }
    }

    @Test func strictArguments() throws {
        let b = try Box()
        try b.put(a)
        for args in [["task": a, "force": true], ["task": a, "parent": "x"], ["task": 1], [:], ["task": a, "check": ["1"]],
                     ["task": a, "check": [true]], ["task": a, "status": "closed"], ["task": a, "depends": ["none"]],
                     ["task": a, "note": NSNull()]] as [[String: Any]] {
            #expect(try b.call("update_task", args).error == "usage", "\(args)")
        }
        #expect(try b.call("list_tasks", ["all": 1]).error == "usage")
        #expect(try b.call("list_tasks", ["limit": 0]).error == "usage")
        // Values never become options; «-» is not stdin.
        let r = try b.call("create_task", ["title": "--force", "body": "-", "items": ["--x"]])
        let t = try #require(r.out["task"] as? [String: Any])
        #expect(t["title"] as? String == "--force")
        let shown = try #require(try b.call("show_task", ["task": t["file"]!]).out["task"] as? [String: Any])
        #expect((shown["body"] as? String)?.hasPrefix("-\n") == true)
    }

    @Test func criteriaGuardDone() throws {
        let b = try Box()
        try b.put(a, body: "текст\n\n## Критерии готовности\n- [ ] проверка")
        #expect(try b.call("complete_task", ["task": a]).error == "invalid")
        #expect(try b.call("update_task", ["task": a, "status": "done"]).error == "invalid")
        #expect(try b.call("update_task", ["task": a, "body": "x"]).error == "usage")
        let shown = try #require(try b.call("show_task", ["task": a]).out["task"] as? [String: Any])
        #expect(try b.call("update_task", ["task": a, "body": "x", "rev": shown["rev"]!, "status": "done"]).error == "invalid")
        #expect(try b.call("update_task", ["task": a, "body": "x", "rev": "0"]).error == "conflict")
        #expect(try b.call("update_task", ["task": a, "body": "новый\n\n## Критерии готовности\n- [ ] проверка\n- [ ] ещё", "rev": shown["rev"]!]).error == nil)
        #expect(try b.call("update_task", ["task": a, "check": [1, 2]]).error == nil)
        let done = try b.call("complete_task", ["task": a, "note": "итог"])
        #expect((done.out["task"] as? [String: Any])?["status"] as? String == "done")
    }

    @Test func subtasksAndDepends() throws {
        let b = try Box()
        try b.put(a)
        let first = try #require(try b.call("create_subtask", ["parent": "alpha", "title": "Первая"]).out["task"] as? [String: Any])
        let name = try #require(first["file"] as? String)
        #expect(first["parent"] as? String == a)
        let second = try #require(try b.call("create_subtask", ["parent": a, "title": "Вторая", "depends": [name]]).out["task"] as? [String: Any])
        #expect(second["depends"] as? [String] == [name])
        let shown = try #require(try b.call("show_task", ["task": a]).out["task"] as? [String: Any])
        #expect(Set(shown["children"] as? [String] ?? []) == [name, second["file"] as! String])
        #expect(try b.call("update_task", ["task": a, "add_depends": [name]]).error == nil)
        #expect(try b.call("update_task", ["task": name, "add_depends": [a]]).error == "invalid")
        #expect(try b.call("update_task", ["task": a, "depends": [String]()]).error == nil)
        #expect(try b.call("create_subtask", ["parent": "no-such", "title": "x"]).error == "not_found")
        // Two levels below the root, not three.
        let deep = try #require(try b.call("create_subtask", ["parent": name, "title": "Глубже"]).out["task"] as? [String: Any])
        #expect(try b.call("create_subtask", ["parent": deep["file"]!, "title": "Ещё глубже"]).error == "invalid")
    }

    @Test func closedAndParkedSubtasksCount() throws {
        let b = try Box()
        try b.put(a)
        for i in 0..<9 {
            let dir = [b.tasks, TaskFolder.archive.url(in: b.tasks), TaskFolder.drafts.url(in: b.tasks)][i % 3]
            try b.put("20261102-10000\(i)-s.md", "parent: \(a)\n", in: dir)
        }
        #expect(try b.call("create_subtask", ["parent": a, "title": "десятая"]).error == nil)
        let r = try b.call("create_subtask", ["parent": a, "title": "лишняя"])
        #expect(r.error == "invalid" && r.message.contains("лимит"))
    }

    @Test func concurrentSubtasksStopAtLimit() throws {
        let b = try Box()
        try b.put(a)
        let (root, project, parent) = (b.root, b.project, a)
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            let t = MCPTools(CLI(cwd: project, root: root, out: { _ in }, err: { _ in }), maxCreated: 50)
            _ = try? t.call("create_subtask", ["parent": parent, "title": "Подзадача \(i)"])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: b.tasks.path).filter { $0.hasSuffix(".md") }.count == 1 + SubtaskLimit.children)
    }

    @Test func createdPerProcess() throws {
        let b = try Box()
        let s = b.make(max: 2)
        #expect(try b.call("create_task", ["title": "1"], on: s).error == nil)
        #expect(try b.call("create_task", ["title": "1"], on: s).error == "invalid") // a twin is not counted
        #expect(try b.call("create_task", ["title": "2"], on: s).error == nil)
        #expect(try b.call("create_task", ["title": "3"], on: s).message.contains("лимит"))
    }

    @Test func limitsAndControlCharacters() throws {
        let b = try Box()
        for i in 0..<3 { try b.put("20261102-10000\(i)-s.md", body: "a\u{1B}[31mb") }
        let l = try b.call("list_tasks", ["limit": 2]).out
        #expect((l["tasks"] as? [Any])?.count == 2 && l["total"] as? Int == 3 && l["truncated"] as? Bool == true)
        let t = try b.call("show_task", ["task": "20261102-100000-s.md"]).out["task"] as? [String: Any]
        #expect(t?["body"] as? String == "a[31mb")
    }

    @Test func queue() throws {
        let b = try Box()
        try b.put(a)
        #expect(try b.call("queue_list").error == "unavailable")
        let job = QueueJob(id: "abcdef12", kind: "runTask", state: "running", title: "t", project: "proj", projectPath: b.project.path)
        b.reply = { $0.op == .log ? QueueResponse(jobs: [job], log: [String(repeating: "x", count: 70_000), "конец"]) : QueueResponse(jobs: [job]) }
        #expect((try b.call("queue_list", ["project": "proj"]).out["jobs"] as? [Any])?.count == 1)
        #expect(try b.call("queue_add", ["tasks": ["alpha"], "with_deps": true]).error == nil)
        #expect(b.sent.last?.op == .add && b.sent.last?.tasks == [a] && b.sent.last?.withDeps == true)
        let log = try b.call("queue_log", ["job": "abcdef12", "tail": 10]).out
        #expect(log["log"] as? [String] == ["конец"] && log["truncated"] as? Bool == true)
        #expect(try b.call("queue_log", ["job": "x", "tail": 500]).error == "usage")
    }

    @Test func queueOutside() throws {
        let b = try Box()
        let mine = QueueJob(id: "abcdef12", kind: "runTask", state: "running", title: "t", project: "proj", projectPath: b.project.path)
        let other = QueueJob(id: "abcdff34", kind: "runTask", state: "running", title: "секрет", project: "proj", projectPath: b.outside.path)
        b.reply = { r in
            guard r.op == .log else { return QueueResponse(jobs: [mine, other]) }
            return QueueResponse(jobs: [try QueueJob.find(r.job ?? "", in: [mine, other])], log: ["строка"])
        }
        let l = try b.call("queue_list", ["all": true]).out
        #expect((l["jobs"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == [mine.id])
        #expect(l["total"] as? Int == 1)
        b.sent = []
        let r = try b.call("queue_log", ["job": other.id])
        #expect(r.error == "not_found" && r.out["log"] == nil && b.sent.map(\.op) == [.list])
        // The prefix fits both jobs; only the visible one counts.
        #expect(try b.call("queue_log", ["job": "abcd"]).out["log"] as? [String] == ["строка"])
        #expect(b.sent.last?.job == mine.id)
        // A response with another job, or without one.
        for jobs in [[other], []] {
            b.reply = { $0.op == .log ? QueueResponse(jobs: jobs, log: ["секрет"]) : QueueResponse(jobs: [mine]) }
            let r = try b.call("queue_log", ["job": mine.id])
            #expect(r.error == "not_found" && r.out["log"] == nil)
        }
    }

    @Test func longTask() throws {
        let b = try Box()
        let long = String(repeating: "x", count: 40_000)
        try b.put(a, body: """
            текст

            - [ ] один \(long)
            - [x] два \(long)

            ## Критерии готовности
            - [ ] \(String(repeating: "y", count: 70_000))

            ## Заметки
            - 01.11 10:00 — старая \(long)
            - 02.11 10:00 — новая \(long)
            """)
        let out = try b.call("show_task", ["task": a]).out
        let t = try #require(out["task"] as? [String: Any])
        #expect(out["truncated"] as? Bool == true)
        #expect((t["items"] as? [[String: Any]])?.compactMap { $0["n"] as? Int } == [1])
        let criteria = try #require(t["criteriaItems"] as? [[String: Any]])
        #expect(criteria.count == 1 && (criteria[0]["text"] as? String)?.utf8.count == MCPTools.maxText)
        let notes = try #require(t["notes"] as? [String])
        #expect(notes.count == 1 && notes[0].contains("новая"))
        try b.put("20261102-100000-s.md", body: "текст\n\n- [ ] пункт\n\n## Заметки\n- 01.11 10:00 — x")
        let proven = "20261102-110000-e.md"
        try b.put(proven, body: "## Критерии готовности\n- [x] один\n  - Доказательство: \(String(repeating: "z", count: 70_000))\n- [x] два\n  - Доказательство: B")
        let e = try b.call("show_task", ["task": proven]).out
        let ev = try #require((e["task"] as? [String: Any])?["criteriaItems"] as? [[String: Any]])
        #expect(e["truncated"] as? Bool == true && ev.map { $0["text"] as? String } == ["один", "два"])
        #expect(ev.reduce(0) { $0 + ($1["text"] as! String).utf8.count + ($1["evidence"] as! String).utf8.count } <= MCPTools.maxText)
        let short = try b.call("show_task", ["task": "20261102-100000-s.md"]).out
        #expect(short["truncated"] == nil)
        #expect(((short["task"] as? [String: Any])?["notes"] as? [String])?.count == 1)
    }
}
