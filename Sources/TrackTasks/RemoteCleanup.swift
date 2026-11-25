import Foundation
import TrackTasksCore

/// What is left on servers: stops that aren't confirmed yet and folders that aren't needed any more.
/// Any thread; the network is only used in the background. A result that wasn't taken is never deleted by itself.
final class RemoteCleanup: @unchecked Sendable {
    static let shared = RemoteCleanup(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TrackTasks/remote-runs.json"))

    struct Work: Codable, Equatable, Identifiable {
        var server: RemoteServer
        var id: String
        var project: String
        /// Local folder it belongs to.
        var folder: String
        /// Runs whose result wasn't taken.
        var unclaimed: [String] = []
        /// The local folder is gone.
        var orphan = false
    }

    struct Item: Codable, Equatable {
        enum Kind: String, Codable { case stop, rmrun, rmwork }
        var kind: Kind
        var server: RemoteServer
        var project: String
        /// Run or working copy.
        var id: String

        var words: [String] { kind == .stop ? ["stop", id] : [kind.rawValue, id, project] }
    }

    private struct State: Codable, Equatable {
        var works: [Work] = []
        var todo: [Item] = []
    }

    private let url: URL
    private let transport: RemoteTransport
    private let lock = NSLock()
    private var state: State
    private var retryPlanned = false
    private let queue = DispatchQueue(label: "remote.cleanup", qos: .utility)
    private static let retryEvery: TimeInterval = 300

    init(url: URL, transport: RemoteTransport = RemoteTransport()) {
        self.url = url
        self.transport = transport
        state = State()
        switch SafeJSON.load(State.self, from: url) {
        case .missing: break
        case .value(let v): state = v
        case .corrupt, .unreadable: Self.report("Файл \(url.lastPathComponent) (запуски на серверах) не прочитан: незавершённая очистка серверов неизвестна")
        }
        publish()
    }

    var works: [Work] { lock.withLock { state.works } }
    var todo: [Item] { lock.withLock { state.todo } }

    private static func report(_ s: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { StorageIssues.shared.report(s) } }
    }

    private func change(_ body: (inout State) -> Void) {
        lock.withLock {
            let old = state
            body(&state)
            guard state != old else { return }
            do { try SafeJSON.save(JSONEncoder().encode(state), to: url) } catch {
                Self.report("Не удалось записать \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        publish()
    }

    private func publish() {
        let s = lock.withLock { state }
        DispatchQueue.main.async { MainActor.assumeIsolated { RemoteStatus.shared.set(s.todo, s.works) } }
    }

    // MARK: Runs

    /// Before the run may exist on the server.
    func began(_ run: RemoteRun, folder: URL) {
        change { s in
            let i = s.works.firstIndex { $0.id == run.work && $0.server == run.server } ?? {
                s.works.append(Work(server: run.server, id: run.work, project: run.project, folder: folder.path))
                return s.works.count - 1
            }()
            s.works[i].orphan = false
            if !s.works[i].unclaimed.contains(run.id) { s.works[i].unclaimed.append(run.id) }
            s.todo.removeAll { $0.kind == .rmwork && $0.id == run.work }
        }
    }

    /// The result is here: the run's files can go. The working copy stays for the next turn.
    func returned(_ run: RemoteRun) {
        change { s in
            for i in s.works.indices where s.works[i].id == run.work { s.works[i].unclaimed.removeAll { $0 == run.id } }
            s.todo.removeAll { $0.kind == .stop && $0.id == run.id }
            s.todo.append(Item(kind: .rmrun, server: run.server, project: run.project, id: run.id))
            Self.settle(&s)
        }
        kick()
    }

    /// Cancelled without a connection.
    func stopLater(_ run: RemoteRun) {
        change { s in
            let item = Item(kind: .stop, server: run.server, project: run.project, id: run.id)
            if !s.todo.contains(item) { s.todo.append(item) }
        }
        kick()
    }

    // MARK: Working copies

    /// The local folder is deleted.
    func release(folder: URL) { release { $0.folder == folder.path } }
    func release(work: String) { release { $0.id == work } }

    private func release(_ match: (Work) -> Bool) {
        guard works.contains(where: match) else { return }
        change { s in
            for i in s.works.indices where match(s.works[i]) { s.works[i].orphan = true }
            Self.settle(&s)
        }
        kick()
    }

    /// The person gave up the result.
    func discard(_ work: Work) {
        change { s in
            guard let i = s.works.firstIndex(where: { $0.id == work.id && $0.server == work.server }) else { return }
            for r in s.works[i].unclaimed {
                for k in [Item.Kind.stop, .rmrun] where !s.todo.contains(where: { $0.kind == k && $0.id == r }) {
                    s.todo.append(Item(kind: k, server: work.server, project: work.project, id: r))
                }
            }
            s.works[i].unclaimed = []
            s.works[i].orphan = true
            Self.settle(&s)
        }
        kick()
    }

    private static func settle(_ s: inout State) {
        for w in s.works where w.orphan && w.unclaimed.isEmpty {
            s.todo.append(Item(kind: .rmwork, server: w.server, project: w.project, id: w.id))
        }
        s.works.removeAll { $0.orphan && $0.unclaimed.isEmpty }
    }

    // MARK: Network

    func kick() {
        guard !todo.isEmpty else { return }
        queue.async { [self] in pass() }
    }

    private func pass() {
        var unreachable = Set<RemoteServer>()
        for item in todo where !unreachable.contains(item.server) {
            // Dropped meanwhile.
            guard todo.contains(item) else { continue }
            do {
                try RemoteLink(item.server, transport).call(item.words)
                change { s in s.todo.removeAll { $0 == item } }
            } catch let e as RemoteError {
                if case .link = e { unreachable.insert(item.server) }
                Log.queue.process("remote cleanup failed", project: item.server.host, command: item.kind.rawValue)
            } catch {}
        }
        guard !todo.isEmpty else { return }
        let plan = lock.withLock { () -> Bool in
            defer { retryPlanned = true }
            return !retryPlanned
        }
        guard plan else { return }
        queue.asyncAfter(deadline: .now() + Self.retryEvery) { [weak self] in
            guard let self else { return }
            lock.withLock { self.retryPlanned = false }
            pass()
        }
    }
}

/// For the UI.
@Observable @MainActor
final class RemoteStatus {
    static let shared = RemoteStatus()
    private(set) var pendingStops: Set<String> = []
    private(set) var leftovers: [RemoteCleanup.Work] = []
    private(set) var pending = 0

    func set(_ todo: [RemoteCleanup.Item], _ works: [RemoteCleanup.Work]) {
        pendingStops = Set(todo.filter { $0.kind == .stop }.map(\.id))
        pending = todo.count
        leftovers = works.filter { !$0.unclaimed.isEmpty }
    }
}
