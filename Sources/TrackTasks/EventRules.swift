import AppKit
import TrackTasksCore

/// Receives events (webhook, GitHub, git) for rules `automations/*.md` with `on:` and creates tasks.
@Observable @MainActor
final class EventRules {
    nonisolated static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackTasks/events.json")
    }
    nonisolated static let service = "TrackTasks.events"
    static let enabledKey = "events.server", portKey = "events.port"
    static let defaultPort = 47824

    /// Secrets of rules: Keychain, in tests a dictionary. Called off the main thread.
    struct Secrets: Sendable {
        var get: @Sendable (String) -> String = { Keychain.get(service: EventRules.service, account: $0) }
        var set: @Sendable (String, String) -> Bool = { Keychain.set(service: EventRules.service, account: $0, $1) }
    }
    enum Reject: String, CaseIterable { case signature = "подпись", replay = "повтор", limit = "частота", other = "прочее" }
    enum ServerState: Equatable { case off, starting, on(UInt16), failed(String) }

    private(set) var state: EventState
    /// Why nothing is accepted until a restart.
    private(set) var stopped: String?
    private(set) var saveError: String?
    private(set) var server = ServerState.off
    /// By rule, since the app started; `nil` key = unknown address. Not on disk: a stranger must not be able to fill it.
    private(set) var rejected: [String?: [Reject: Int]] = [:]
    /// Rules whose secret was read and is there / is not.
    private(set) var secretKnown: [String: Bool] = [:]

    @ObservationIgnored private let jobs: JobQueue
    @ObservationIgnored private let projects: () -> [Project]
    @ObservationIgnored private let ensureGit: (String) -> String?
    @ObservationIgnored private let adopt: (TaskItem, String) -> Void
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let secretStore: Secrets
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let usesServer: Bool
    @ObservationIgnored private var listener: EventServer?
    /// By rule address id.
    @ObservationIgnored private var secrets: [String: String] = [:]
    @ObservationIgnored private var loading = Set<String>()
    /// Accepted work goes one by one: the second request sees the task of the first.
    @ObservationIgnored private var line: Task<Void, Never>?
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var startedOnce = false
    /// Rule files whose refs still have to be compared after the app started or the rule appeared.
    @ObservationIgnored private var checkedGit = Set<String>()

    init(jobs: JobQueue, projects: @escaping () -> [Project], ensureGit: @escaping (String) -> String? = { _ in nil },
         adopt: @escaping (TaskItem, String) -> Void = { _, _ in }, storeURL: URL = EventRules.url,
         secretStore: Secrets = Secrets(), now: @escaping () -> Date = { Date() }, usesServer: Bool = true) {
        self.jobs = jobs
        self.projects = projects
        self.ensureGit = ensureGit
        self.adopt = adopt
        self.storeURL = storeURL
        self.secretStore = secretStore
        self.now = now
        self.usesServer = usesServer
        let r = EventState.load(storeURL)
        state = r.state
        stopped = r.problem
        if let p = r.problem { StorageIssues.shared.report(p) }
    }

    // MARK: Files and secrets

    func refreshSoon() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    /// Notes the files as they are: addresses, secrets of active rules, first look at git.
    func refresh() {
        guard stopped == nil else { return }
        let all = projects()
        var seen = state
        for p in all { seen.observe(p.eventRules, project: p.url) }
        guard seen == state || persist(seen) else { return }
        for r in all.flatMap(\.eventRules) where r.isActive && r.isRemote { loadSecret(r) }
        let git = all.filter { $0.eventRules.contains { $0.isActive && $0.kind == .git } }
        let ids = Set(all.flatMap(\.eventRules).filter { $0.isActive && $0.kind == .git }.map(\.id))
        for p in git where p.eventRules.contains(where: { ids.contains($0.id) && !checkedGit.contains($0.id) }) { gitChanged(p.id) }
        checkedGit = ids
        if usesServer, !startedOnce {
            startedOnce = true
            if UserDefaults.standard.bool(forKey: Self.enabledKey) { startServer() }
        }
    }

    func loadSecret(_ r: EventRule, again: Bool = false) {
        guard let id = state.entries[r.id]?.id, again || secrets[id] == nil, loading.insert(id).inserted else { return }
        let store = secretStore
        Task {
            let s = await Self.offMain { store.get(id) }
            loading.remove(id)
            // A secret set meanwhile is newer.
            if secrets[id, default: ""].isEmpty { secrets[id] = s }
            secretKnown[r.id] = secrets[id]?.isEmpty == false
        }
    }

    /// May wait for a person at a system prompt: not on the cooperative pool.
    nonisolated private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) } }
    }

    /// A new secret, returned once to be shown.
    func renewSecret(_ r: EventRule) async -> Result<String, EventError> {
        if let stopped { return .failure(EventError(text: stopped)) }
        guard let id = state.entries[r.id]?.id else { return .failure(EventError(text: "Правило ещё не прочитано")) }
        guard loading.insert(id).inserted else { return .failure(EventError(text: "Секрет уже читается или меняется")) }
        defer { loading.remove(id) }
        let new = EventSignature.random(bytes: 32), store = secretStore
        // Neither the old nor the new one works while it is being changed.
        secrets[id] = ""
        secretKnown[r.id] = false
        guard await Self.offMain({ store.set(id, new) }) else {
            let old = await Self.offMain { store.get(id) }
            secrets[id] = old
            secretKnown[r.id] = !old.isEmpty
            return .failure(EventError(text: "Keychain не записал секрет, прежний не изменён"))
        }
        var next = state
        next.secretChanged(r.id)
        guard persist(next) else { return .failure(EventError(text: saveError ?? "состояние не записано")) }
        secrets[id] = new
        secretKnown[r.id] = true
        return .success(new)
    }

    struct EventError: Error { var text: String }

    @discardableResult
    private func persist(_ new: EventState) -> Bool {
        do {
            if let stopped { throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: stopped]) }
            try new.save(storeURL)
            state = new
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            StorageIssues.shared.report("События не принимаются, \(storeURL.lastPathComponent) не записан: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Server

    var port: Int {
        let p = UserDefaults.standard.integer(forKey: Self.portKey)
        return (1024...65535).contains(p) ? p : Self.defaultPort
    }

    func address(_ r: EventRule) -> String? {
        guard r.isRemote, let id = state.entries[r.id]?.id else { return nil }
        return "http://127.0.0.1:\(port)/hook/\(id)"
    }

    func setServer(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { startServer() } else { stopServer() }
    }

    func setPort(_ p: Int) {
        UserDefaults.standard.set(p, forKey: Self.portKey)
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { startServer() }
    }

    private func stopServer() {
        listener?.stop()
        listener = nil
        server = .off
    }

    private func startServer() {
        stopServer()
        server = .starting
        let s = EventServer { [weak self] r in await self?.handle(r) ?? EventResponse(503, "приложение закрывается") }
        listener = s
        s.start(port: UInt16(port)) { [weak self, weak s] st in
            Task { @MainActor in
                guard let self, let s, self.listener === s else { return }
                switch st {
                case .ready(let p): self.server = .on(p)
                case .failed(let why): self.server = .failed(why)
                }
            }
        }
    }

    // MARK: Accepting

    private func reject(_ rule: String?, _ why: Reject, _ r: EventResponse) -> EventResponse {
        rejected[rule, default: [:]][why, default: 0] += 1
        return r
    }

    private func find(_ id: String) -> (EventRule, Project)? {
        guard let key = state.entries.first(where: { $0.value.id == id })?.key else { return nil }
        for p in projects() { if let r = p.eventRules.first(where: { $0.id == key && $0.isRemote }) { return (r, p) } }
        return nil
    }

    func handle(_ q: EventRequest) async -> EventResponse {
        if stopped != nil { return EventResponse(503, "события не принимаются") }
        guard let (shown, project) = find(q.id) else { return reject(nil, .signature, .denied) }
        guard let secret = secrets[q.id] else {
            return loading.contains(q.id) ? EventResponse(503, "секрет ещё читается") : reject(shown.id, .signature, .denied)
        }
        // The signature first: before parsing and before any reading from disk.
        let replay: EventState.Replay
        if shown.kind == .github {
            guard EventSignature.github(q.headers["x-hub-signature-256"], body: q.body, secret: secret) else { return reject(shown.id, .signature, .denied) }
            replay = .body(EventSignature.bodyHash(q.body))
        } else {
            guard let s = EventSignature.webhook(time: q.headers["x-tracktasks-timestamp"], nonce: q.headers["x-tracktasks-nonce"],
                                                 signature: q.headers["x-tracktasks-signature"], body: q.body, secret: secret, now: now())
            else { return reject(shown.id, .signature, .denied) }
            replay = .nonce(s)
        }
        return await inLine {
            let url = shown.url, kind = shown.kind, body = q.body, header = q.headers["x-github-event"]
            let read = await Task.detached(priority: .utility) { () -> (EventRule, Project, EventPayload.Outcome)? in
                guard let r = EventRule.read(url), r.isActive, r.kind == kind else { return nil }
                return (r, Codec.project(at: project.url, category: project.category), EventPayload.parse(body, header: header, rule: r))
            }.value
            guard self.secrets[q.id] == secret else { return self.reject(shown.id, .signature, .denied) }
            guard let (rule, fresh, outcome) = read else {
                return self.reject(shown.id, .other, EventResponse(403, "правило выключено или с ошибкой"))
            }
            switch outcome {
            case .bad(let why): return self.reject(shown.id, .other, EventResponse(400, why))
            case .ignore(let why): return EventResponse(202, "пропущено: \(why)")
            case .accept(let p): return await self.accept(rule, fresh, p, replay)
            }
        }
    }

    private func inLine<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let before = line
        let task = Task { @MainActor in
            await before?.value
            return await work()
        }
        line = Task { _ = await task.value }
        return await task.value
    }

    /// Check, remember, create, queue; one event at a time (`inLine`).
    private func accept(_ r: EventRule, _ p: Project, _ payload: EventPayload, _ replay: EventState.Replay) async -> EventResponse {
        let moment = now()
        var next = state
        let rec: UUID
        switch next.accept(r, replay, now: moment) {
        case .ok(let id): rec = id
        case .replay: return reject(r.id, .replay, EventResponse(409, "повтор"))
        case .limit: return reject(r.id, .limit, EventResponse(429, "слишком часто"))
        case .full: return reject(r.id, .other, EventResponse(503, "журнал повторов заполнен: смени секрет правила"))
        }
        // Before the task: a crash loses an event and never repeats it.
        guard persist(next) else { return EventResponse(503, "состояние не записано") }

        let allowed = state.mayQueue(r)
        var why = !r.queue || allowed ? "" : "очередь не разрешена в окне «Расписания»"
        if allowed, let busy = jobs.unfinished(file: r.fileName, past: Set(state.entries[r.id]?.history.compactMap(\.task) ?? []), in: p) {
            why = busy
        }
        let draft = !allowed || !why.isEmpty
        let dir = (draft ? TaskFolder.drafts : .active).url(in: p.tasksURL)
        let f = DateFormatter()
        f.calendar = Automations.localCalendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        let item = EventTask.make(r, payload, stamp: f.string(from: moment), created: Automation.Rule.dayKey(moment, Automations.localCalendar),
                                  source: state.source(r), dod: p.dod, in: dir)
        let task: TaskItem
        switch await TaskWrites.run({ try TaskFile.create(item, in: dir).item }) {
        case .success(let t): task = t
        case .failure(let e):
            finish(r, rec, .failed, "задача не создана: \(TaskFile.message(e))", nil)
            return EventResponse(500, "задача не создана")
        }
        adopt(task, p.id)
        guard !draft else {
            finish(r, rec, .draft, why, task)
            return EventResponse(202, "черновик создан")
        }
        // The permission could be taken back while the file was written.
        guard state.mayQueue(r) else {
            finish(r, rec, .created, "очередь не разрешена в окне «Расписания»", task)
            return EventResponse(202, "задача создана")
        }
        var queued = p
        queued.tasks.append(task)
        switch jobs.tryEnqueue([task], project: queued, confirmed: false, autoDependencies: false, ensureGit: ensureGit) {
        case .queued(let added) where !added.isEmpty: finish(r, rec, .queued, "", task)
        case .queued: finish(r, rec, .created, "в очередь не поставлена", task)
        case .needsDependencies: finish(r, rec, .created, "в очередь не поставлена: есть невыполненные зависимости", task)
        case .failed(let m): finish(r, rec, .created, "в очередь не поставлена: \(m)", task)
        }
        return EventResponse(202, "задача создана")
    }

    private func finish(_ r: EventRule, _ rec: UUID, _ outcome: EventState.Record.Outcome, _ note: String, _ task: TaskItem?) {
        var next = state
        next.finish(r.id, rec, outcome, note: note, task: task?.fileName)
        persist(next)
    }

    // MARK: Git

    /// `.git` of a project changed. Git runs only when the project has a rule for it.
    func gitChanged(_ projectID: String) {
        guard stopped == nil, let p = projects().first(where: { $0.id == projectID }) else { return }
        for r in p.eventRules where r.isActive && r.kind == .git { Task { await checkGit(r, in: p) } }
    }

    func checkGit(_ shown: EventRule, in project: Project) async {
        await inLine {
            let before = self.state.entries[shown.id]?.refs
            let url = shown.url
            let read = await Task.detached(priority: .utility) { () -> (EventRule, Project, GitEvents.Change)? in
                guard let r = EventRule.read(url), r.isActive, r.kind == .git,
                      let c = GitEvents.change(in: project.url, branches: r.branches, before: before) else { return nil }
                return (r, Codec.project(at: project.url, category: project.category), c)
            }.value
            // Switched off and on meanwhile: the look taken is of no use.
            guard let (rule, fresh, change) = read, let entry = self.state.entries[rule.id],
                  entry.refs == before, entry.branches == rule.branches else { return }
            if let payload = change.payload {
                _ = await self.accept(rule, fresh, payload, .refs(change.refs))
            } else if change.refs != before {
                var next = self.state
                next.entries[rule.id]?.refs = change.refs
                self.persist(next)
            }
        }
    }

    // MARK: The person's decisions (the window only)

    /// Allows queueing for the text that was shown; a file changed since is refused.
    func allowQueue(_ shown: EventRule) -> String? {
        guard let r = EventRule.read(shown.url), r.fingerprint == shown.fingerprint else { return "Файл изменился — прочитай его заново" }
        guard r.errors.isEmpty, r.queue else { return "В файле нет queue: true или есть ошибки" }
        guard state.entries[r.id] != nil else { return saveError ?? stopped ?? "Правило ещё не прочитано" }
        var next = state
        next.allow(r, true)
        return persist(next) ? nil : saveError
    }

    func forbidQueue(_ r: EventRule) -> String? {
        var next = state
        next.allow(r, false)
        return persist(next) ? nil : saveError
    }

    /// Writes `enabled:`, unless the file changed since it was shown.
    func setEnabled(_ shown: EventRule, _ on: Bool) async -> String? {
        let r = await TaskWrites.run { () -> String? in
            let file = try TaskFile(reading: shown.url)
            let r = EventRule.parse(file.text, url: shown.url)
            guard r.fingerprint == shown.fingerprint else { return "Файл изменился — прочитай его заново" }
            guard !on || r.errors.isEmpty else { return r.errors.joined(separator: "; ") }
            try file.write(Frontmatter.setting("enabled", to: on ? "true" : "false", in: file.text))
            return nil
        }
        switch r {
        case .success(let why): return why
        case .failure(let e): return TaskFile.message(e)
        }
    }

    func create(title: String, kind: EventRule.Kind, in project: Project) async -> String? {
        let dir = Automation.dir(in: project.url)
        let r = await TaskWrites.run { _ = try TaskFile.create(text: EventRule.template(title: title, kind: kind), slugOf: title, in: dir) }
        if case .failure(let e) = r { return TaskFile.message(e) }
        return nil
    }
}
