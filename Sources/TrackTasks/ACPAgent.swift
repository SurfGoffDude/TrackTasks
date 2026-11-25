import Foundation
import TrackTasksCore

/// Any CLI that speaks the Agent Client Protocol; which one is in the profile.
struct ACPAgent: Agent {
    let id = AgentID.acp
    let title = "ACP-агент"
    /// The protocol doesn't tell whether the agent asks before using its own tools: it counts as one that doesn't,
    /// so no `.permissions` and no `.bypass` (its requests are always shown). `.resume` comes with `ACPFeatures`.
    let capabilities: AgentCapabilities = [.requiresWorktree]

    func makeRun() -> any AgentRun { ACPProcess() }
}

/// Tells what the agent announced.
@MainActor
protocol ACPFeaturesRun: AgentRun {
    var onFeatures: ((ACPFeatures) -> Void)? { get set }
}

enum ACPLocator {
    static func folders(_ env: [String: String]) -> [String] {
        let home = NSHomeDirectory(), nvm = "\(home)/.nvm/versions/node"
        var all = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        all += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        all += ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []).sorted(by: >).map { "\(nvm)/\($0)/bin" }
        all += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        // A relative one would be looked for in the worktree.
        var seen = Set<String>()
        return all.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    static func path(_ env: [String: String]) -> String { folders(env).joined(separator: ":") }

    static func resolve(_ command: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        func runs(_ p: String) -> Bool {
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && !dir.boolValue && FileManager.default.isExecutableFile(atPath: p)
        }
        if command.hasPrefix("/") { return runs(command) ? command : nil }
        return folders(env).map { $0 + "/" + command }.first(where: runs)
    }
}

enum ACPError: LocalizedError {
    case noCommand
    case bad(String)
    case notFound(String)
    var errorDescription: String? {
        switch self {
        case .noCommand: "В профиле ACP-агента не задана команда (Настройки → «Агенты»)"
        case .bad(let s): s
        case .notFound(let c): "Не найдена программа «\(c)» ACP-агента: установи её или укажи полный путь в профиле"
        }
    }
}

/// One process of an ACP agent: one turn (or only the check what it is).
@MainActor
final class ACPProcess: ACPFeaturesRun {
    var onEvent: ((AgentEvent) -> Void)?
    var onExit: ((AgentRunResult) -> Void)?
    var onPermission: ((AgentPermission) -> Void)?
    var onTurnStarted: (() -> Void)?
    var onFeatures: ((ACPFeatures) -> Void)?

    private var process: Process?
    private var session = ACPSession(nil, program: "acp")
    private var input: AgentStdin?
    private var access: ACPAccess?
    private let terminals = ACPTerminals()
    /// File requests: in order, off the main thread.
    private let files = DispatchQueue(label: "acp.files")
    private let halted = Flag()
    private let startTimeout: TimeInterval

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return on }
        func set() { lock.lock(); on = true; lock.unlock() }
    }

    init(startTimeout: TimeInterval = 60) { self.startTimeout = startTimeout }

    func start(_ request: AgentRequest) throws {
        guard let c = request.acp else { throw ACPError.noCommand }
        try start(c, request)
    }

    /// Version and capabilities only; no tokens are spent.
    func check(_ command: ACPCommand) throws { try start(command, nil) }

    private func start(_ command: ACPCommand, _ request: AgentRequest?) throws {
        if let why = command.problem { throw ACPError.bad(why) }
        var env = ProcessInfo.processInfo.environment
        guard let exe = ACPLocator.resolve(command.command, env: env) else { throw ACPError.notFound(command.command) }
        let program = (exe as NSString).lastPathComponent
        session = ACPSession(request, program: program)
        access = request.map { ACPAccess(access: $0.access, cwd: $0.cwd, addDirs: $0.addDirs) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = command.args
        p.currentDirectoryURL = request?.cwd ?? FileManager.default.temporaryDirectory
        env["PATH"] = (exe as NSString).deletingLastPathComponent + ":" + ACPLocator.path(env)
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        Log.queue.process(program, project: p.currentDirectoryURL?.lastPathComponent ?? "", command: "acp")
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(d) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.session.addStderr(String(decoding: d, as: UTF8.self)) } }
        }
        // Strong self: the result must come even if the owner dropped the run.
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            // Not to the end: a command left by the agent may keep the pipe open forever.
            func rest(_ h: FileHandle) -> Data {
                let fd = h.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var rest = Data(), chunk = [UInt8](repeating: 0, count: 65536)
                while case let n = read(fd, &chunk, chunk.count), n > 0 { rest.append(contentsOf: chunk[0..<n]) }
                return rest
            }
            let tail = rest(out.fileHandleForReading), errors = rest(err.fileHandleForReading), code = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.session.addStderr(String(decoding: errors, as: UTF8.self))
                    self.consume(tail + Data([0x0A]))
                    self.ended(code)
                }
            }
        }
        try p.run()
        process = p
        input = AgentStdin(inp.fileHandleForWriting)
        input?.send(session.begin())
        DispatchQueue.main.asyncAfter(deadline: .now() + startTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.process === p, !self.session.promptSent, !self.session.isFinished else { return }
                self.session.startTimedOut()
                self.killTree()
            }
        }
    }

    /// The result only after nothing of the run can change files any more.
    private func ended(_ code: Int32) {
        input?.close()
        input = nil
        process = nil
        halted.set()
        let r = session.exited(code: code)
        terminals.close { [self] in
            files.async {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.onExit?(r)
                        self.onExit = nil
                    }
                }
            }
        }
    }

    func respond(_ r: AgentPermission, allow: Bool, always: Bool) { carryOut(session.respond(r.id, allow: allow)) }

    func stop() {
        guard let p = process else { return }
        halted.set()
        let actions = session.interrupt()
        terminals.killAll()
        guard let actions else { return killTree() }
        carryOut(actions)
        killLater(p, after: 3)
    }

    /// The agent and every command it started.
    func killTree() {
        halted.set()
        terminals.killAll()
        if let p = process, p.isRunning { ProcessTree.killTree(p.processIdentifier) }
    }

    private func killLater(_ p: Process, after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { if self?.process === p { self?.killTree() } }
        }
    }

    private func consume(_ d: Data) {
        let before = session.turnStarted
        let actions = session.consume(d)
        if !before, session.turnStarted { onTurnStarted?() }
        carryOut(actions)
    }

    private func carryOut(_ actions: [ACPSession.Action]) {
        for a in actions {
            switch a {
            case .send(let obj): input?.send(obj)
            case .event(let e): onEvent?(e)
            case .features(let f): onFeatures?(f)
            case .permission(let r):
                if let onPermission { onPermission(r) } else { respond(r, allow: false, always: false) }
            case .read(let key, let path, let line, let limit):
                file(key, path) { ["content": try $0.read(path, line: line, limit: limit)] }
            case .write(let key, let path, let content):
                file(key, path) { try $0.write(path, content); return [:] }
            case .terminal(let key, let call):
                terminals.call(call) { [weak self] r in
                    guard let self else { return }
                    switch r {
                    case .success(let d): self.carryOut(self.session.reply(key, d))
                    case .failure(let e): self.carryOut(self.session.refuse(key, e.message, code: e.code))
                    }
                }
            case .finished:
                halted.set()
                terminals.killAll()
                // The agent exits with its input.
                input?.close()
                if let p = process { killLater(p, after: 5) }
            }
        }
    }

    private struct Answer: @unchecked Sendable { let result: Result<[String: Any], ACPAccess.Refusal> }

    private func file(_ key: String, _ path: String, _ work: @escaping @Sendable (ACPAccess) throws -> [String: Any]) {
        guard let access else { return }
        let halted = halted
        files.async {
            guard !halted.isSet else { return }
            let a: Answer
            do { a = Answer(result: .success(try work(access))) }
            catch { a = Answer(result: .failure(error as? ACPAccess.Refusal ?? .failed(error.localizedDescription))) }
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.answered(key, path, a) } }
        }
    }

    private func answered(_ key: String, _ path: String, _ a: Answer) {
        switch a.result {
        case .success(let d): carryOut(session.reply(key, d))
        case .failure(let e):
            if e == .outside || e == .protected { onEvent?(.tool("Отклонено: \(path) — \(e.message.lowercased())")) }
            carryOut(session.refuse(key, e.message, code: e.code))
        }
    }
}
