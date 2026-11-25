import Foundation
import Testing
@testable import TrackTasksCore

private struct FakeEnv: CheckEnvironment {
    var tools: Set<CheckTool> = [.git, .claude, .codex, .gh]
    var hasTools = true
    var folderState = CheckFolder.ready
    var answers: [String: CheckOutput] = [
        "git --version": CheckOutput(ok: true, out: "git version 2.50.1 (Apple Git-155)\n"),
        "claude --version": CheckOutput(ok: true, out: "2.1.325 (Claude Code)\n"),
        "claude --help": CheckOutput(ok: true, out: goodHelp),
        "claude auth status --json": CheckOutput(ok: true, out: #"{"loggedIn": true, "email": "someone@example.com"}"#),
    ]
    var ghAnswer = CheckOutput(ok: true)
    var codexAnswer = CheckCodex.ok("codex 1, вход выполнен")
    let log = Log()

    static let goodHelp = "  -p, --print\n" + EnvironmentCheck.claudeFlags.map { "  \($0) <x>  text\n" }.joined() + "Commands:\n  auth      Manage\n"

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ s: String) { lock.withLock { all.append(s) } }
        var calls: [String] { lock.withLock { all } }
    }

    func prepare() { log.add("prepare") }
    func find(_ tool: CheckTool) -> String? { tools.contains(tool) ? "/x/\(tool.rawValue)" : nil }
    func folder(_ url: URL) -> CheckFolder { folderState }
    func developerTools() -> Bool { hasTools }
    func run(_ tool: CheckTool, _ args: [String]) -> CheckOutput {
        let key = ([tool.rawValue] + args).joined(separator: " ")
        log.add(key)
        return answers[key] ?? CheckOutput(ok: false)
    }
    func ghLogin() -> CheckOutput { log.add("gh"); return ghAnswer }
    func codex() async -> CheckCodex { log.add("codex"); return codexAnswer }

    func full() async -> [EnvironmentCheck.Item: EnvironmentCheck.Report] {
        let r = await EnvironmentCheck.full(self, root: URL(fileURLWithPath: "/p"))
        return Dictionary(uniqueKeysWithValues: r.map { ($0.item, $0) })
    }
}

struct EnvironmentCheckTests {
    @Test func everythingIsFine() async {
        let e = FakeEnv(), r = await e.full()
        #expect(r.count == EnvironmentCheck.Item.allCases.count && r.values.allSatisfy { $0.state == .ok })
        #expect(r[.claude]?.reason == "Версия 2.1.325")
        #expect(!"\(r)".contains("someone@example.com"))
        #expect(EnvironmentCheck.launchBlocked(Array(r.values), agent: .claude) == nil)
        // No prompt among the runs.
        #expect(e.log.calls == ["prepare", "claude --help", "claude --version", "claude auth status --json", "git --version", "codex", "gh"])
    }

    @Test func noTools() async {
        var e = FakeEnv()
        e.tools = [.git]
        let r = await e.full()
        for i in [EnvironmentCheck.Item.claude, .claudeLogin, .codex, .gh] { #expect(r[i]?.state == .missing && r[i]?.reason.isEmpty == false) }
        #expect(e.log.calls == ["prepare", "git --version"])
        #expect(EnvironmentCheck.launchBlocked(Array(r.values), agent: .claude) != nil)
        #expect(EnvironmentCheck.launchBlocked(Array(r.values), agent: .ssh) == nil)
    }

    /// The stub in /usr/bin would open the installer.
    @Test func gitStubIsNotRun() async {
        var e = FakeEnv()
        e.hasTools = false
        let r = await e.full()
        #expect(r[.git]?.state == .missing && r[.git]?.command == "xcode-select --install")
        #expect(!e.log.calls.contains("git --version"))
    }

    @Test func versions() async {
        var e = FakeEnv()
        func git(_ s: String, ok: Bool = true) async -> EnvironmentCheck.State? {
            e.answers["git --version"] = CheckOutput(ok: ok, out: s)
            return await e.full()[.git]?.state
        }
        #expect(await git("git version 2.35.9") == .old)
        #expect(await git("git version 2.36") == .ok)
        #expect(await git("git version 10.0.1 (x)") == .ok)
        #expect(await git("что-то") == .unknown)
        #expect(await git("git version 2.50", ok: false) == .unknown)
        e.answers["git --version"] = CheckOutput(ok: false, err: "You have not agreed to the Xcode license agreements")
        #expect(await e.full()[.git]?.command.contains("-license") == true)
    }

    @Test func oldClaude() async {
        var e = FakeEnv()
        e.answers["claude --help"] = CheckOutput(ok: true, out: "--print\n--input-format\n--permission-mode\n  auth   x")
        let r = await e.full()
        #expect(r[.claude]?.state == .old && r[.claude]?.reason.contains("--setting-sources") == true)
        #expect(EnvironmentCheck.launchBlocked(Array(r.values), agent: .claude) == "Устарело: Claude Code")
        #expect(!e.log.calls.contains("claude auth status --json"))
        // `auth status` would be a prompt there.
        e = FakeEnv()
        e.answers["claude --help"] = CheckOutput(ok: true, out: FakeEnv.goodHelp.replacingOccurrences(of: "  auth ", with: "  other "))
        let s = await e.full()
        #expect(s[.claude]?.state == .ok && s[.claudeLogin]?.state == .unknown)
        #expect(!e.log.calls.contains("claude auth status --json"))
        e.answers["claude --help"] = CheckOutput(ok: true, out: "привет")
        #expect(await e.full()[.claude]?.state == .unknown)
    }

    @Test func noLogin() async {
        var e = FakeEnv()
        e.answers["claude auth status --json"] = CheckOutput(ok: false, out: #"{"loggedIn": false}"#)
        e.ghAnswer = CheckOutput(ok: false, err: "no oauth token found")
        e.codexAnswer = .noLogin
        let r = await e.full()
        for i in [EnvironmentCheck.Item.claudeLogin, .codex, .gh] { #expect(r[i]?.state == .noLogin && r[i]?.command.contains("login") == true) }
        #expect(EnvironmentCheck.launchBlocked(Array(r.values), agent: .claude) == "Нет входа: Вход в Claude")
        e.answers["claude auth status --json"] = CheckOutput(ok: true, out: "ok")
        e.ghAnswer = CheckOutput(ok: false, err: #"unknown command "token""#)
        let s = await e.full()
        #expect(s[.claudeLogin]?.state == .unknown && s[.gh]?.state == .old)
    }

    @Test func noAnswer() async {
        var e = FakeEnv()
        let hang = CheckOutput(ok: false, timedOut: true)
        e.answers = ["git --version": hang, "claude --help": hang]
        e.ghAnswer = hang
        let r = await e.full()
        for i in [EnvironmentCheck.Item.git, .claude, .gh] { #expect(r[i]?.state == .noAnswer) }
    }

    @Test func quickRunsNothingButGit() {
        var e = FakeEnv()
        e.folderState = .missing
        let r = EnvironmentCheck.quick(e, root: URL(fileURLWithPath: "/p"))
        #expect(r.map(\.state) == [.missing, .ok, .unchecked, .unchecked, .unchecked, .unchecked])
        #expect(e.log.calls == ["git --version"])
        #expect(EnvironmentCheck.launchBlocked(r, agent: .claude) != nil)
        e.hasTools = false
        _ = EnvironmentCheck.quick(e, root: URL(fileURLWithPath: "/p"))
        #expect(e.log.calls == ["git --version"])
    }

    @Test func codexAnswers() async {
        var old = CodexSession(nil)
        _ = old.begin()
        guard case .old = CheckCodex(old.exited(code: 1)) else { Issue.record("old codex"); return }
        var silent = CodexSession(nil)
        _ = silent.begin()
        silent.startTimedOut()
        guard case .problem = CheckCodex(silent.exited(code: 9)) else { Issue.record("silent codex"); return }
        var r = AgentRunResult(program: "codex")
        #expect(CheckCodex(r) != .ok(""))
        r.resultText = CodexSession.noLogin
        r.isError = true
        r.cannotStart = true
        #expect(CheckCodex(r) == .noLogin)
        r = AgentRunResult(program: "codex")
        r.gotResult = true
        r.resultText = "codex 1, вход выполнен"
        #expect(CheckCodex(r) == .ok("codex 1, вход выполнен"))
        var e = FakeEnv()
        e.codexAnswer = .old("старый")
        #expect(await e.full()[.codex]?.state == .old)
    }
}
