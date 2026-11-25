import AppKit
import TrackTasksCore

/// Carries out `tt queue` requests. Every operation checks and changes the queue in one go on the main actor,
/// so clients take turns. Only what `QueueOp` lists: no approvals, no merging.
@MainActor
final class QueueServer {
    static let shared = QueueServer()
    private var server: QueueSocketServer?
    private weak var store: Store?

    func start(_ store: Store) {
        guard server == nil else { return }
        self.store = store
        let s = QueueSocketServer(url: QueueSocket.defaultURL) { r in QueueServer.handle(r) }
        server = s
        do { try s.start() } catch {
            let text = (error as? QueueFailure)?.message ?? error.localizedDescription
            Log.queue.logger.info("tt queue server: \(text, privacy: .public)")
            StorageIssues.shared.report("Команды tt queue недоступны: \(text)")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            s.stop()
        }
    }

    /// On a connection's thread: the disk is read here, the queue is touched on the main actor.
    nonisolated private static func handle(_ r: QueueRequest) -> QueueResponse {
        do {
            var fresh: Project?
            if r.op == .add {
                // From disk: the task may have been created a moment ago, before FSEvents told the app.
                let known = try onMain { try $0.knownProject(r.project ?? "") }
                fresh = Codec.project(at: known.url, category: known.category)
            }
            return try onMain { try $0.perform(r, project: fresh) }
        } catch {
            return QueueResponse(error: error as? QueueFailure ?? QueueFailure(.io, error.localizedDescription))
        }
    }

    nonisolated private static func onMain<T: Sendable>(_ body: @MainActor (Store) throws -> T) throws -> T {
        try DispatchQueue.main.sync {
            try MainActor.assumeIsolated {
                guard let store = QueueServer.shared.store else { throw QueueFailure(.unavailable, "приложение закрывается") }
                return try body(store)
            }
        }
    }
}

extension Store {
    func knownProject(_ path: String) throws -> Project {
        guard projectsLoaded else { throw QueueFailure(.unavailable, "проекты ещё загружаются, повтори") }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard !path.isEmpty, let p = projects.first(where: { $0.url.resolvingSymlinksInPath().path == real }) else {
            throw QueueFailure(.notFound, "приложение не знает проект \(path)")
        }
        return p
    }

    func perform(_ r: QueueRequest, project: Project?) throws -> QueueResponse {
        switch r.op {
        case .list:
            return QueueResponse(jobs: jobs.jobs.map(queueJob), paused: jobs.paused)
        case .add:
            guard let project else { throw QueueFailure(.usage, "не указан проект") }
            return QueueResponse(jobs: try queueAdd(r.tasks ?? [], project: project, withDeps: r.withDeps == true).map(queueJob))
        case .cancel:
            let job = try queueFind(r.job)
            guard job.isActive else { throw QueueFailure(.conflict, "«\(job.title)» уже не выполняется (\(job.state.rawValue))") }
            jobs.cancel(job)
            return QueueResponse(jobs: [queueJob(job)])
        case .answer:
            let job = try queueFind(r.job)
            if let why = jobs.replyBlocked(job) { throw QueueFailure(.conflict, why) }
            guard jobs.sendReply(job, text: r.text ?? "") else { throw QueueFailure(.usage, "пустое сообщение") }
            return QueueResponse(jobs: [queueJob(job)])
        case .log:
            let job = try queueFind(r.job)
            return QueueResponse(jobs: [queueJob(job)], log: QueueResponse.tail(job.log, r.tail ?? 50))
        case .open:
            mode = .work
            selectedID = Store.queueID
            openMainWindow?()
            NSApp.activate()
            return QueueResponse()
        }
    }

    /// All or nothing: one task that can't be queued rejects the request.
    private func queueAdd(_ names: [String], project: Project, withDeps: Bool) throws -> [Job] {
        guard !names.isEmpty else { throw QueueFailure(.usage, "не указаны задачи") }
        // `project` was read off the main actor: since then a job could finish or a file move away.
        var project = project
        let tasks = try names.map { n in
            let t = try queueReread(n, in: &project)
            if t.status == .done { throw QueueFailure(.conflict, "\(n) уже выполнена") }
            if let j = jobs.blockingJob(forTask: t.id) {
                throw QueueFailure(.conflict, j.isActive ? "\(n) уже в очереди" : "\(n) ждёт слияния")
            }
            return t
        }
        var reread = Set(names)
        var confirmed = false
        while true {
            switch tryEnqueue(tasks, project: project, confirmed: confirmed, autoDependencies: false) {
            case .queued(let added): return added
            case .failed(let m): throw QueueFailure(.invalid, m)
            case .needsDependencies(let extra, _):
                // Fresh copies first: a dependency may be done by now or have got its own `depends:`.
                let stale = extra.map(\.fileName).filter { !reread.contains($0) }
                for n in stale { _ = try queueReread(n, in: &project) }
                reread.formUnion(stale)
                if !stale.isEmpty { continue }
                guard withDeps else {
                    throw QueueFailure(.conflict, "не выполнены и не в очереди зависимости (--with-deps — добавить и их): "
                        + extra.map(\.fileName).joined(separator: ", "))
                }
                confirmed = true
            }
        }
    }

    private func queueReread(_ name: String, in project: inout Project) throws -> TaskItem {
        guard let i = project.tasks.firstIndex(where: { $0.fileName == name }),
              let t = Codec.task(at: project.tasks[i].url) else {
            throw QueueFailure(.notFound, "нет задачи \(name) в проекте \(project.displayName)")
        }
        project.tasks[i] = t
        return t
    }

    private func queueFind(_ ref: String?) throws -> Job {
        // No wait reasons here: they need a planner run each.
        let found = try QueueJob.find(ref ?? "", in: jobs.jobs.map { queueJob($0, reason: false) })
        guard let job = jobs.job(UUID(uuidString: found.id)) else { throw QueueFailure(.notFound, "в очереди нет «\(ref ?? "")»") }
        return job
    }

    private func queueJob(_ j: Job) -> QueueJob { queueJob(j, reason: true) }

    private func queueJob(_ j: Job, reason: Bool) -> QueueJob {
        QueueJob(id: j.id.uuidString, kind: j.kind.rawValue, state: j.state.rawValue, title: j.title,
                 project: j.projectName, projectPath: j.projectID ?? j.cwd.path, taskPath: j.taskPath,
                 lastLine: String(j.lastLine.prefix(300)), waitReason: reason ? jobs.waitReason(j) : "",
                 permissions: j.permissions.count, awaitingPlan: j.awaitingPlan, awaitsMerge: j.awaitsMerge)
    }
}
