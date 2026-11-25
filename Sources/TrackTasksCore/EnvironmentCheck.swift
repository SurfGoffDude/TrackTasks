import Foundation

/// What the tracker needs from the Mac. Pure: files and commands are behind `CheckEnvironment`.
public enum EnvironmentCheck {
    public enum Item: String, CaseIterable, Identifiable, Sendable {
        case folder, git, claude, claudeLogin, codex, gh
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .folder: "Папка проектов"
            case .git: "git"
            case .claude: "Claude Code"
            case .claudeLogin: "Вход в Claude"
            case .codex: "Codex"
            case .gh: "GitHub CLI (gh)"
            }
        }
        public var isRequired: Bool { self == .git }
    }

    public enum State: Equatable, Sendable {
        case ok
        case missing
        case old
        case noLogin
        /// Needs a run the user hasn't asked for yet.
        case unchecked
        /// The answer wasn't understood: neither fine nor broken.
        case unknown
        case noAnswer
    }

    public struct Report: Equatable, Identifiable, Sendable {
        public var item: Item
        public var state: State
        /// Version or path; for a problem — why.
        public var reason: String
        /// What to do; empty = nothing.
        public var fix: String
        /// To be copied. The app never runs it.
        public var command: String
        public var id: Item { item }

        public init(_ item: Item, _ state: State, _ reason: String, fix: String = "", command: String = "") {
            self.item = item
            self.state = state
            self.reason = reason
            self.fix = fix
            self.command = command
        }
    }

    // MARK: Checks

    /// Looks at files; runs only `xcode-select -p` and, when the tools are there, `git --version`.
    public static func quick(_ env: some CheckEnvironment, root: URL) -> [Report] {
        func later(_ item: Item, _ tool: CheckTool) -> Report {
            guard env.find(tool) != nil else { return missing(item) }
            return Report(item, .unchecked, "Найден, ещё не проверен")
        }
        let claude = later(.claude, .claude)
        let login = claude.state == .missing ? noClaude : Report(.claudeLogin, .unchecked, "Ещё не проверен")
        return [folder(env, root), git(env), claude, login, later(.codex, .codex), later(.gh, .gh)]
    }

    /// On the user's request only: starts the tools. No prompt goes to any model.
    public static func full(_ env: some CheckEnvironment, root: URL) async -> [Report] {
        env.prepare()
        let (claude, login) = checkClaude(env)
        return [folder(env, root), git(env), claude, login, await codex(env), gh(env)]
    }

    public static func folder(_ env: some CheckEnvironment, _ root: URL) -> Report {
        switch env.folder(root) {
        case .ready: Report(.folder, .ok, root.path)
        case .missing: Report(.folder, .missing, "Папки ещё нет", fix: "Выбери другую или создай вместе с примером проекта")
        case .notFolder: Report(.folder, .unknown, "По этому пути файл, а не папка", fix: "Выбери другую папку")
        case .denied: Report(.folder, .unknown, "Нет прав на чтение или запись", fix: "Выбери другую папку или дай доступ в Finder")
        }
    }

    /// `worktree list -z` appeared there. It is the newest thing the app asks of git.
    static let minGit = [2, 36]

    static func git(_ env: some CheckEnvironment) -> Report {
        // Without the tools `/usr/bin/git` is a stub that opens the installer.
        guard env.developerTools() else {
            return Report(.git, .missing, "Не установлены Command Line Tools (в них git; git из Homebrew приложение не использует)",
                          fix: "Выполни команду в терминале и проверь снова", command: "xcode-select --install")
        }
        let r = env.run(.git, ["--version"])
        if r.timedOut { return noAnswer(.git) }
        if r.err.lowercased().contains("license") {
            return Report(.git, .unknown, "git ждёт согласия с лицензией Xcode", fix: "Выполни команду в терминале и проверь снова",
                          command: "sudo xcodebuild -license")
        }
        guard r.ok, let v = version(r.out) else { return unclear(.git) }
        guard isAtLeast(v, minGit) else {
            return Report(.git, .old, "Версия \(text(v)), нужна \(text(minGit)) или новее", fix: "Обнови Command Line Tools в Настройках macOS")
        }
        return Report(.git, .ok, "Версия \(text(v))")
    }

    /// Passed to every run; an older claude exits on an unknown option.
    static let claudeFlags = ["--input-format", "--permission-mode", "--setting-sources", "--strict-mcp-config", "--disable-slash-commands"]

    private static let noClaude = Report(.claudeLogin, .missing, "Сначала нужен Claude Code")
    private static let claudeUpdate = "claude update"
    private static let claudeLogin = "claude auth login"

    static func checkClaude(_ env: some CheckEnvironment) -> (Report, Report) {
        guard env.find(.claude) != nil else { return (missing(.claude), noClaude) }
        let help = env.run(.claude, ["--help"])
        func loginUnknown(_ why: String) -> Report { Report(.claudeLogin, .unchecked, why) }
        if help.timedOut { return (noAnswer(.claude), loginUnknown("Claude Code не ответил")) }
        let words = Set(help.out.split { !($0.isLetter || $0.isNumber || $0 == "-") }.map(String.init))
        guard help.ok, words.contains("--print") else { return (unclear(.claude), loginUnknown("Claude Code не проверен")) }
        let lacks = claudeFlags.filter { !words.contains($0) }
        let v = version(env.run(.claude, ["--version"]).out).map(text)
        guard lacks.isEmpty else {
            return (Report(.claude, .old, "\(v.map { "Версия \($0)" } ?? "Эта версия") не знает: \(lacks.joined(separator: ", "))",
                           fix: "Обнови Claude Code", command: claudeUpdate), loginUnknown("Сначала обнови Claude Code"))
        }
        let claude = Report(.claude, .ok, v.map { "Версия \($0)" } ?? "Версия неизвестна, нужные возможности есть")
        // Without this command the words would be taken as a prompt and spend the limit.
        guard help.out.split(separator: "\n").contains(where: { $0.hasPrefix("  auth ") }) else {
            return (claude, Report(.claudeLogin, .unknown, "Эта версия не умеет показать вход", fix: "Обнови Claude Code или проверь вход в терминале", command: claudeUpdate))
        }
        let a = env.run(.claude, ["auth", "status", "--json"])
        if a.timedOut { return (claude, noAnswer(.claudeLogin)) }
        // Nothing else of the answer (email, organization) is kept.
        let json = (try? JSONSerialization.jsonObject(with: Data(a.out.utf8))) as? [String: Any]
        switch json?["loggedIn"] as? Bool {
        case true?: return (claude, Report(.claudeLogin, .ok, "Вход выполнен"))
        case false?:
            return (claude, Report(.claudeLogin, .noLogin, "Вход не выполнен", fix: "Выполни команду в терминале и проверь снова", command: claudeLogin))
        case nil: return (claude, unclear(.claudeLogin))
        }
    }

    static func codex(_ env: some CheckEnvironment) async -> Report {
        guard env.find(.codex) != nil else { return missing(.codex) }
        switch await env.codex() {
        case .ok(let t): return Report(.codex, .ok, t)
        case .noLogin: return Report(.codex, .noLogin, "Вход не выполнен", fix: "Выполни команду в терминале и проверь снова", command: "codex login")
        case .old(let t): return Report(.codex, .old, t, fix: "Обнови Codex", command: "npm install -g @openai/codex@latest")
        case .problem(let t): return Report(.codex, .unknown, t, fix: "Проверь в Настройках (⌘,): «Проверить Codex»")
        }
    }

    static func gh(_ env: some CheckEnvironment) -> Report {
        guard env.find(.gh) != nil else { return missing(.gh) }
        let r = env.ghLogin()
        if r.timedOut { return noAnswer(.gh) }
        if r.ok { return Report(.gh, .ok, "Вход на github.com есть") }
        if r.err.contains("unknown command") {
            return Report(.gh, .old, "Эта версия не знает gh auth token", fix: "Обнови gh", command: "brew upgrade gh")
        }
        return Report(.gh, .noLogin, "Нет входа на github.com", fix: "Нужен только для PR, импорта Issues и GitHub-событий", command: "gh auth login")
    }

    // MARK: First task

    /// Why the first task can't be started now, nil — it can. `agent`: the agent of the default profile.
    public static func launchBlocked(_ reports: [Report], agent: AgentID) -> String? {
        func state(_ i: Item) -> State { reports.first { $0.item == i }?.state ?? .unchecked }
        var need: [Item] = [.git]
        if agent == .claude { need += [.claude, .claudeLogin] }
        if agent == .codex { need.append(.codex) }
        for i in need {
            switch state(i) {
            case .ok, .unknown, .noAnswer: continue
            case .unchecked: return "Сначала нажми «Проверить» на шаге проверок"
            case .missing: return "Не найдено: \(i.title)"
            case .old: return "Устарело: \(i.title)"
            case .noLogin: return "Нет входа: \(i.title)"
            }
        }
        return nil
    }

    // MARK: Pieces

    private static func missing(_ item: Item) -> Report {
        switch item {
        case .claude:
            Report(item, .missing, "Не найден. Нужен только для запуска задач и чата", fix: "Установи Claude Code или укажи путь в Настройках (⌘,)",
                   command: "curl -fsSL https://claude.ai/install.sh | bash")
        case .codex:
            Report(item, .missing, "Не найден. Это второй агент, без него всё работает", fix: "Установи Codex или укажи путь в Настройках (⌘,)",
                   command: "npm install -g @openai/codex")
        default:
            Report(item, .missing, "Не найден. Нужен только для PR, импорта Issues и GitHub-событий", fix: "Установи gh", command: "brew install gh")
        }
    }

    private static func noAnswer(_ item: Item) -> Report {
        Report(item, .noAnswer, "Нет ответа", fix: "Проверь снова; возможно, macOS ждёт разрешения в другом окне")
    }

    private static func unclear(_ item: Item) -> Report {
        Report(item, .unknown, "Не удалось узнать: ответ не разобран", fix: "Проверь командой в терминале", command: item == .claudeLogin ? "claude auth status" : "\(item.rawValue) --version")
    }

    /// First `1.2` or `1.2.3…` of the text.
    static func version(_ s: String) -> [Int]? {
        guard let m = s.firstMatch(of: #/(\d+)\.(\d+)(?:\.(\d+))?/#) else { return nil }
        return [m.1, m.2, m.3].compactMap { $0.flatMap { Int($0) } }
    }

    static func isAtLeast(_ v: [Int], _ min: [Int]) -> Bool { !v.lexicographicallyPrecedes(min) }
    private static func text(_ v: [Int]) -> String { v.map(String.init).joined(separator: ".") }
}

public enum CheckTool: String, Sendable { case git, claude, codex, gh }

public struct CheckOutput: Sendable {
    public var ok: Bool
    public var out: String
    public var err: String
    public var timedOut: Bool
    public init(ok: Bool, out: String = "", err: String = "", timedOut: Bool = false) {
        self.ok = ok
        self.out = out
        self.err = err
        self.timedOut = timedOut
    }
}

public enum CheckFolder: Sendable { case ready, missing, notFolder, denied }
public enum CheckCodex: Sendable, Equatable {
    case ok(String), noLogin, old(String), problem(String)

    /// Result of `CodexSession(nil)`: an error may be told in `resultText` too.
    public init(_ r: AgentRunResult) {
        let text = r.errorText.isEmpty ? r.resultText : r.errorText
        if !r.failed, !r.cannotStart, !r.resultText.isEmpty { self = .ok(r.resultText) }
        else if text == CodexSession.noLogin { self = .noLogin }
        else if r.cannotStart, CodexSession.isOutdated(text) { self = .old(text) }
        else { self = .problem(text.isEmpty ? "Codex не ответил" : text) }
    }
}

/// Blocking calls: never on the main thread.
public protocol CheckEnvironment: Sendable {
    /// Before the full check: may start the user's shell to find claude.
    func prepare()
    /// Files only.
    func find(_ tool: CheckTool) -> String?
    func folder(_ url: URL) -> CheckFolder
    /// `xcode-select -p` leads to a git.
    func developerTools() -> Bool
    func run(_ tool: CheckTool, _ args: [String]) -> CheckOutput
    /// The token must not come back.
    func ghLogin() -> CheckOutput
    func codex() async -> CheckCodex
}
