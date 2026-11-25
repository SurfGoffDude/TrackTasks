import Foundation
import Testing
@testable import TrackTasksCore

/// Start-up lines are from codex 0.162.0-alpha.17.2 (cut down); the events of a turn are
/// written by that version's schema (recorded ones are in CodexRecordings).
private enum Lines {
    static let initialize = #"{"id":1,"result":{"userAgent":"tracktasks/0.162.0-alpha.17.2 (Mac OS 27.2.0; arm64) (tracktasks; 1)","codexHome":"/h","platformFamily":"unix","platformOs":"macos"}}"#
    static let noAccount = #"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true,"workspaceRouting":null}}"#
    static let account = #"{"id":2,"result":{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}}"#
    static let unknownMethod = #"{"error":{"code":-32600,"message":"Invalid request: unknown variant `account/read`"},"id":2}"#
    static let config = #"{"id":3,"result":{"config":{"model":null,"mcp_servers":{"my.srv":{"command":"/bin/sh"},"two":{"command":"x"}}}}}"#
    static func thread(_ sandbox: String = "workspaceWrite", approval: String = "untrusted") -> String {
        #"{"id":4,"result":{"thread":{"id":"th1","ephemeral":false},"model":"gpt-6.1-sol","approvalPolicy":"\#(approval)","approvalsReviewer":"user","sandbox":{"type":"\#(sandbox)","writableRoots":[],"networkAccess":false}}}"#
    }
    static let noThread = #"{"error":{"code":-32600,"message":"no rollout found for thread id 0"},"id":4}"#
    static let turn = #"{"id":5,"result":{"turn":{"id":"tu1","status":"inProgress","items":[],"error":null}}}"#
    static func item(_ phase: String, _ json: String) -> String {
        #"{"method":"item/\#(phase)","params":{"threadId":"th1","turnId":"tu1","item":\#(json)}}"#
    }
    static func done(_ status: String = "completed", error: String = "null") -> String {
        #"{"method":"turn/completed","params":{"threadId":"th1","turn":{"id":"tu1","items":[],"status":"\#(status)","error":\#(error),"durationMs":1500}}}"#
    }
    static func change(_ path: String, move: String = "null") -> String {
        item("started", #"{"type":"fileChange","id":"f1","status":"inProgress","changes":[{"path":"\#(path)","kind":{"type":"update","move_path":\#(move)},"diff":""}]}"#)
    }
    static func ask(_ method: String, _ extra: String = "") -> String {
        #"{"id":7,"method":"\#(method)","params":{"threadId":"th1","turnId":"tu1","itemId":"f1","startedAtMs":0\#(extra)}}"#
    }
}

/// Also for CodexRecordedTests.
struct Driver {
    var s: CodexSession
    var sent: [[String: Any]] = []
    var events: [AgentEvent] = []
    var asked: [AgentPermission] = []
    var finished = false

    init(_ r: AgentRequest?) { s = CodexSession(r, runID: "r") }

    mutating func feed(_ lines: String...) { lines.forEach { take(s.consume(Data(($0 + "\n").utf8))) } }
    mutating func take(_ actions: [CodexSession.Action]) {
        for a in actions {
            switch a {
            case .send(let o): sent.append(o)
            case .event(let e): events.append(e)
            case .permission(let p): asked.append(p)
            case .started: break
            case .finished: finished = true
            }
        }
    }
    func params(_ method: String) -> [String: Any]? {
        sent.last { $0["method"] as? String == method }?["params"] as? [String: Any]
    }
    var lastDecision: String? { (sent.last?["result"] as? [String: Any])?["decision"] as? String }

    fileprivate static func running(_ access: AgentAccess = .coding, cwd: String = "/p") -> Driver {
        var d = Driver(AgentRequest(cwd: URL(fileURLWithPath: cwd), prompt: "сделай", systemPrompt: "sys", access: access,
                                    addDirs: [URL(fileURLWithPath: "/main/tasks")]))
        d.feed(Lines.initialize, Lines.account, Lines.config, Lines.thread(access == .coding ? "workspaceWrite" : "readOnly"), Lines.turn)
        return d
    }
}

@Suite struct CodexProtocolTests {
    @Test func wholeTurn() {
        var d = Driver.running()
        #expect(d.params("thread/start")?["sandbox"] as? String == "workspace-write")
        #expect(d.params("thread/start")?["approvalPolicy"] as? String == "untrusted")
        #expect(d.params("thread/start")?["developerInstructions"] as? String == "sys")
        // The user's MCP servers are off, also with a dot in the name.
        let servers = (d.params("thread/start")?["config"] as? [String: Any])?["mcp_servers"] as? [String: [String: Bool]]
        #expect(servers == ["my.srv": ["enabled": false], "two": ["enabled": false]])
        let sandbox = d.params("turn/start")?["sandboxPolicy"] as? [String: Any]
        #expect(sandbox?["networkAccess"] as? Bool == false)
        #expect(sandbox?["writableRoots"] as? [String] == ["/p", "/main/tasks"])
        d.feed(Lines.item("started", #"{"type":"commandExecution","id":"c1","command":"ls"}"#),
               Lines.item("completed", #"{"type":"commandExecution","id":"c1","command":"ls","exitCode":0}"#),
               Lines.change("/p/a.swift"),
               Lines.item("completed", #"{"type":"agentMessage","id":"m1","text":"готово"}"#), Lines.done())
        #expect(d.events == [.tool("$ ls"), .tool("Правит a.swift"), .text("готово")])
        #expect(d.finished)
        // Killed after the turn: still a success.
        let r = d.s.exited(code: 15)
        #expect(!r.failed && !r.stopped && r.gotResult && r.turns == 3 && r.resultText == "готово")
        #expect(r.sessionID == "th1" && r.model == "gpt-6.1-sol" && r.costUSD == nil && r.durationMs == 1500)
    }

    @Test func usageIsOfThisTurnOnly() {
        var d = Driver.running()
        func usage(_ turn: String, _ total: (Int, Int, Int), _ last: (Int, Int, Int)) -> String {
            func b(_ t: (Int, Int, Int)) -> String {
                #"{"totalTokens":0,"inputTokens":\#(t.0),"cachedInputTokens":\#(t.1),"cacheWriteInputTokens":0,"outputTokens":\#(t.2),"reasoningOutputTokens":0}"#
            }
            return #"{"method":"thread/tokenUsage/updated","params":{"threadId":"th1","turnId":"\#(turn)","tokenUsage":{"total":\#(b(total)),"last":\#(b(last)),"modelContextWindow":null}}}"#
        }
        d.feed(usage("old", (1000, 0, 50), (1000, 0, 50)), usage("tu1", (1100, 60, 60), (100, 60, 10)),
               usage("tu1", (1300, 160, 80), (200, 100, 20)), usage("tu1", (1300, 160, 80), (200, 100, 20)))
        #expect(d.s.result.totalInput == 300)
        #expect(d.s.result.cacheReadTokens == 160)
        #expect(d.s.result.outputTokens == 30)
    }

    @Test func splitLinesAndGarbage() {
        var d = Driver(AgentRequest(cwd: URL(fileURLWithPath: "/p"), prompt: "привет", access: .coding))
        for b in Data(("not json\n{\"method\":\"new/thing\",\"params\":{}}\n" + Lines.initialize + "\n").utf8) { d.take(d.s.consume(Data([b]))) }
        #expect(d.sent.compactMap { $0["method"] as? String } == ["initialized", "account/read"])
    }

    @Test func resume() {
        var d = Driver(AgentRequest(cwd: URL(fileURLWithPath: "/p"), prompt: "x", access: .coding, resume: "th0"))
        d.feed(Lines.initialize, Lines.account, Lines.config)
        #expect(d.params("thread/resume")?["threadId"] as? String == "th0")
        d.feed(Lines.noThread)
        let r = d.s.exited(code: 0)
        // Not `cannotStart`: the queue may start a new session.
        #expect(d.finished && r.failed && r.turns == 0 && !r.cannotStart && r.errorText.contains("не найдена"))
    }

    @Test func noLogin() {
        var d = Driver.init(AgentRequest(cwd: URL(fileURLWithPath: "/p"), prompt: "x", access: .coding))
        d.feed(Lines.initialize, Lines.noAccount)
        let r = d.s.exited(code: 0)
        #expect(d.finished && r.failed && r.cannotStart && r.errorText == CodexSession.noLogin)
        #expect(d.params("thread/start") == nil)
    }

    @Test func oldVersion() {
        var d = Driver(nil)
        d.feed(Lines.initialize, Lines.unknownMethod)
        #expect(d.s.exited(code: 0).errorText.contains("обнови Codex"))
        var silent = CodexSession(nil)
        let r = silent.exited(code: 1)
        #expect(r.failed && r.cannotStart && r.errorText.contains("обнови Codex"))
    }

    @Test func check() {
        var d = Driver(nil)
        d.feed(Lines.initialize, Lines.account)
        #expect(d.finished && !d.s.exited(code: 0).failed)
        #expect(d.s.result.resultText == "codex 0.162.0-alpha.17.2, вход выполнен")
    }

    @Test(arguments: [Lines.thread("dangerFullAccess"), Lines.thread("readOnly"), Lines.thread(approval: "never")])
    func widerRightsStopTheRun(thread: String) {
        var d = Driver(AgentRequest(cwd: URL(fileURLWithPath: "/p"), prompt: "x", access: .coding, bypassPermissions: true))
        d.feed(Lines.initialize, Lines.account, Lines.config, thread)
        #expect(d.finished && d.s.result.cannotStart && d.params("turn/start") == nil)
    }

    @Test func turnErrors() {
        for (info, text) in [("\"usageLimitExceeded\"", "исчерпан лимит"), ("\"unauthorized\"", "codex login"),
                             (#"{"responseStreamDisconnected":{"httpStatusCode":null}}"#, "нет связи"), ("\"badRequest\"", "модель")] {
            var d = Driver.running()
            d.feed(Lines.done("failed", error: #"{"message":"m","codexErrorInfo":\#(info),"additionalDetails":null}"#))
            let r = d.s.exited(code: 0)
            #expect(r.failed && r.errorText.contains(text))
            #expect((r.limit != nil) == info.contains("usageLimit") && r.limit?.resetsAt == nil)
        }
    }

    /// Other limits are not the account's one; a text about limits isn't a limit.
    @Test(arguments: ["rateLimitExceeded", "sessionBudgetExceeded", "other"]) func notTheAccountLimit(kind: String) {
        var d = Driver.running()
        d.feed(Lines.done("failed", error: #"{"message":"usage limit reached","codexErrorInfo":"\#(kind)","additionalDetails":null}"#))
        let r = d.s.exited(code: 0)
        #expect(r.failed && r.limit == nil)
    }

    @Test func diedInTheMiddle() {
        var d = Driver.running()
        d.s.addStderr("boom")
        let r = d.s.exited(code: 0)
        #expect(r.failed && !r.cannotStart && r.errorText.contains("boom"))
    }

    @Test func stop() {
        var d = Driver.running()
        let m = d.s.interrupt()
        #expect((m?["params"] as? [String: String]) == ["threadId": "th1", "turnId": "tu1"])
        d.feed(Lines.done("interrupted"))
        let r = d.s.exited(code: 0)
        #expect(r.stopped && !r.failed)
        var early = CodexSession(AgentRequest(cwd: URL(fileURLWithPath: "/p"), prompt: "x", access: .coding))
        #expect(early.interrupt() == nil)
        #expect(early.exited(code: 15).stopped)
    }
}

@Suite struct CodexPermissionTests {
    private let cmd = "item/commandExecution/requestApproval", file = "item/fileChange/requestApproval"

    @Test func commandIsAsked() throws {
        for allow in [true, false] {
            var d = Driver.running()
            d.feed(Lines.ask(cmd, #","command":"npm i","reason":"сеть""#))
            let p = try #require(d.asked.first)
            #expect(p.title == "npm i" && p.ruleText.isEmpty && p.note.contains("вне песочницы") && p.id.contains("r"))
            d.take(d.s.respond(p.id, allow: allow))
            #expect(d.lastDecision == (allow ? "accept" : "decline"))
            #expect(d.sent.last?["id"] as? Int == 7)
            // Answered once.
            #expect(d.s.respond(p.id, allow: true).isEmpty)
        }
    }

    /// The schema allows both kinds of ids; recorded ones are numbers.
    @Test func textRequestID() throws {
        var d = Driver.running()
        d.feed(Lines.ask(cmd, #","command":"npm i""#).replacingOccurrences(of: #""id":7"#, with: #""id":"q-7""#))
        let p = try #require(d.asked.first)
        d.take(d.s.respond(p.id, allow: true))
        #expect(d.sent.last?["id"] as? String == "q-7" && d.lastDecision == "accept")
        d.feed(Lines.change("src/a.swift"), Lines.ask(file).replacingOccurrences(of: #""id":7"#, with: #""id":"q-8""#))
        #expect(d.sent.last?["id"] as? String == "q-8" && d.lastDecision == "accept")
    }

    @Test func edits() {
        var d = Driver.running()
        d.feed(Lines.change("src/a.swift"), Lines.ask(file))
        #expect(d.asked.isEmpty && d.lastDecision == "accept")
        for (path, extra) in [("/main/Sources/a.swift", ""), ("src/../../q/x", ""), (".git/config", ""), ("a", #","grantRoot":"/""#)] {
            var d = Driver.running()
            d.feed(Lines.change(path), Lines.ask(file, extra))
            #expect(d.asked.count == 1, "\(path)")
        }
        // Moved out of the worktree.
        var m = Driver.running()
        m.feed(Lines.change("a", move: "\"/other/a\""), Lines.ask(file))
        #expect(m.asked.count == 1)
        // Files aren't known.
        var u = Driver.running()
        u.feed(Lines.ask(file))
        #expect(u.asked.count == 1)
        var answer = Driver.running(.answer)
        answer.feed(Lines.change("a"), Lines.ask(file))
        #expect(answer.asked.isEmpty && answer.lastDecision == "decline")
        answer.feed(Lines.ask(cmd, #","command":"ls""#))
        #expect(answer.asked.isEmpty && answer.lastDecision == "decline")
    }

    @Test func otherRequestsAreRefused() {
        var d = Driver.running()
        d.feed(Lines.ask("item/permissions/requestApproval"))
        #expect(((d.sent.last?["result"] as? [String: Any])?["permissions"] as? [String: Any])?.isEmpty == true)
        d.feed(Lines.ask("mcpServer/elicitation/request"))
        #expect((d.sent.last?["result"] as? [String: Any])?["action"] as? String == "decline")
        d.feed(Lines.ask("some/new/request"))
        #expect(d.sent.last?["error"] != nil && d.asked.isEmpty)
    }

    @Test func planningEditsOnlyTrackerFiles() {
        let p = CodexPolicy(access: .planning, cwd: URL(fileURLWithPath: "/p"), addDirs: [URL(fileURLWithPath: "/main/tasks")])
        #expect(p.sandboxMode == "read-only")
        for ok in ["tasks/a.md", "about.md", "spectrack.md", "/main/tasks/b.md"] { #expect(p.edit([ok]) == .allow, "\(ok)") }
        for no in ["Sources/a.swift", "tasks/../a.swift", "/main/about.md", "/main/tasks/../x"] { #expect(p.edit([no]) == .ask, "\(no)") }
        #expect(p.edit(["tasks/a.md", "x"]) == .ask)
    }

    @Test func symlinkLeadsOutside() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let wt = dir.appendingPathComponent("wt"), out = dir.appendingPathComponent("out")
        try fm.createDirectory(at: wt, withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: wt.appendingPathComponent("link"), withDestinationURL: out)
        try fm.createSymbolicLink(at: wt.appendingPathComponent("dangling"), withDestinationURL: dir.appendingPathComponent("none"))
        let p = CodexPolicy(access: .coding, cwd: wt)
        #expect(p.edit(["new/a.swift"]) == .allow)
        #expect(p.edit([wt.path + "/a.swift"]) == .allow)
        for bad in ["link/a", "link/../x", "dangling", "../out/a"] { #expect(p.edit([bad]) == .ask, "\(bad)") }
    }
}
