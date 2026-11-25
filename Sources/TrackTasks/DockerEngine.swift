import Foundation
import TrackTasksCore

/// `docker` CLI. Calls block: not for the main thread.
struct DockerEngine: Sendable {
    static let timeout: TimeInterval = 30

    let cli: String

    /// nil = Docker isn't installed.
    static func find() -> DockerEngine? {
        ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }.map(DockerEngine.init)
    }

    /// Only what the CLI itself needs, plus the secrets named in the spec: nothing of the app's environment leaks.
    static func environment(_ secrets: [String: String] = [:]) -> [String: String] {
        var env = secrets
        for (k, v) in ProcessInfo.processInfo.environment where k == "HOME" || k.hasPrefix("DOCKER_") { env[k] = v }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return env
    }

    func run(_ args: [String], secrets: [String: String] = [:], timeout: TimeInterval = DockerEngine.timeout,
             input: String? = nil, onOutput: (@Sendable (String) -> Void)? = nil) -> Worktrees.Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        p.environment = Self.environment(secrets)
        Log.queue.process("docker", project: "", command: args.first ?? "")
        return TimedProcess.run(p, timeout: timeout, input: input, outputLimit: 1 << 20, onOutput: onOutput)
    }

    var isUp: Bool { run(["version", "--format", "{{.Server.Version}}"], timeout: 10).ok }

    func hasImage(_ image: String) -> Bool { run(["image", "inspect", "--format", "{{.Id}}", image]).ok }

    /// nil = the daemon didn't answer.
    private func exists(_ name: String) -> Bool? {
        let r = run(["ps", "-a", "--filter", "name=\(name)", "--format", "{{.Names}}"])
        // The filter matches parts of names.
        return r.ok ? r.out.split(separator: "\n").contains { $0 == name } : nil
    }

    /// nil = there is no such container any more.
    func remove(_ name: String) -> String? {
        var message = ""
        for _ in 0..<20 {
            let r = run(["rm", "-f", "-v", name])
            // The outcome is asked from the daemon: the text of errors depends on docker's version.
            guard let there = exists(name) else { return "Контейнер \(name) не удалён: \(r.message)" }
            if !there { return nil }
            message = r.message
            // Removal by `--rm` may be under way.
            Thread.sleep(forTimeInterval: 0.3)
        }
        return "Контейнер \(name) не удалён: \(message)"
    }

    /// Names of this app copy's containers, running or not. nil = the daemon didn't answer.
    func containers(instance: String) -> [String]? {
        let r = run(["ps", "-a", "--filter", "label=\(ContainerSpec.instanceLabel)=\(instance)", "--format", "{{.Names}}"])
        return r.ok ? r.out.split(separator: "\n").map(String.init) : nil
    }

    /// Containers of one worktree. nil = all gone.
    func removeAll(instance: String, job: String) -> String? {
        let r = run(["ps", "-a", "--filter", "label=\(ContainerSpec.instanceLabel)=\(instance)",
                     "--filter", "label=\(ContainerSpec.jobLabel)=\(job)", "--format", "{{.Names}}"])
        guard r.ok else { return "Docker не ответил — контейнеры не проверены: \(r.message)" }
        return r.out.split(separator: "\n").compactMap { remove(String($0)) }.first
            ?? removeNetworks(instance: instance, job: job, keep: [])
    }

    /// Networks of this app copy (of one worktree) except `keep`. nil = all gone.
    func removeNetworks(instance: String, job: String? = nil, keep: Set<String>) -> String? {
        var args = ["network", "ls", "--filter", "label=\(ContainerSpec.instanceLabel)=\(instance)"]
        if let job { args += ["--filter", "label=\(ContainerSpec.jobLabel)=\(job)"] }
        let r = run(args + ["--format", "{{.Name}}"])
        guard r.ok else { return "Docker не ответил — сети не проверены: \(r.message)" }
        return r.out.split(separator: "\n").map(String.init).filter { !keep.contains($0) }.compactMap {
            let d = run(["network", "rm", $0])
            return d.ok ? nil : "Сеть \($0) не удалена: \(d.message)"
        }.first
    }

    /// The closed network of one container and the proxy in it. nil = ready.
    func openNetwork(_ p: DockerProxy, for spec: ContainerSpec) -> String? {
        for args in [p.networkArgs(spec.name, instance: spec.instance, job: spec.job),
                     p.createArgs(spec.name, instance: spec.instance, job: spec.job),
                     p.connectArgs(spec.name), ["start", DockerProxy.container(spec.name)]] {
            let r = run(args)
            guard r.ok else { return "Сеть с прокси не создана: \(r.message)" }
        }
        return nil
    }

    /// After the container is gone. What stays is removed at the next start or run of the folder.
    func closeNetwork(for spec: ContainerSpec) {
        _ = remove(DockerProxy.container(spec.name))
        _ = run(["network", "rm", "-f", DockerProxy.network(spec.name)])
    }

    /// Does nothing when it exists.
    func createVolume(_ name: String, instance: String) -> Worktrees.Result {
        run(["volume", "create", "--label", "\(ContainerSpec.instanceLabel)=\(instance)", name])
    }

    /// nil = there is no such volume any more.
    func removeVolume(_ name: String) -> String? {
        let r = run(["volume", "rm", "-f", name])
        return r.ok ? nil : "Том \(name) не удалён: \(r.message)"
    }

    /// Leftovers after a crash: only containers with our label that no live job owns. Returns what wasn't removed.
    func cleanup(instance: String, keep: Set<String>) -> [String] {
        guard let all = containers(instance: instance) else { return ["Docker не ответил — контейнеры не проверены"] }
        return all.filter { !keep.contains($0) }.compactMap(remove)
    }
}

/// One container from creation to removal. `run` blocks; `stop` may come from any thread at any moment.
final class DockerRun: @unchecked Sendable {
    struct Outcome {
        var result: Worktrees.Result
        var stopped: Bool
        /// The container may still be there: to be shown and retried.
        var leftover: String?
    }

    let engine: DockerEngine
    let spec: ContainerSpec
    let proxy: DockerProxy?
    private let lock = NSLock()
    private var stopping = false

    /// With a proxy the container gets its own closed network.
    init(_ engine: DockerEngine, _ spec: ContainerSpec, proxy: DockerProxy? = nil) {
        self.engine = engine
        var spec = spec
        if proxy != nil {
            spec.network = .named(DockerProxy.network(spec.name))
            spec.viaProxy = true
        }
        self.spec = spec
        self.proxy = proxy
    }

    var isStopping: Bool { lock.withLock { stopping } }

    /// Killing the docker client leaves the container alive, so the container itself is removed; the client then exits.
    /// Returns an error if it could not be removed (`run` tries once more).
    @discardableResult
    func stop() -> String? {
        lock.withLock { stopping = true }
        return engine.remove(spec.name)
    }

    /// First step of an interactive run; then the client is started with `attachArgs`, at the end — `engine.remove`.
    func create(secrets: [String: String] = [:]) -> Worktrees.Result {
        let args: [String]
        do { args = try spec.createArgs() } catch { return .init(ok: false, out: "", err: error.localizedDescription) }
        if isStopping { return .init(ok: false, out: "", err: "Остановлено") }
        if let proxy, let why = engine.openNetwork(proxy, for: spec) { return .init(ok: false, out: "", err: why) }
        return engine.run(args, secrets: secrets.filter { spec.secrets.contains($0.key) })
    }

    /// Together with `engine.remove`; may be repeated.
    func closeNetwork() { if proxy != nil { engine.closeNetwork(for: spec) } }

    var attachArgs: [String] { ["start", "-ai", spec.name] }

    /// `secrets`: values for `spec.secrets`.
    func run(timeout: TimeInterval, secrets: [String: String] = [:], input: String? = nil,
             onOutput: (@Sendable (String) -> Void)? = nil) -> Outcome {
        if case .failure(let e) = Result(catching: { try spec.createArgs() }) {
            return Outcome(result: .init(ok: false, out: "", err: e.localizedDescription), stopped: false)
        }
        if isStopping { return Outcome(result: .init(ok: false, out: "", err: ""), stopped: true) }
        var r = create(secrets: secrets)
        // Stopped while it was being created: `stop` may have come too early to find it.
        if r.ok, !isStopping {
            r = engine.run(attachArgs, timeout: timeout, input: input, onOutput: onOutput)
        }
        // Also after a timeout, a lost client or a failed create. Normally `--rm` has done it already.
        let leftover = engine.remove(spec.name)
        closeNetwork()
        let stopped = isStopping
        // A stopped run is never a success, whatever step it was stopped at.
        if stopped { r = .init(ok: false, out: r.out, err: r.err) }
        return Outcome(result: r, stopped: stopped, leftover: leftover)
    }
}
