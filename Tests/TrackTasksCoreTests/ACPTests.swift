import Foundation
import Testing
@testable import TrackTasksCore

private typealias R = ACPRecordings

private struct ACPDriver {
    var s: ACPSession
    var sent: [[String: Any]] = []
    var events: [AgentEvent] = []
    var asked: [AgentPermission] = []
    var work: [String] = []
    var features: ACPFeatures?
    var finished = false

    init(_ r: AgentRequest?) { s = ACPSession(r, program: "fake", runID: "r") }

    mutating func feed(_ lines: String...) { lines.forEach { take(s.consume(Data(($0 + "\n").utf8))) } }
    mutating func take(_ actions: [ACPSession.Action]) {
        for a in actions {
            switch a {
            case .send(let o): sent.append(o)
            case .event(let e): events.append(e)
            case .permission(let p): asked.append(p)
            case .features(let f): features = f
            case .read(let k, let p, _, _): work.append("read \(k) \(p)")
            case .write(let k, let p, _): work.append("write \(k) \(p)")
            case .terminal(let k, let t): work.append("terminal \(k) \(t)")
            case .finished: finished = true
            }
        }
    }
    func params(_ method: String) -> [String: Any]? { sent.last { $0["method"] as? String == method }?["params"] as? [String: Any] }
    func answers(_ id: Int) -> [[String: Any]] { sent.filter { $0["method"] == nil && $0["id"] as? Int == id } }
    func outcome(_ id: Int) -> [String: String]? {
        (answers(id).last?["result"] as? [String: Any])?["outcome"] as? [String: String]
    }
    func errorCode(_ id: Int) -> Int? { (answers(id).last?["error"] as? [String: Any])?["code"] as? Int }
    var lastEvent: String { if case .tool(let t)? = events.last { t } else { "" } }

    static func request(_ access: AgentAccess = .coding, resume: String? = nil, model: String = "") -> AgentRequest {
        AgentRequest(cwd: URL(fileURLWithPath: "/private/tmp"), prompt: "go", systemPrompt: "sys", model: model, access: access,
                     resume: resume, addDirs: [URL(fileURLWithPath: "/main/tasks")])
    }
    static func running(_ caps: String = "{}", access: AgentAccess = .coding) -> ACPDriver {
        var d = ACPDriver(request(access))
        d.feed(R.initialize(caps), R.session)
        return d
    }
}

@Suite struct ACPProtocolTests {
    @Test func wholeTurn() {
        var d = ACPDriver.running()
        #expect(d.s.begin()["jsonrpc"] as? String == "2.0" && d.params("session/new")?["cwd"] as? String == "/private/tmp")
        #expect(d.s.promptSent && !d.s.turnStarted)
        // Not announced: in the text, not in fields.
        #expect(d.params("session/new")?["systemPrompt"] == nil && d.params("session/new")?["additionalDirectories"] == nil)
        let text = (d.params("session/prompt")?["prompt"] as? [[String: Any]])?.first?["text"] as? String
        #expect(text == "sys\n\ngo")
        d.feed(R.text("при"), R.text("вет"), R.tool("t1", "Edit a"), R.tool("t1", "Edit a"), R.text("го"), R.text("тово"), R.cost("0.25"), R.end())
        #expect(d.s.turnStarted && d.finished)
        #expect(d.events.suffix(3) == [.text("привет"), .tool("Edit a"), .text("готово")])
        let r = d.s.result
        #expect(r.gotResult && !r.failed && r.resultText == "готово" && r.sessionID == "s1" && r.turns == 3 && r.costUSD == 0.25 && r.limit == nil)
    }

    @Test func turnInPieces() {
        var d = ACPDriver.running()
        let bytes = Array([R.text("ы"), R.end()].joined(separator: "\n").utf8) + [0x0A]
        for b in bytes { d.take(d.s.consume(Data([b]))) }
        #expect(d.s.result.resultText == "ы" && d.finished)
    }

    @Test func announcedFeaturesAreUsed() {
        var d = ACPDriver.running(R.full)
        #expect(d.features == [.resume, .load, .systemPrompt, .additionalDirectories])
        let p = d.params("session/new")
        #expect((p?["systemPrompt"] as? [String: Any])?["mode"] as? String == "append")
        #expect(p?["additionalDirectories"] as? [String] == ["/main/tasks"])
        #expect((d.params("session/prompt")?["prompt"] as? [[String: Any]])?.first?["text"] as? String == "go")
        d.feed(R.end())
        #expect(d.s.result.gotResult && d.s.result.turns == 1)
        #expect(ACPFeatures([:]) == [] && ACPFeatures(["loadSession": true]) == [.load])
        #expect(ACPFeatures(["sessionCapabilities": ["resume": NSNull()]]) == [])
    }

    @Test(arguments: ["2", "0", "true", "\"1\"", "null"]) func otherVersionIsRefused(v: String) {
        var d = ACPDriver(ACPDriver.request())
        d.feed(R.initialize(version: v))
        #expect(d.finished && d.s.result.cannotStart && d.s.result.failed && d.params("session/new") == nil)
        #expect(d.s.result.errorText.contains("версия протокола ACP") && d.s.result.errorText.contains("нужна 1"))
        if v == "2" { #expect(d.s.result.errorText.contains("ACP 2")) }
    }

    @Test func check() {
        var d = ACPDriver(nil)
        let caps = d.s.begin()["params"] as? [String: Any]
        #expect((caps?["clientCapabilities"] as? [String: Any])?["terminal"] as? Bool == false)
        d.feed(R.initialize(R.full))
        #expect(d.finished && d.s.result.gotResult && d.s.result.resultText.hasPrefix("Fake 1.2, ACP v1: продолжение сессии") && d.sent.isEmpty)
    }

    @Test func unknownMessages() {
        var d = ACPDriver.running()
        d.feed("мусор", "{}", "[1]", #"{"jsonrpc":"2.0","id":99,"result":{}}"#, #"{"jsonrpc":"2.0","method":"x/y"}"#,
               R.update(#"{"sessionUpdate":"brand_new"}"#), #"{"jsonrpc":"2.0","id":50,"method":"elicitation/create","params":{}}"#, R.text("чужое", session: "s2"))
        #expect(!d.finished && d.errorCode(50) == -32601 && !d.s.turnStarted)
        // An answer to a request that wasn't sent.
        #expect(d.s.result.turns == 0)
        d.feed(R.end())
        #expect(d.s.result.gotResult && d.s.result.resultText.isEmpty)
    }

    @Test func stopReasons() {
        for r in ["refusal", "max_tokens", "max_turn_requests", "cancelled", "new_reason"] {
            var d = ACPDriver.running()
            d.feed(R.end(r))
            #expect(d.s.result.failed && d.s.result.turns == 1 && !d.s.result.cannotStart && d.s.result.limit == nil, "\(r)")
        }
    }

    @Test func loginAndErrors() {
        for step in 1...2 {
            var d = ACPDriver(ACPDriver.request())
            if step == 2 { d.feed(R.initialize()) }
            d.feed(R.error(step, -32000))
            #expect(d.s.result.cannotStart && d.s.result.errorText.contains("вход не выполнен"))
        }
        var d = ACPDriver.running()
        d.feed(R.error(4, -32000))
        #expect(d.s.result.cannotStart && d.s.result.errorText.contains("вход"))
        d = ACPDriver.running()
        d.feed(R.error(4, -32603, "нет сети"))
        #expect(d.s.result.failed && !d.s.result.cannotStart && d.s.result.errorText.contains("нет сети"))
    }

    @Test func resumeAndLoad() {
        var d = ACPDriver(ACPDriver.request(resume: "s1"))
        d.feed(R.initialize(R.full))
        #expect(d.params("session/resume")?["sessionId"] as? String == "s1" && d.params("session/new") == nil)
        d.feed(#"{"jsonrpc":"2.0","id":2,"result":{}}"#, R.cost("3"), R.text("да"), R.end())
        // The cost is for the whole session: what this turn cost isn't known.
        #expect(d.s.result.gotResult && d.s.result.costUSD == nil && d.s.result.sessionID == "s1")

        d = ACPDriver(ACPDriver.request(resume: "s1"))
        d.feed(R.initialize(#"{"loadSession":true}"#), R.text("старое"), R.tool("t", "старое"))
        #expect(d.params("session/load") != nil && d.events.count == 1 && d.s.result.turns == 0 && !d.s.turnStarted)
        d.feed(#"{"jsonrpc":"2.0","id":2,"result":null}"#, R.text("новое"), R.end())
        #expect(d.s.result.resultText == "новое")

        // The queue may start a new session.
        d = ACPDriver(ACPDriver.request(resume: "s1"))
        d.feed(R.initialize(R.full), R.error(2, -32002))
        #expect(d.s.result.failed && !d.s.result.cannotStart && d.s.result.turns == 0)
        d = ACPDriver(ACPDriver.request(resume: "s1"))
        d.feed(R.initialize())
        #expect(d.s.result.failed && !d.s.result.cannotStart && d.s.result.errorText.contains("не продолжает"))
    }

    @Test func model() {
        func session(_ current: String, _ id: Int = 2) -> String {
            #"{"jsonrpc":"2.0","id":\#(id),"result":{"sessionId":"s1","configOptions":[{"id":"m","name":"M","category":"model","type":"select","currentValue":"\#(current)","options":[{"group":"g","name":"G","options":[{"value":"big","name":"B"}]},{"value":"small","name":"S"}]}]}}"#
        }
        var d = ACPDriver(ACPDriver.request(model: "big"))
        d.feed(R.initialize(), session("small"))
        #expect(d.params("session/set_config_option")?["value"] as? String == "big" && !d.s.promptSent)
        d.feed(session("big", 3))
        #expect(d.s.promptSent && d.s.result.model == "big")
        // Not taken, not there, can't be chosen: never another model silently.
        d = ACPDriver(ACPDriver.request(model: "big"))
        d.feed(R.initialize(), session("small"), session("small", 3))
        #expect(d.s.result.cannotStart)
        d = ACPDriver(ACPDriver.request(model: "huge"))
        d.feed(R.initialize(), session("small"))
        #expect(d.s.result.cannotStart && d.s.result.errorText.contains("big, small"))
        d = ACPDriver(ACPDriver.request(model: "big"))
        d.feed(R.initialize(), R.session)
        #expect(d.s.result.cannotStart)
    }

    @Test func permission() {
        for allow in [true, false] {
            var d = ACPDriver.running()
            d.feed(R.ask())
            #expect(d.asked[0].title == "Run tests" && d.asked[0].note.contains("npm test") && d.asked[0].ruleText.isEmpty)
            #expect(d.answers(7).isEmpty)
            d.take(d.s.respond(d.asked[0].id, allow: allow))
            #expect(d.outcome(7) == ["outcome": "selected", "optionId": allow ? "a" : "r"])
            d.take(d.s.respond(d.asked[0].id, allow: true))
            #expect(d.answers(7).count == 1)
        }
        var d = ACPDriver.running()
        d.feed(R.ask(options: #"[{"optionId":"w","name":"Always","kind":"allow_always"}]"#))
        #expect(d.asked.isEmpty && d.outcome(7) == ["outcome": "cancelled"] && d.lastEvent.contains("Отклонено"))
        d.feed(R.ask("8", options: #"[{"optionId":"a","name":"Yes","kind":"allow_once"}]"#))
        d.take(d.s.respond(d.asked[0].id, allow: false))
        #expect(d.outcome(8) == ["outcome": "cancelled"])
    }

    @Test func cancel() {
        var d = ACPDriver.running()
        #expect(d.s.interrupt() != nil)
        var e = ACPDriver(ACPDriver.request())
        e.feed(R.initialize())
        #expect(e.s.interrupt() == nil && e.s.exited(code: 9).stopped)

        d = ACPDriver.running()
        d.feed(R.ask(), R.call("8", "fs/read_text_file", #""path":"/private/tmp/a""#), R.call("9", "terminal/create", #""command":"ls""#))
        d.take(d.s.interrupt() ?? [])
        #expect(d.params("session/cancel")?["sessionId"] as? String == "s1")
        #expect(d.outcome(7) == ["outcome": "cancelled"] && d.errorCode(8) == -32800 && d.errorCode(9) == -32800)
        // Late answers of the person and of the disk, and new requests.
        for p in d.asked { d.take(d.s.respond(p.id, allow: true)) }
        d.take(d.s.reply("n8", ["content": ""]))
        #expect((7...9).allSatisfy { d.answers($0).count == 1 } && d.work.count == 1)
        d.feed(R.call("10", "fs/write_text_file", #""path":"/private/tmp/a","content":"x""#), R.ask("11"))
        #expect(d.errorCode(10) == -32800 && d.outcome(11) == ["outcome": "cancelled"] && d.work.count == 1)
        d.feed(R.end("cancelled"))
        #expect(d.finished && d.s.exited(code: 0).stopped && !d.s.result.failed)
        // Some answer with an error instead.
        d = ACPDriver.running()
        _ = d.s.interrupt()
        d.feed(R.error(4, -32603))
        #expect(d.s.result.stopped && !d.s.result.failed)
    }

    @Test func agentTakesItsRequestBack() {
        var d = ACPDriver.running()
        d.feed(R.ask(), #"{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":7}}"#)
        #expect(d.errorCode(7) == -32800)
        d.take(d.s.respond(d.asked[0].id, allow: true))
        #expect(d.answers(7).count == 1)
    }

    @Test func brokenOff() {
        var d = ACPDriver(ACPDriver.request())
        d.s.addStderr("bad flag")
        var r = d.s.exited(code: 2)
        #expect(r.failed && r.cannotStart && r.errorText.contains("bad flag"))
        // After the prompt it may have worked: never repeated in a new session.
        d = ACPDriver.running()
        r = d.s.exited(code: 1)
        #expect(r.failed && !r.cannotStart && r.turns == 1 && r.errorText.contains("оборвался"))
        d = ACPDriver(ACPDriver.request())
        d.s.startTimedOut()
        #expect(d.s.exited(code: 15).cannotStart)
    }

    @Test func foreignSessionAndReadOnly() {
        var d = ACPDriver.running()
        d.feed(R.call("1", "fs/read_text_file", #""path":"/private/tmp/a""#, session: "s2"), R.call("2", "terminal/create", #""command":"ls""#, session: "s2"))
        #expect(d.errorCode(1) == -32602 && d.errorCode(2) == -32602 && d.work.isEmpty && d.asked.isEmpty)
        d = ACPDriver.running(access: .answer)
        d.feed(R.call("1", "fs/read_text_file", #""path":"/private/tmp/a""#), R.ask())
        #expect(d.errorCode(1) == -32602 && d.errorCode(7) == -32602 && d.asked.isEmpty)
        // The same id as a string is another request.
        d = ACPDriver.running()
        d.feed(R.call("1", "fs/read_text_file", #""path":"/private/tmp/a""#), R.call("\"1\"", "fs/read_text_file", #""path":"/private/tmp/b""#))
        #expect(d.work == ["read n1 /private/tmp/a", "read s1 /private/tmp/b"])
        d.take(d.s.reply("s1", ["content": "b"]))
        #expect(d.sent.last?["id"] as? String == "1")
    }

    @Test func terminalAsksForEveryCommand() {
        var d = ACPDriver.running()
        d.feed(R.call("1", "terminal/create", #""command":"npm","args":["run","a b"],"env":[{"name":"X","value":"1"}]"#))
        #expect(d.asked[0].title == "npm run 'a b'" && d.asked[0].note.contains("X=1") && d.asked[0].note.contains("где угодно") && d.work.isEmpty)
        d.take(d.s.respond(d.asked[0].id, allow: true))
        #expect(d.work.count == 1 && d.answers(1).isEmpty)
        d.take(d.s.reply("n1", ["terminalId": "t"]))
        #expect(d.answers(1).count == 1)
        d.feed(R.call("2", "terminal/create", #""command":"ls""#))
        d.take(d.s.respond(d.asked[1].id, allow: false))
        #expect(d.errorCode(2) == -32602 && d.work.count == 1)
        for cwd in ["/", "/etc", "/private/tmp/../..", "relative"] {
            d.feed(R.call("3", "terminal/create", #""command":"ls","cwd":"\#(cwd)""#))
            #expect(d.errorCode(3) == -32602 && d.asked.count == 2)
        }
    }

    @Test func profiles() {
        var p = AgentProfiles()
        #expect(p.add(AgentProfile(id: "x", title: "x", agent: .acp)) != nil)
        for bad in ["", " ", "./agent", "bin/agent", "a\nb"] {
            #expect(p.add(AgentProfile(id: "x", title: "x", agent: .acp, acp: ACPCommand(command: bad))) != nil, "\(bad)")
        }
        #expect(p.add(AgentProfile(id: "x", title: "x", agent: .acp, acp: ACPCommand(command: "gemini", args: ["--acp"]))) == nil)
        // Never by default: about.md and quick tasks would go there.
        p.defaultID = "x"
        #expect(p.resolve("") == nil && p.resolve("x")?.acp?.args == ["--acp"])
        let old = #"{"id":"c","title":"c","agent":"codex","model":""}"#
        #expect((try? JSONDecoder().decode(AgentProfile.self, from: Data(old.utf8)))?.acp == nil)
    }
}
