import AppKit
import TrackTasksCore

/// Runs schedules (`automations/*.md`): one timer for the nearest moment of all projects, no polling.
@Observable @MainActor
final class Automations {
    nonisolated static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackTasks/automations.json")
    }

    private(set) var state: AutomationState
    /// Why scheduled runs stand still until a restart.
    private(set) var stopped: String?
    /// The state could not be written: nothing runs by schedule until a write succeeds.
    private(set) var saveError: String?
    /// Files being run now.
    private(set) var running = Set<String>()
    /// Planned moment of the timer.
    private(set) var wakeAt: Date?

    @ObservationIgnored private let jobs: JobQueue
    @ObservationIgnored private let projects: () -> [Project]
    @ObservationIgnored private let ensureGit: (String) -> String?
    @ObservationIgnored private let adopt: (TaskItem, String) -> Void
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: () -> Calendar
    @ObservationIgnored private let usesTimer: Bool
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshScheduled = false

    /// `adopt`: a task file was created. Tests pass their own clock and store, and no timer.
    init(jobs: JobQueue, projects: @escaping () -> [Project], ensureGit: @escaping (String) -> String? = { _ in nil },
         adopt: @escaping (TaskItem, String) -> Void = { _, _ in }, storeURL: URL = Automations.url,
         now: @escaping () -> Date = { Date() }, calendar: @escaping () -> Calendar = { Automations.localCalendar },
         usesTimer: Bool = true) {
        self.jobs = jobs
        self.projects = projects
        self.ensureGit = ensureGit
        self.adopt = adopt
        self.storeURL = storeURL
        self.now = now
        self.calendar = calendar
        self.usesTimer = usesTimer
        let r = AutomationState.load(storeURL)
        state = r.state
        stopped = r.problem
        if let p = r.problem { StorageIssues.shared.report(p) }
        if usesTimer { observeClock() }
    }

    /// Dates of schedules are ordinary local ones, whatever calendar the system shows.
    nonisolated static var localCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// A `Timer` doesn't run during sleep and knows nothing about a changed clock.
    private func observeClock() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon() }
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    NSTimeZone.resetSystemTimeZone()
                    self?.refreshSoon()
                }
            }
        }
    }

    // MARK: Planning

    /// Several changes in a row — one pass.
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

    /// Notes the files as they are, starts what is due and sets the timer.
    func refresh() {
        timer?.invalidate()
        timer = nil
        wakeAt = nil
        guard stopped == nil else { return }
        let moment = now(), cal = calendar(), all = projects()
        var seen = state
        for p in all { seen.observe(p.automations, project: p.url, now: moment) }
        guard seen == state || persist(seen) else { return }
        for p in all {
            for a in p.automations where !running.contains(a.id) && state.due(a, now: moment, calendar: cal) != nil {
                Task { await self.run(a, in: p, manual: false) }
            }
        }
        schedule(all, moment, cal)
    }

    private func schedule(_ all: [Project], _ moment: Date, _ cal: Calendar) {
        let active = all.flatMap(\.automations).filter { !running.contains($0.id) }
        guard saveError == nil, let at = active.compactMap({ state.next($0, now: moment, calendar: cal) }).min() else { return }
        wakeAt = at
        guard usesTimer else { return }
        let t = Timer(timeInterval: max(at.timeIntervalSince(moment), 0) + 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func next(_ a: Automation) -> Date? {
        stopped == nil ? state.next(a, now: now(), calendar: calendar()) : nil
    }

    /// Memory follows the file: what is not written did not happen.
    @discardableResult
    private func persist(_ new: AutomationState) -> Bool {
        do {
            // A file of another version, or one that could not be read, is not replaced.
            if let stopped { throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: stopped]) }
            try new.save(storeURL)
            state = new
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            StorageIssues.shared.report("Расписания остановлены, \(storeURL.lastPathComponent) не записан: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Running

    /// One run; returns an error text when nothing was recorded. `manual` works for a switched off schedule too
    /// and takes no slot. The file is read again: what is on disk now decides, not what the list shows.
    @discardableResult
    func run(_ shown: Automation, in project: Project, manual: Bool) async -> String? {
        guard running.insert(shown.id).inserted else { return "Уже запускается" }
        // A run that could not take its slot is still due: starting it again at once would spin.
        // The next file, clock or wake event tries again.
        var settled = manual
        defer {
            running.remove(shown.id)
            if settled { refreshSoon() }
        }
        let url = shown.url, projectURL = project.url, category = project.category
        let (found, fresh) = await Task.detached(priority: .utility) {
            (Automation.read(url), Codec.project(at: projectURL, category: category))
        }.value
        guard let a = found else { return "Файл \(shown.fileName) не прочитан" }
        guard a.errors.isEmpty else { return a.errors.joined(separator: "; ") }
        let moment = now(), cal = calendar()
        var slot: Date?
        var next = state
        if !manual {
            guard stopped == nil else { return stopped }
            next.observe([a], project: projectURL, now: moment)
            // `observe` of one file says nothing about its neighbours.
            for (k, e) in state.entries where k != a.id { next.entries[k] = e }
            slot = next.due(a, now: moment, calendar: cal)
            if slot == nil {
                // Switched off or changed meanwhile; keep what was noticed.
                settled = next == state || persist(next)
                return nil
            }
        }
        let run = next.begin(a, slot: slot, now: moment, calendar: cal)
        // Before the task: a crash loses a run and never repeats it.
        guard persist(next) else { return saveError }
        settled = true

        if let why = jobs.unfinished(file: a.fileName, past: Set(state.entries[a.id]?.history.compactMap(\.task) ?? []), in: fresh) { return finish(a, run, .skipped, why) }
        let stamp = DateFormatter()
        stamp.calendar = cal
        stamp.timeZone = cal.timeZone
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = manual ? "dd.MM.yyyy HH:mm" : "dd.MM.yyyy"
        let item = a.task(stamp: stamp.string(from: slot ?? moment), created: Automation.Rule.dayKey(moment, cal),
                          dod: fresh.dod, in: fresh.tasksURL)
        let task: TaskItem
        let dir = fresh.tasksURL
        switch await TaskWrites.run({ try TaskFile.create(item, in: dir).item }) {
        case .success(let t): task = t
        case .failure(let e): return finish(a, run, .failed, "задача не создана: \(TaskFile.message(e))")
        }
        adopt(task, fresh.id)
        guard a.queue else { return finish(a, run, .created, "", task) }
        guard state.mayQueue(a) else { return finish(a, run, .created, "очередь не разрешена в окне «Расписания»", task) }
        var queued = fresh
        queued.tasks.append(task)
        switch jobs.tryEnqueue([task], project: queued, confirmed: false, autoDependencies: false, ensureGit: ensureGit) {
        case .queued(let added) where !added.isEmpty: return finish(a, run, .queued, "", task)
        case .queued: return finish(a, run, .created, "в очередь не поставлена", task)
        case .needsDependencies: return finish(a, run, .created, "в очередь не поставлена: есть невыполненные зависимости", task)
        case .failed(let m): return finish(a, run, .created, "в очередь не поставлена: \(m)", task)
        }
    }

    private func finish(_ a: Automation, _ run: UUID, _ outcome: AutomationState.Run.Outcome, _ note: String,
                        _ task: TaskItem? = nil) -> String? {
        var next = state
        next.finish(a.id, run, outcome, note: note, task: task?.fileName)
        persist(next)
        return outcome == .skipped || outcome == .failed ? note : nil
    }

    // MARK: The person's decisions (the window only)

    /// Allows queueing for the text that was shown; a file changed since is refused.
    func allowQueue(_ shown: Automation) -> String? {
        guard let a = Automation.read(shown.url), a.fingerprint == shown.fingerprint else { return "Файл изменился — прочитай его заново" }
        guard a.errors.isEmpty, a.queue else { return "В файле нет queue: true или есть ошибки" }
        var next = state
        next.allow(a, true, now: now())
        return persist(next) ? nil : saveError
    }

    func forbidQueue(_ a: Automation) -> String? {
        var next = state
        next.allow(a, false, now: now())
        return persist(next) ? nil : saveError
    }

    /// Writes `enabled:`, unless the file changed since it was shown.
    func setEnabled(_ shown: Automation, _ on: Bool) async -> String? {
        let r = await TaskWrites.run { () -> String? in
            let file = try TaskFile(reading: shown.url)
            let a = Automation.parse(file.text, url: shown.url)
            guard a.fingerprint == shown.fingerprint else { return "Файл изменился — прочитай его заново" }
            guard !on || a.errors.isEmpty else { return a.errors.joined(separator: "; ") }
            try file.write(Frontmatter.setting("enabled", to: on ? "true" : "false", in: file.text))
            return nil
        }
        switch r {
        case .success(let why): return why
        case .failure(let e): return TaskFile.message(e)
        }
    }

    func create(title: String, in project: Project) async -> String? {
        let dir = Automation.dir(in: project.url)
        let r = await TaskWrites.run { _ = try TaskFile.create(text: Automation.template(title: title), slugOf: title, in: dir) }
        if case .failure(let e) = r { return TaskFile.message(e) }
        return nil
    }
}

extension JobQueue {
    /// The previous work of an automation is not over: by the task's `automation:` and by its history
    /// (the line could be removed from the file).
    func unfinished(file: String, past: Set<String>, in p: Project) -> String? {
        for t in p.allTasks where t.automation == file || past.contains(t.fileName) {
            // The queue remembers the path the task was queued with.
            let original = p.tasksURL.appendingPathComponent(t.fileName).path
            if let why = moveBlocked(forTask: t.id) ?? moveBlocked(forTask: original) { return "«\(t.title)»: \(why)" }
            if t.folder == .active, t.status != .done { return "«\(t.title)» ещё не закрыта" }
        }
        return nil
    }
}
