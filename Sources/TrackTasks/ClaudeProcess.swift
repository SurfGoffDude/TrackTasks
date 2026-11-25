import Foundation
import TrackTasksCore

// Chat and one-shot requests use Claude directly, under its older names.
typealias ClaudeRunStats = AgentRunResult
typealias ClaudeEvent = AgentEvent
typealias PermissionRequest = AgentPermission

struct ClaudeOptions {
    var cwd: URL
    var prompt: String
    var systemPrompt: String
    /// `--model`; empty = CLI default.
    var model: String
    var resume: String? = nil
    /// With `resume`: continue the history in a new session; the resumed one stays as it is.
    var fork = false
    /// With `fork`: keep the history only up to this message.
    var resumeAt: String? = nil
    var bypassPermissions = false
    var allowedTools: [String]
    /// Extra folders Claude may edit outside cwd (`--add-dir`).
    var addDirs: [URL] = []
    /// Don't load the user's MCP servers, plugins, hooks, skills and user-level settings:
    /// background runs only need the built-in tools, and every MCP schema costs input tokens on each step.
    var isolated = false
    /// Built-in tools available at all (`--tools`); nil = CLI default set, [] = no tools.
    var tools: [String]? = nil
    /// The user's message in the chat, not a background run: the session also goes to «Мои».
    var fromChat = false
    /// PNG, sent with the prompt.
    var images: [Data] = []
}

extension ClaudeOptions {
    var arguments: [String] {
        ClaudeArgs.run(systemPrompt: systemPrompt, model: model, allowedTools: allowedTools,
                       bypassPermissions: bypassPermissions, resume: resume, fork: fork, resumeAt: resumeAt,
                       addDirs: addDirs.map(\.path), isolated: isolated, tools: tools)
    }

    static let isolateKey = "isolateBackground"
    /// Settings → «Изолировать фоновые запуски» (on by default).
    static var isolateBackground: Bool { UserDefaults.standard.object(forKey: isolateKey) as? Bool ?? true }

    /// One-shot text answer (classification, commit message, limit probe): no tools, isolated.
    static func oneShot(cwd: URL, prompt: String, model: ClaudeModel) -> ClaudeOptions {
        ClaudeOptions(cwd: cwd, prompt: prompt, systemPrompt: "", model: model.alias, allowedTools: [],
                      isolated: isolateBackground, tools: [])
    }
}

enum ClaudeTools {
    /// Read the project, write only task/about files (enforced by system prompt).
    static let planning = ["Read", "Glob", "Grep", "Write", "Edit",
                           "Bash(git log:*)", "Bash(git status:*)", "Bash(git diff:*)", "Bash(git show:*)", "Bash(ls:*)"]
    /// Background task execution: edit code too.
    static let coding = planning + ["MultiEdit", "TodoWrite"]
}

enum ClaudeError: LocalizedError {
    case notFound
    var errorDescription: String? { "Не найден claude CLI. Укажи путь в Настройках (⌘,)." }
}

/// One headless `claude -p --output-format stream-json` run.
@MainActor
final class ClaudeProcess: AgentRun {
    var onEvent: ((ClaudeEvent) -> Void)?
    var onExit: ((ClaudeRunStats) -> Void)?
    /// Tool use needing approval. Leave nil to deny everything that isn't pre-approved.
    var onPermission: ((PermissionRequest) -> Void)?
    var onTurnStarted: (() -> Void)?
    /// Only the chat needs these.
    var onTool: ((ClaudeToolEvent) -> Void)?
    var onContext: ((ClaudeContext) -> Void)?
    /// See `ClaudeStream.point`.
    var point: String? { stream.point }

    /// Where ids of started sessions go.
    var sessions = AppSessions.shared
    /// Where ids of chat sessions (`fromChat`) go as well.
    var chatSessions = AppSessions.chats
    private var stream = ClaudeStream()

    private var process: Process?
    private var stdin: Input?

    /// Writes off the main thread: an image doesn't fit the pipe until claude starts reading.
    private final class Input: @unchecked Sendable {
        private let queue = DispatchQueue(label: "claude.stdin")
        private let handle: FileHandle
        init(_ h: FileHandle) {
            handle = h
            _ = fcntl(h.fileDescriptor, F_SETNOSIGPIPE, 1)
        }
        func send(_ d: Data) { queue.async { [handle] in try? handle.write(contentsOf: d) } }
        func close() { queue.async { [handle] in try? handle.close() } }
    }

    var isRunning: Bool { process != nil }

    /// `executable`: a stand-in for claude in tests. `client`: a program that is connected to claude already running
    /// elsewhere with its own arguments.
    func start(_ o: ClaudeOptions, executable: String? = nil, client: Process? = nil) throws {
        let stream = ClaudeStream(resume: o.resume, fork: o.fork, cwd: o.cwd.path)
        stream.onEvent = { [weak self] in self?.onEvent?($0) }
        stream.onPermission = { [weak self] r in
            guard let self else { return }
            if let onPermission { onPermission(r) } else { respond(r, allow: false, always: false) }
        }
        stream.onSend = { [weak self] in self?.send($0) }
        stream.onResult = { [weak self] in self?.closeInput() }
        stream.onSession = { [weak self] in
            self?.sessions.add($0)
            if o.fromChat { self?.chatSessions.add($0) }
        }
        if onTool != nil { stream.onTool = { [weak self] in self?.onTool?($0) } }
        stream.onContext = { [weak self] in self?.onContext?($0) }
        stream.onTurnStarted = { [weak self] in self?.onTurnStarted?() }
        stream.onLimits = { Limits.shared.update($0) }
        self.stream = stream

        let p = try client ?? local(o, executable)
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        Log.queue.process("claude", project: o.cwd.lastPathComponent,
                          command: "\(o.model.isEmpty ? "default" : o.model)\(o.resume != nil ? " --resume" : "")")

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stream.consume(d) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let s = String(data: d, encoding: .utf8) ?? ""
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stream.stats.stderr += s } }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            let code = proc.terminationStatus
            let signaled = proc.terminationReason == .uncaughtSignal
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !rest.isEmpty { self.stream.consume(rest) }
                    self.stream.consume(Data([0x0A]))
                    self.closeInput()
                    self.stream.stats.exitCode = code
                    self.stream.stats.stopped = signaled
                    self.process = nil
                    self.onExit?(self.stream.stats)
                }
            }
        }

        try p.run()
        process = p
        stdin = Input(inp.fileHandleForWriting)
        for m in ClaudeStream.opening(prompt: o.prompt, images: o.images) { send(m) }
    }

    private func local(_ o: ClaudeOptions, _ executable: String?) throws -> Process {
        guard let claude = executable ?? ClaudeLocator.resolve() else { throw ClaudeError.notFound }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = o.arguments
        p.currentDirectoryURL = o.cwd

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        let dir = (claude as NSString).deletingLastPathComponent
        env["PATH"] = [dir, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
            .joined(separator: ":")
        p.environment = env
        return p
    }

    /// Claude and every command it started.
    func killTree() {
        if let p = process, p.isRunning { ProcessTree.killTree(p.processIdentifier) }
        closeInput()
    }

    func stop() {
        closeInput()
        process?.terminate()
    }

    /// Answer a permission request. `always` saves claude's suggested rule to the project's .claude/settings.local.json.
    func respond(_ r: AgentPermission, allow: Bool, always: Bool) {
        if let answer = stream.answer(r.id, allow: allow, always: always) { send(answer) }
    }

    private func send(_ obj: [String: Any]) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        stdin.send(data + Data([0x0A]))
    }

    private func closeInput() {
        stdin?.close()
        stdin = nil
    }
}

/// Claude spend: today's total (UserDefaults) + every run in spend.jsonl for the stats screen.
@Observable @MainActor
final class Spend {
    static let shared = Spend()
    private(set) var today: Double
    /// Bumped on every write so the stats screen can reload.
    private(set) var version = 0

    typealias Entry = SpendEntry

    nonisolated static var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackTasks/spend.jsonl")
    }

    private init() {
        today = UserDefaults.standard.double(forKey: Spend.key())
    }

    private static func key() -> String { "spend-" + Codec.today() }

    func add(_ v: Double) {
        guard v > 0 else { return }
        let k = Spend.key()
        let nv = UserDefaults.standard.double(forKey: k) + v
        UserDefaults.standard.set(nv, forKey: k)
        today = nv
    }

    /// Record one agent run.
    func add(_ s: ClaudeRunStats, project: String, kind: String, task: SpendTask? = nil) {
        guard (s.costUSD ?? 0) > 0 || s.totalInput + s.outputTokens > 0 else { return }
        add(s.costUSD ?? 0)
        let e = Entry(date: Date(), project: project, model: Spend.family(s.model), kind: kind,
                      cost: s.costUSD, input: s.inputTokens, output: s.outputTokens,
                      cacheWrite: s.cacheWriteTokens, cacheRead: s.cacheReadTokens,
                      duration: s.durationMs > 0 ? s.durationMs : nil, turns: s.turns > 0 ? s.turns : nil,
                      task: task?.title, taskFile: task?.file)
        guard var line = try? Spend.encoder.encode(e) else { return }
        line.append(0x0A)
        let url = Spend.logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: url)
        }
        version += 1
    }

    /// "claude-opus-5-5" → "Opus".
    static func family(_ model: String) -> String {
        let m = model.lowercased()
        for f in ["fable", "opus", "sonnet", "haiku"] where m.contains(f) { return f.capitalized }
        return model.isEmpty ? "—" : model
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()

    nonisolated static func load(since: Date) -> [Entry] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? d.decode(Entry.self, from: Data($0.utf8)) }
            .filter { $0.date >= since }
    }
}
