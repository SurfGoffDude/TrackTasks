import Foundation
import TrackTasksCore

/// One `codex app-server` process: one turn (or only the check that codex works).
@MainActor
final class CodexProcess: AgentRun {
    var onEvent: ((AgentEvent) -> Void)?
    var onExit: ((AgentRunResult) -> Void)?
    var onPermission: ((AgentPermission) -> Void)?
    var onTurnStarted: (() -> Void)?

    private var process: Process?
    private var session = CodexSession(nil)
    private var input: AgentStdin?
    private static let startTimeout: TimeInterval = 60

    func start(_ request: AgentRequest) throws { try start(request, executable: nil) }

    /// nil request: check the version and the login.
    func start(_ request: AgentRequest?, executable: String?) throws {
        guard let codex = executable ?? CodexLocator.resolve() else { throw CodexError.notFound }
        var env = ProcessInfo.processInfo.environment
        if let file = CodexRules.blocking(CodexLocator.rulesDirs(request, env: env)) { throw CodexError.rules(file) }
        session = CodexSession(request)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: codex)
        p.arguments = ["app-server"]
        p.currentDirectoryURL = request?.cwd ?? FileManager.default.temporaryDirectory
        env["PATH"] = [(codex as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin",
                       env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        Log.queue.process("codex", project: p.currentDirectoryURL?.lastPathComponent ?? "", command: "app-server")
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
            let fd = out.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var rest = Data(), chunk = [UInt8](repeating: 0, count: 65536)
            while case let n = read(fd, &chunk, chunk.count), n > 0 { rest.append(contentsOf: chunk[0..<n]) }
            let tail = rest, code = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.consume(tail + Data([0x0A]))
                    self.input?.close()
                    self.input = nil
                    self.process = nil
                    let r = self.session.exited(code: code)
                    self.onExit?(r)
                    self.onExit = nil
                }
            }
        }
        try p.run()
        process = p
        input = AgentStdin(inp.fileHandleForWriting)
        input?.send(session.begin())
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.process === p, !self.session.turnStarted, !self.session.isFinished else { return }
                self.session.startTimedOut()
                self.killTree()
            }
        }
    }

    func respond(_ r: AgentPermission, allow: Bool, always: Bool) { carryOut(session.respond(r.id, allow: allow)) }

    func stop() {
        guard let p = process else { return }
        guard let msg = session.interrupt() else { return killTree() }
        input?.send(msg)
        killLater(p, after: 3)
    }

    /// Codex and every command it started.
    func killTree() {
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

    private func carryOut(_ actions: [CodexSession.Action]) {
        for a in actions {
            switch a {
            case .send(let obj): input?.send(obj)
            case .event(let e): onEvent?(e)
            case .started: break
            case .permission(let r):
                if let onPermission { onPermission(r) } else { respond(r, allow: false, always: false) }
            case .finished:
                // The server exits with its input.
                input?.close()
                if let p = process { killLater(p, after: 5) }
            }
        }
    }
}
