import Foundation
import TrackTasksCore

/// What containers are made from. nil in the queue = docker isn't offered.
struct DockerHost: Sendable {
    var engine: DockerEngine
    var image: String
    /// Claude inside the image; tests put a script here.
    var program = ["claude"]
    /// Network of the agent without `proxy`. Project commands get no secrets and no network; only `setup` has the proxy.
    var network = ContainerSpec.Network.none
    var limits = ContainerSpec.Limits()
    var secrets: [String: String] = [:]
    /// Sign-in of Claude. May block: the Keychain can ask the person.
    var token: (@Sendable () -> String)?
    var proxy: DockerProxy?
    /// Keep Claude's sessions in a volume: needs an image with `ContainerSpec.sessionsDir`.
    var sessions = true
}

/// A project command that can be stopped: on the host or in a container.
enum RunningCommand: Sendable {
    case process(Process)
    case container(DockerRun)

    /// Returns at once.
    func kill() {
        switch self {
        case .process(let p): if p.isRunning { ProcessTree.killTree(p.processIdentifier) }
        case .container(let r): DispatchQueue.global(qos: .userInitiated).async { r.stop() }
        }
    }

    /// nil = in a container.
    var pid: pid_t? { if case .process(let p) = self { p.processIdentifier } else { nil } }
}

/// Worktrees that containers write to. The mark belongs to the folder, not to a job: merges, checks and terminals know
/// only the folder. Kept on disk, any thread. Nothing in such a folder runs on the host, and git reads it only after
/// the container is gone and `.git` is proved untouched.
final class ContainerStore: @unchecked Sendable {
    static let shared = ContainerStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TrackTasks/containers", isDirectory: true))

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Record: Codable {
        var info: Worktrees.Info
        /// `.git` before the first container.
        var seal: Data
        /// A container was started and its result isn't proved safe yet.
        var unchecked = false
        var problem: String?
    }

    static let pending = "Контейнер ещё работает или не проверен — git в этой папке пока не запускается"
    private static let unreadable = "Запись о контейнере этой папки не читается — git и команды в ней не запускаются"

    /// One folder per marked worktree, named by `key`: every entry here is a mark, so other files lie next to it.
    private let root: URL
    private var instanceFile: URL { beside("instance") }
    /// Versions of task files from worktrees that are gone.
    private var keptConflicts: URL { beside("conflicts") }
    private func beside(_ name: String) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-" + name)
    }

    private let lock = NSLock()
    private var marked: Set<String>
    private var records: [String: Record] = [:]
    private var live: [String: [DockerRun]] = [:]
    private var _host: DockerHost?

    init(root: URL) {
        self.root = root
        // The folder itself is the mark: a lost record still means «container».
        marked = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    }

    /// For commands in marked folders. nil = they are refused.
    var host: DockerHost? {
        get { lock.withLock { _host } }
        set { lock.withLock { _host = newValue } }
    }

    static func key(_ folder: URL) -> String { RemoteRun.key(folder.standardizedFileURL.path) }
    private func dir(_ key: String) -> URL { root.appendingPathComponent(key, isDirectory: true) }
    func volume(_ folder: URL) -> String { "tracktasks-" + Self.key(folder) }
    func conflicts(_ folder: URL) -> URL { dir(Self.key(folder)).appendingPathComponent("conflicts", isDirectory: true) }

    /// Label of this copy of the app's containers.
    var instance: String {
        let u = instanceFile
        return lock.withLock {
            if let s = try? String(contentsOf: u, encoding: .utf8), UUID(uuidString: s) != nil { return s }
            let s = UUID().uuidString
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? s.write(to: u, atomically: true, encoding: .utf8)
            return s
        }
    }

    // MARK: Marks

    func isContainer(_ folder: URL) -> Bool {
        lock.withLock { marked.isEmpty ? false : marked.contains(Self.key(folder)) }
    }

    /// Call with the lock held.
    private func load(_ key: String) -> Record? {
        if let r = records[key] { return r }
        guard let d = try? Data(contentsOf: dir(key).appendingPathComponent("record.json")),
              let r = try? JSONDecoder().decode(Record.self, from: d) else { return nil }
        records[key] = r
        return r
    }

    private func store(_ r: Record, _ key: String) throws {
        try JSONEncoder().encode(r).write(to: dir(key).appendingPathComponent("record.json"), options: .atomic)
        records[key] = r
    }

    func record(_ folder: URL) -> Record? { lock.withLock { load(Self.key(folder)) } }

    /// Before the first container of the folder. A marked folder keeps its old seal.
    func mark(_ w: Worktrees.Info) throws {
        let key = Self.key(w.path)
        try lock.withLock {
            if marked.contains(key) {
                guard load(key) != nil else { throw Failure(message: Self.unreadable) }
                return
            }
            guard let seal = WorktreeSeal.read(w.path) else { throw Failure(message: "Не удалось прочитать .git worktree") }
            try FileManager.default.createDirectory(at: dir(key), withIntermediateDirectories: true)
            marked.insert(key)
            try ContainerSpec.gitLink.write(to: dir(key).appendingPathComponent("gitLink"), atomically: true, encoding: .utf8)
            try store(Record(info: w, seal: seal), key)
        }
    }

    // MARK: Git on the host

    /// Why git must not run in the folder now; nil = may.
    func refusal(_ folder: URL) -> String? {
        lock.withLock {
            guard !marked.isEmpty else { return nil }
            let key = Self.key(folder)
            guard marked.contains(key) else { return nil }
            guard let r = load(key) else { return Self.unreadable }
            return r.problem ?? (r.unchecked ? Self.pending : nil)
        }
    }

    /// A hook or fsmonitor of the main repository may be a path inside the worktree.
    func gitOptions(_ folder: URL) -> [String] {
        isContainer(folder) ? ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] : []
    }

    // MARK: Runs. They block: not for the main thread.

    /// One run or check of a folder at a time. Waits, so on the main thread it is refused instead of freezing the app.
    private func claim(_ key: String) throws {
        guard !Thread.isMainThread else { throw Failure(message: "Контейнер нельзя запускать с главного потока") }
        let until = Date().addingTimeInterval(60)
        while !lock.withLock({ () -> Bool in
            guard live[key] == nil else { return false }
            live[key] = []
            return true
        }) {
            guard Date() < until else { throw Failure(message: Self.pending) }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func unclaim(_ key: String) { lock.withLock { live[key] = nil } }

    /// The container, not created yet. The folder is closed for git until `end`.
    func begin(_ folder: URL, command: [String], host: DockerHost, proxy: Bool = false,
               _ edit: (inout ContainerSpec) -> Void = { _ in }) throws -> DockerRun {
        let key = Self.key(folder)
        try claim(key)
        do {
            guard let r = record(folder) else { throw Failure(message: Self.unreadable) }
            if r.unchecked || r.problem != nil, let why = clean(folder, host.engine) { throw Failure(message: why) }
            var spec = ContainerSpec(image: host.image, worktree: folder, gitSeal: dir(key).appendingPathComponent("gitLink"),
                                     command: command, instance: instance, job: key)
            spec.limits = host.limits
            edit(&spec)
            let run = DockerRun(host.engine, spec, proxy: proxy ? host.proxy : nil)
            try lock.withLock {
                guard var now = load(key) else { throw Failure(message: Self.unreadable) }
                now.unchecked = true
                try store(now, key)
                live[key] = [run]
            }
            return run
        } catch {
            unclaim(key)
            throw error
        }
    }

    /// The container was removed (`leftover` = it wasn't). nil = git may work in the folder again.
    func end(_ folder: URL, leftover: String?) -> String? {
        let key = Self.key(folder)
        defer { lock.withLock { live[key] = nil } }
        return settle(folder, leftover: leftover)
    }

    private func settle(_ folder: URL, leftover: String?) -> String? {
        let key = Self.key(folder)
        guard let r = record(folder) else { return isContainer(folder) ? Self.unreadable : nil }
        let problem = leftover ?? WorktreeSeal.problem(folder, sealed: r.seal)
        return lock.withLock {
            guard var now = load(key) else { return Self.unreadable }
            now.problem = problem
            now.unchecked = leftover != nil
            do { try store(now, key) } catch { return "Не удалось записать проверку контейнера: \(error.localizedDescription)" }
            return problem
        }
    }

    private func clean(_ folder: URL, _ engine: DockerEngine) -> String? {
        settle(folder, leftover: engine.removeAll(instance: instance, job: Self.key(folder)))
    }

    /// Removes what is left of earlier runs and looks at the folder again. nil = all is well.
    @discardableResult
    func check(_ folder: URL, _ engine: DockerEngine) -> String? {
        let key = Self.key(folder)
        do { try claim(key) } catch { return error.localizedDescription }
        defer { unclaim(key) }
        return clean(folder, engine)
    }

    /// A project command (setup, verify, teardown) in a marked folder: no secrets; network only through the proxy, for `setup`.
    func run(_ command: String, in folder: URL, timeout: TimeInterval, variables: [String: String] = [:], proxy: Bool = false,
             onStart: ((RunningCommand) -> Void)? = nil, onOutput: (@Sendable (String) -> Void)? = nil) -> Worktrees.Result {
        guard let host else { return .init(ok: false, out: "", err: "Docker не настроен — команда не запускается вне контейнера") }
        do {
            let run = try begin(folder, command: ["/bin/sh", "-c", command], host: host, proxy: proxy) { $0.secrets = variables.keys.sorted() }
            onStart?(.container(run))
            let o = run.run(timeout: timeout, secrets: variables, onOutput: onOutput)
            if let why = end(folder, leftover: o.leftover) { return .init(ok: false, out: o.result.out, err: o.result.err + "\n" + why) }
            return o.result
        } catch { return .init(ok: false, out: "", err: error.localizedDescription) }
    }

    // MARK: Cleanup

    /// The folder is going away: containers first, then the volume and the mark. Error = keep the folder.
    func release(_ folder: URL) -> String? {
        guard isContainer(folder) else { return nil }
        let key = Self.key(folder)
        let runs = lock.withLock { live[key] ?? [] }
        for r in runs { if let why = r.stop() { return why } }
        // Whoever ran them removes them too and looks at the folder.
        let until = Date().addingTimeInterval(60)
        while lock.withLock({ live[key] != nil }), Date() < until { Thread.sleep(forTimeInterval: 0.1) }
        guard let engine = host?.engine ?? DockerEngine.find() else { return "Docker не найден — контейнеры папки не проверены" }
        if let why = engine.removeAll(instance: instance, job: key) ?? engine.removeVolume(volume(folder)) { return why }
        return nil
    }

    /// After the folder is deleted.
    func forget(_ folder: URL) {
        let key = Self.key(folder)
        lock.withLock {
            guard marked.contains(key) else { return }
            // Versions of task files that nobody took stay.
            let kept = dir(key).appendingPathComponent("conflicts")
            if FileManager.default.fileExists(atPath: kept.path) {
                let to = keptConflicts
                try? FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
                guard (try? FileManager.default.moveItem(at: kept, to: to.appendingPathComponent(key + "-" + UUID().uuidString))) != nil else { return }
            }
            guard (try? FileManager.default.removeItem(at: dir(key))) != nil else { return }
            marked.remove(key)
            records[key] = nil
        }
    }

    /// After a crash: containers of this copy of the app that no live run owns, then the folders they wrote to.
    /// Without marked folders Docker isn't touched.
    func recover() {
        guard !lock.withLock({ marked.isEmpty }), let engine = host?.engine ?? DockerEngine.find() else { return }
        // Listed first: a run is live before its container exists.
        if let all = engine.containers(instance: instance) {
            let names = lock.withLock { live.values.joined().map(\.spec.name) }
            let keep = Set(names + names.map(DockerProxy.container))
            for n in all where !keep.contains(n) { _ = engine.remove(n) }
            _ = engine.removeNetworks(instance: instance, keep: Set(names.map(DockerProxy.network)))
        }
        let folders = lock.withLock { marked.compactMap { k in live[k] == nil ? load(k)?.info.path : nil } }
        for f in folders where record(f)?.unchecked == true { check(f, engine) }
    }

    /// The app quits. Waits a little; what isn't gone by then is removed at the next start.
    func stopAll() {
        let runs = lock.withLock { Array(live.values.joined()) }
        guard !runs.isEmpty else { return }
        let g = DispatchGroup()
        for r in runs { DispatchQueue.global(qos: .userInitiated).async(group: g) { r.stop(); r.closeNetwork() } }
        _ = g.wait(timeout: .now() + 5)
    }
}
