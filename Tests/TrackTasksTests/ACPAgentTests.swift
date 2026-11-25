import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// The adapter with a stand-in script instead of an agent, and the queue's rules for it.
@MainActor @Suite(.serialized) struct ACPAgentTests {
    let dir: URL, wt: URL, out: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-acpa-\(UUID().uuidString)")
        wt = dir.appendingPathComponent("wt")
        out = dir.appendingPathComponent("out")
        for d in [wt, out] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "секрет".write(to: out.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
    }

    private final class Seen {
        var started = false, asked: [AgentPermission] = [], features: ACPFeatures?, events: [AgentEvent] = []
    }

    /// `got.txt` next to the worktree gets every line the agent reads with `r`.
    private func script(_ body: String) throws -> ACPCommand {
        let f = dir.appendingPathComponent("agent")
        let head = """
        #!/bin/sh
        r() { IFS= read -r l; printf '%s\\n' "$l" >> '\(dir.path)/got.txt'; }
        w() { printf '%s\\n' "$1"; }

        """
        try (head + body).write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        return ACPCommand(command: f.path)
    }

    private func run(_ body: String, allow: Bool? = true, stopWhen: ((ACPAgentTests) -> Bool)? = nil, seen: Seen = Seen(), timeout: TimeInterval = 60,
                     prompt: String = "go") async throws -> AgentRunResult {
        let p = ACPProcess(startTimeout: timeout)
        var result: AgentRunResult?
        p.onExit = { result = $0 }
        p.onTurnStarted = { seen.started = true }
        p.onFeatures = { seen.features = $0 }
        p.onEvent = { seen.events.append($0) }
        if let allow {
            p.onPermission = { [weak p] r in
                seen.asked.append(r)
                p?.respond(r, allow: allow, always: false)
            }
        }
        try p.start(AgentRequest(cwd: wt, prompt: prompt, access: .coding, acp: try script(body)))
        if let stopWhen {
            for _ in 0..<3000 where result == nil && !stopWhen(self) { try await Task.sleep(for: .milliseconds(20)) }
            p.stop()
        }
        for _ in 0..<3000 where result == nil { try await Task.sleep(for: .milliseconds(20)) }
        return try #require(result)
    }

    private func start(_ caps: String = "{}", version: Int = 1) -> String {
        """
        r; w '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":\(version),"agentCapabilities":\(caps),"agentInfo":{"name":"fake","version":"1"}}}'
        r; w '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}'
        r

        """
    }
    private let end = """

    w '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ok"}}}}'
    w '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
    cat >/dev/null
    """
    private func call(_ id: Int, _ method: String, _ params: String) -> String {
        "w '{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":{\"sessionId\":\"s1\",\(params)}}'; r\n"
    }
    private var got: [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("got.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    private func file(_ name: String) -> String? { try? String(contentsOf: wt.appendingPathComponent(name), encoding: .utf8) }

    @Test func editsCode() async throws {
        let seen = Seen()
        let r = try await run(start(#"{"loadSession":true}"#) + call(10, "fs/write_text_file", "\"path\":\"\(wt.path)/a/b.txt\",\"content\":\"new\"") + end,
                              seen: seen, prompt: String(repeating: "ы", count: 200_000))
        #expect(!r.failed && r.gotResult && r.resultText == "ok" && r.sessionID == "s1")
        #expect(seen.started && seen.features == [.load] && file("a/b.txt") == "new" && seen.asked.isEmpty)
        #expect(got.last?.contains("\"result\":{}") == true)
    }

    @Test func outsideFilesAreRefused() async throws {
        try FileManager.default.createSymbolicLink(at: wt.appendingPathComponent("link"), withDestinationURL: out)
        let seen = Seen()
        let r = try await run(start() + call(10, "fs/read_text_file", "\"path\":\"\(out.path)/s.txt\"") + call(11, "fs/read_text_file", "\"path\":\"\(wt.path)/link/s.txt\"")
            + call(12, "fs/write_text_file", "\"path\":\"\(wt.path)/link/new.txt\",\"content\":\"x\"")
            + call(13, "terminal/create", "\"command\":\"ls\",\"cwd\":\"\(wt.path)/link\"") + end, seen: seen)
        #expect(!r.failed && seen.asked.isEmpty)
        #expect(got.suffix(4).allSatisfy { $0.contains("-32602") } && !got.joined().contains("секрет"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["s.txt"])
        #expect(seen.events.filter { if case .tool(let t) = $0 { t.hasPrefix("Отклонено") } else { false } }.count == 4)
    }

    private let ask = "\"toolCall\":{\"toolCallId\":\"t\",\"title\":\"Delete\"},\"options\":[{\"optionId\":\"yes\",\"name\":\"y\",\"kind\":\"allow_once\"},{\"optionId\":\"no\",\"name\":\"n\",\"kind\":\"reject_once\"}]"

    @Test(arguments: [true, false, nil]) func permission(allow: Bool?) async throws {
        let seen = Seen()
        let r = try await run(start() + call(10, "session/request_permission", ask) + end, allow: allow, seen: seen)
        #expect(!r.failed && seen.asked.count == (allow == nil ? 0 : 1))
        // Nobody to ask: denied.
        #expect(got.last?.contains(allow == true ? "\"yes\"" : "\"no\"") == true)
    }

    @Test func terminal() async throws {
        let body = start() + call(10, "terminal/create", "\"command\":\"echo hi > t.txt; echo out; exit 3\"") + """
        id=$(printf '%s' "$l" | sed 's/.*"terminalId":"\\([^"]*\\)".*/\\1/')

        """ + """
        w "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":11,\\"method\\":\\"terminal/wait_for_exit\\",\\"params\\":{\\"sessionId\\":\\"s1\\",\\"terminalId\\":\\"$id\\"}}"; r
        w "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":12,\\"method\\":\\"terminal/output\\",\\"params\\":{\\"sessionId\\":\\"s1\\",\\"terminalId\\":\\"$id\\"}}"; r

        """ + call(13, "terminal/output", "\"terminalId\":\"nope\"") + end
        let seen = Seen()
        let r = try await run(body, seen: seen)
        #expect(!r.failed && seen.asked.map(\.title) == ["echo hi > t.txt; echo out; exit 3"])
        #expect(file("t.txt") == "hi\n")
        #expect(got.contains { $0.contains("\"exitCode\":3") } && got.contains { $0.contains("out\\n") && $0.contains("\"truncated\":false") } && got.last?.contains("-32002") == true)
    }

    @Test func deniedCommandDoesNotRun() async throws {
        let r = try await run(start() + call(10, "terminal/create", "\"command\":\"touch\",\"args\":[\"t.txt\"]") + end, allow: false)
        #expect(!r.failed && file("t.txt") == nil)
    }

    @Test func terminalDiesWithTheRun() async throws {
        let pid = dir.appendingPathComponent("pid").path
        let command = "(trap '' TERM; echo $$ > '\(pid)'; while :; do sleep 1; done) & sleep 100".replacingOccurrences(of: "'", with: "'\\''")
        let seen = Seen()
        let r = try await run(start() + call(10, "terminal/create", "\"command\":\"\(command)\"") + "sleep 1" + end, seen: seen)
        #expect(!r.failed && seen.asked.count == 1)
        let id = try #require(pid_t((try String(contentsOfFile: pid, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!ProcessTree.snapshot().contains { $0.session == id })
    }

    @Test func outputIsLimited() async throws {
        let t = try ACPTerminal(.init(command: "printf", args: ["%s", "ыыыы"], env: [:], cwd: wt.path, limit: 3))
        for _ in 0..<3000 where t.exitStatus.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(t.output["output"] as? String == "ы" && t.output["truncated"] as? Bool == true && t.exitStatus["exitCode"] as? Int == 0)
    }

    @Test func cancel() async throws {
        let polite = try await run(start() + call(10, "x/unknown", "\"a\":1") + """
        r; w '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"cancelled"}}'
        cat >/dev/null
        """, stopWhen: { $0.got.last?.contains("-32601") == true })
        #expect(polite.stopped && !polite.failed)
        #expect(got.contains { $0.contains("-32601") } && got.last?.contains("session\\/cancel") == true)
        let deaf = try await run(start() + "trap '' TERM; echo deaf >> '\(dir.path)/got.txt'; while :; do sleep 1; done", stopWhen: { $0.got.last == "deaf" })
        #expect(deaf.stopped && !deaf.failed)
    }

    @Test func brokenOff() async throws {
        let seen = Seen()
        var r = try await run("echo hello; echo oops >&2; exit 3", seen: seen)
        #expect(r.failed && r.cannotStart && r.errorText.contains("oops") && !seen.started)
        r = try await run(start() + "w 'не json'; exit 1")
        #expect(r.failed && !r.cannotStart && r.errorText.contains("оборвался"))
        r = try await run("sleep 100", timeout: 0.5)
        #expect(r.failed && r.cannotStart && r.errorText.contains("не отвечает"))
    }

    @Test func refusals() async throws {
        var r = try await run(start(version: 2))
        #expect(r.failed && r.cannotStart && r.errorText.contains("версия протокола ACP 2"))
        r = try await run("""
        r; w '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        r; w '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"auth"}}'
        cat >/dev/null
        """)
        #expect(r.cannotStart && r.errorText.contains("вход не выполнен"))
        for c in [nil, ACPCommand(command: "/no/such/agent"), ACPCommand(command: "no-such-agent-\(UUID().uuidString)"), ACPCommand(command: "./x")] {
            #expect(throws: ACPError.self) { try ACPProcess().start(AgentRequest(cwd: wt, prompt: "", access: .coding, acp: c)) }
        }
        #expect(ACPLocator.folders(["PATH": ".:bin:/usr/bin"]).allSatisfy { $0.hasPrefix("/") })
    }

    @Test func check() async throws {
        let p = ACPProcess()
        var result: AgentRunResult?
        p.onExit = { result = $0 }
        try p.check(try script(start()))
        for _ in 0..<3000 where result == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(result?.resultText == "fake 1, ACP v1" && got.filter { !$0.isEmpty }.count == 1)
    }

    // MARK: Queue

    private let command = ACPCommand(command: "/bin/agent", args: ["--acp"])

    private func queue(_ agents: [any Agent], danger: DangerMode = DangerMode()) -> JobQueue {
        let q = JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry(agents),
                         profiles: { [command] in AgentProfiles(custom: [AgentProfile(id: "my", title: "My", agent: .acp, acp: command)]) },
                         dangerMode: { danger }, recordSpend: { _, _, _, _ in })
        // Another suite pauses its queue through the same UserDefaults at this time.
        q.paused = false
        return q
    }
    private func job(_ kind: Job.Kind = .runTask, worktree: Bool = true) -> Job {
        let j = Job(kind: kind, title: "Задача", projectID: nil, projectName: "p", cwd: dir, prompt: "x", systemPrompt: "")
        j.profile = "my"
        if worktree { j.worktree = .init(path: wt, main: dir, branch: "tracktasks/x") }
        return j
    }
    private func git() {
        for a in [["init", "-q", "-b", "tracktasks/x"], ["config", "user.name", "t"], ["config", "user.email", "t@t"], ["config", "commit.gpgsign", "false"],
                  ["commit", "-q", "--allow-empty", "-m", "base"]] { #expect(Worktrees.git(a, in: wt).ok) }
    }
    private func fake() -> FakeAgent { FakeAgent("acp", ACPAgent().capabilities) }
    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<3000 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(done())
    }

    @Test func unannouncedIsHidden() {
        let q = queue([ACPAgent()]), j = job()
        j.agent = .acp
        j.sessionID = "s1"
        j.state = .done
        for f in [nil, ACPFeatures.systemPrompt] {
            j.acpFeatures = f
            #expect(q.capabilities(j) == [.requiresWorktree])
            #expect(q.replyBlocked(j)?.contains("не продолжает сессии") == true && q.forkBlocked(j)?.contains("не умеет") == true)
        }
        for f in [ACPFeatures.resume, .load] {
            j.acpFeatures = f
            #expect(q.capabilities(j) == [.requiresWorktree, .resume] && q.replyBlocked(j) == nil && q.forkBlocked(j) != nil)
        }
        j.acp = command
        let r = Job(j.record)
        #expect(r.acp == command && r.acpFeatures == .load && r.agent == .acp)
        let child = job()
        child.useAgent(of: j)
        #expect(child.acp == command && child.acpFeatures == .load)
    }

    @Test func neverClaudeInstead() async throws {
        let claude = FakeAgent("claude")
        let q = queue([claude]), j = job(worktree: false)
        q.add(j)
        try await wait { j.state != .pending }
        #expect(j.state == .failed && j.lastLine.contains("«acp» не поддерживается") && claude.runs.isEmpty)
        let gone = job(worktree: false)
        gone.profile = "deleted"
        q.add(gone)
        try await wait { gone.state != .pending }
        #expect(gone.state == .failed && gone.lastLine.contains("не найден") && claude.runs.isEmpty)
        // A start problem is the job's failure too.
        let a = fake(), q2 = queue([claude, a]), j2 = job()
        git()
        a.startError = ACPError.notFound("x")
        q2.add(j2)
        try await wait { j2.state == .failed }
        #expect(claude.runs.isEmpty && j2.lastLine.contains("Не найдена программа"))
    }

    @Test func commandIsFixedAtTheStart() async throws {
        git()
        let a = fake(), q = queue([a]), j = job()
        q.add(j)
        try await wait { a.runs.first?.request != nil }
        #expect(a.runs[0].request?.acp == command && j.acp == command && a.runs[0].request?.bypassPermissions == false)
        a.runs[0].finish { $0.stopped = true }
    }

    /// A handover that never began gives the program back too; between two programs it is another agent.
    @Test func handover() async throws {
        git()
        // Checkpoints need a linked worktree.
        let linked = dir.appendingPathComponent("linked")
        #expect(Worktrees.git(["worktree", "add", "-q", "-b", "tracktasks/y", linked.path], in: wt).ok)
        let a = fake(), claude = FakeAgent("claude", [.resume]), q = queue([claude, a])
        let j = Job(kind: .runTask, title: "Задача", projectID: nil, projectName: "p", cwd: wt, prompt: "x", systemPrompt: "")
        j.profile = "old"
        j.worktree = .init(path: linked, main: wt, branch: "tracktasks/y")
        j.agent = .acp
        j.acp = ACPCommand(command: "/bin/other")
        j.acpFeatures = .resume
        j.sessionID = "s0"
        j.state = .failed
        j.setupDone = true
        j.baseCommit = Worktrees.git(["rev-parse", "HEAD"], in: wt).out.trimmingCharacters(in: .whitespacesAndNewlines)
        q.jobs.append(j)
        let to = try #require(q.profiles().resolve("my"))
        #expect(q.handoffRefusal(j, to: to) == nil)
        var bare = to
        bare.acp = nil
        #expect(q.handoffRefusal(j, to: bare)?.contains("не задана команда") == true)
        let draft = try await q.prepareHandoff(j).get()
        #expect(await q.handOff(j, draft, to: "my") == nil)
        try await wait { a.runs.first?.request != nil }
        #expect(a.runs[0].request?.acp == command && a.runs[0].request?.resume == nil && j.acpFeatures == nil)
        #expect(Job(j.record).handoffs == j.handoffs)
        a.runs[0].finish(session: nil) { $0.isError = true; $0.turns = 0; $0.gotResult = false; $0.resultText = "нет входа" }
        #expect(j.acp?.command == "/bin/other" && j.acpFeatures == .resume && j.sessionID == "s0" && claude.runs.isEmpty)
        // The same program: nothing to hand over.
        j.acp = command
        #expect(q.handoffRefusal(j, to: to)?.contains("уже у этого агента") == true)
    }

    @Test func onlyInAWorktree() async throws {
        let a = fake(), q = queue([a])
        let plan = job(worktree: false)
        plan.planPhase = .planning
        q.add(plan)
        try await wait { plan.state == .failed }
        #expect(plan.lastLine.contains("plan: false"))
        for kind in [Job.Kind.updateAbout, .quickAdd, .review] {
            let j = job(kind, worktree: false)
            q.add(j)
            try await wait { j.state == .failed }
            #expect(j.lastLine.contains("только в worktree"))
        }
        let main = job(worktree: false)
        main.mustUseMain = true
        q.add(main)
        try await wait { main.state == .failed }
        #expect(main.lastLine.contains("только в worktree") && a.runs.isEmpty)
        let done = job(.review, worktree: false)
        done.agent = .acp
        done.sessionID = "s"
        done.state = .done
        done.acpFeatures = .resume
        #expect(q.replyBlocked(done)?.contains("только в worktree") == true)
    }

    @Test func dangerModeDoesNotAnswer() async throws {
        git()
        var mode = DangerMode()
        let on = mode.enable(dir.path, name: "p", typed: "p", .hour, autopilot: false, verify: "", now: Date())
        #expect(on)
        let a = fake(), q = queue([a], danger: mode), j = job(.review)
        q.add(j)
        try await wait { a.runs.first?.request != nil }
        let run = a.runs[0]
        run.onPermission?(AgentPermission(id: "1", tool: "Bash", title: "rm"))
        #expect(run.answers.isEmpty && j.permissions.count == 1 && run.request?.bypassPermissions == false)
        run.finish { $0.stopped = true }
    }

    @Test(arguments: [true, false]) func reviewMustNotChangeCode(changes: Bool) async throws {
        git()
        let a = fake(), q = queue([a]), task = job(), review = job(.review)
        task.agent = .acp
        task.acp = command
        task.state = .done
        q.jobs.append(task)
        review.parentID = task.id
        review.useAgent(of: task)
        q.add(review)
        try await wait { a.runs.first?.request != nil }
        if changes { try "x".write(to: wt.appendingPathComponent("evil.txt"), atomically: true, encoding: .utf8) }
        a.runs[0].finish { $0.resultText = "ВЕРДИКТ: ОК" }
        try await wait { !review.isActive }
        #expect(review.state == (changes ? .failed : .done) && task.verdict == (changes ? nil : .ok))
    }
}
