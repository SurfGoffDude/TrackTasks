import Foundation
import TrackTasksCore

/// One turn of Claude in a container: task files are copied in, the container lives and goes, the folder is proved safe
/// for git, the task file comes back. `onExit` follows all of that; any trouble there is a failure of the turn.
@MainActor
final class DockerAgentRun: AgentRun {
    struct Place: Sendable {
        var host: DockerHost
        var worktree: Worktrees.Info
        /// Name in the main folder's tasks/; nil = no task file.
        var taskFile: String?
        /// The agent's edits of the task file go to the main folder.
        var returnsTask = true
        /// Review: the diff since this commit is put into `reviewDiff`.
        var reviewBase: String?
        var store = ContainerStore.shared
    }

    /// tasks/ is never committed from a worktree.
    nonisolated static let reviewDiff = "tasks/.tt-review.diff"

    var onEvent: ((AgentEvent) -> Void)?
    var onExit: ((AgentRunResult) -> Void)?
    var onPermission: ((AgentPermission) -> Void)?
    var onTurnStarted: (() -> Void)?

    private let place: Place
    private let inner = ClaudeProcess()
    private var run: DockerRun?
    /// Main actor only, like `run`: background steps get a copy or come back here through `await`.
    private var stopping = false

    init(_ place: Place) { self.place = place }

    private struct Ready: Sendable {
        var run: DockerRun
        var secrets: [String: String]
        var exchange: DockerExchange?
    }

    func start(_ request: AgentRequest) throws {
        var r = request
        r.cwd = URL(fileURLWithPath: ContainerSpec.workspace, isDirectory: true)
        r.addDirs = []
        let options = ClaudeOptions(r), place = place
        inner.onEvent = { [weak self] in self?.onEvent?($0) }
        inner.onTurnStarted = { [weak self] in self?.onTurnStarted?() }
        inner.onPermission = { [weak self] p in
            guard let self else { return }
            if let onPermission { onPermission(p) } else { inner.respond(p, allow: false, always: false) }
        }
        Task.detached(priority: .userInitiated) {
            let ready: Result<Ready, Error>
            do { ready = .success(try Self.prepare(place, options.arguments)) }
            catch { ready = .failure(error) }
            await self.prepared(ready, options)
        }
    }

    nonisolated private static func prepare(_ p: Place, _ args: [String]) throws -> Ready {
        guard p.host.engine.hasImage(p.host.image) else {
            throw ContainerStore.Failure(message: "Образа \(p.host.image) нет или Docker не запущен — Настройки → Docker")
        }
        var secrets = p.host.secrets
        if let token = p.host.token {
            let t = token()
            guard !t.isEmpty else { throw ContainerStore.Failure(message: "Токен Claude не прочитан из Keychain — Настройки → Docker") }
            secrets["CLAUDE_CODE_OAUTH_TOKEN"] = t
        }
        // git: before the folder is closed for it.
        var extra: [String: Data] = [:]
        if let base = p.reviewBase {
            let d = DiffLoader.runRaw(["diff", "--no-ext-diff", "--no-textconv", "\(base)..HEAD"], in: p.worktree.path, input: nil)
            guard d.status == 0 else { throw ContainerStore.Failure(message: "Не удалось снять diff для ревью: \(d.err)") }
            extra[reviewDiff] = d.out
        }
        let run = try p.store.begin(p.worktree.path, command: p.host.program + args, host: p.host, proxy: true) {
            $0.network = p.host.network
            $0.secrets = secrets.keys.sorted()
            if p.host.sessions { $0.sessions = p.store.volume(p.worktree.path) }
        }
        var exchange: DockerExchange?
        do {
            exchange = try p.taskFile.map { try DockerExchange.begin(main: p.worktree.main, worktree: p.worktree.path, taskFile: $0, extra: extra) }
            // Last, so that a failure above leaves no volume.
            if p.host.sessions {
                let v = p.host.engine.createVolume(p.store.volume(p.worktree.path), instance: p.store.instance)
                guard v.ok else { throw ContainerStore.Failure(message: "Том для сессий не создан: \(v.message)") }
            }
            return Ready(run: run, secrets: secrets, exchange: exchange)
        } catch {
            exchange?.restore()
            // No container was created.
            _ = p.store.end(p.worktree.path, leftover: nil)
            throw error
        }
    }

    private func prepared(_ r: Result<Ready, Error>, _ options: ClaudeOptions) {
        switch r {
        case .failure(let e): onExit?(failure(e.localizedDescription))
        case .success(let ready):
            run = ready.run
            let secrets = ready.secrets
            let stopNow = stopping
            Task.detached(priority: .userInitiated) {
                if stopNow { ready.run.stop() }
                let c = ready.run.create(secrets: secrets)
                await self.created(c, ready, options)
            }
        }
    }

    private func created(_ c: Worktrees.Result, _ ready: Ready, _ options: ClaudeOptions) {
        guard c.ok, !stopping else { return end(failure("Контейнер не создан: \(c.message)"), ready) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ready.run.engine.cli)
        p.arguments = ready.run.attachArgs
        p.environment = DockerEngine.environment()
        inner.onExit = { [weak self] s in
            var s = s
            // 125–127: docker or the image's program didn't start; a new session wouldn't help.
            if s.turns == 0, !s.gotResult, (125...127).contains(s.exitCode) { s.cannotStart = true }
            self?.end(s, ready)
        }
        do { try inner.start(options, client: p) } catch { end(failure(error.localizedDescription), ready) }
    }

    private func end(_ s: AgentRunResult, _ ready: Ready) {
        let place = place
        Task.detached(priority: .userInitiated) {
            let leftover = ready.run.engine.remove(ready.run.spec.name)
            ready.run.closeNetwork()
            let problem = place.store.end(place.worktree.path, leftover: leftover)
            var notes: [String] = [], error = problem
            // A container that may still write: its files aren't taken.
            if leftover == nil, let x = ready.exchange {
                if place.returnsTask, problem == nil {
                    do {
                        if case .conflict(let u) = try x.finish(conflicts: place.store.conflicts(place.worktree.path)) {
                            notes.append("Файл задачи изменили, пока работал агент: остался ваш, версия агента — \(u.path)")
                        }
                    } catch let e { error = e.localizedDescription }
                }
                x.restore()
            }
            let said = notes, failed = error
            await self.ended(s, failed, said)
        }
    }

    private func ended(_ s: AgentRunResult, _ error: String?, _ notes: [String]) {
        var s = s
        for n in notes { onEvent?(.text(n)) }
        // The client ends with a code of its own when the container is removed.
        s.stopped = stopping
        if let error {
            onEvent?(.text("✗ " + error))
            s.isError = true
            s.cannotStart = true
            s.resultText = error
            s.limit = nil
            // Not an ordinary cancel: the person must see it.
            s.stopped = false
        }
        onExit?(s)
    }

    private func failure(_ text: String) -> AgentRunResult {
        var s = AgentRunResult()
        s.isError = true
        s.cannotStart = true
        s.resultText = text
        s.stopped = stopping
        return s
    }

    func respond(_ p: AgentPermission, allow: Bool, always: Bool) { inner.respond(p, allow: allow, always: always) }

    func stop() {
        stopping = true
        guard let run else { return }
        Task.detached(priority: .userInitiated) { run.stop() }
    }

    func killTree() { stop() }
}
