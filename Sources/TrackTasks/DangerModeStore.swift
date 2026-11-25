import Foundation
import TrackTasksCore

/// «Опасный режим» of the app: the state on disk, its timer and the only place that turns it on (the window).
@Observable @MainActor
final class DangerModeStore {
    static let shared = DangerModeStore()
    static let oldKey = "jobsAllowAll"
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackTasks/danger-mode.json")
    }

    private(set) var mode: DangerMode
    /// The old global setting is on: ask once. Until answered it gives nothing.
    private(set) var asksAboutOldSetting: Bool
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var timer: Timer?

    private init() {
        let r = DangerMode.load(Self.url)
        mode = r.mode
        asksAboutOldSetting = DangerMode.asksAboutOldSetting(UserDefaults.standard.object(forKey: Self.oldKey))
        if let p = r.problem { StorageIssues.shared.report(p) }
        schedule()
    }

    var active: [String] { mode.active(now: Date()) }
    func isOn(_ project: URL) -> Bool { mode.isOn(project.path, now: Date()) }
    func grant(_ path: String) -> DangerMode.Grant? { mode.grant(path, now: Date()) }

    /// Returns an error text; the mode is on only after the file is written.
    func enable(_ project: Project, typed: String, _ duration: DangerMode.Duration, autopilot: Bool) -> String? {
        let verify = MergeRunner.command(project.url)
        if autopilot, verify.isEmpty { return "Автопилоту нужна проверка: задай verify в about.md" }
        var next = mode
        guard next.enable(project.url.path, name: project.displayName, typed: typed, duration, autopilot: autopilot, verify: verify, now: Date()) else {
            return "Имя проекта не совпадает"
        }
        do { try next.save(Self.url) } catch { return "Не удалось сохранить: \(error.localizedDescription)" }
        mode = next
        changed()
        return nil
    }

    /// Off in memory at once, even if the file can't be written.
    func disable(_ paths: [String]) {
        for p in paths { mode.disable(p) }
        do { try mode.save(Self.url) } catch {
            // An old file must not turn the mode on again after a restart.
            try? FileManager.default.removeItem(at: Self.url)
            StorageIssues.shared.report("Опасный режим выключен, но файл не записан: \(error.localizedDescription)")
        }
        changed()
    }

    func answerOldSetting() {
        UserDefaults.standard.removeObject(forKey: Self.oldKey)
        asksAboutOldSetting = false
    }

    private func changed() {
        schedule()
        onChange?()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let end = mode.nextExpiry(now: Date()) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(end.timeIntervalSinceNow, 0) + 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                self.disable(self.mode.grants.keys.filter { !self.mode.isOn($0, now: now) })
            }
        }
    }
}

extension JobQueue {
    /// The one place that decides what a job may do without asking.
    func allows(_ action: DangerMode.Action, _ job: Job) -> Bool {
        let now = Date(), mode = dangerMode()
        // Only to skip reading the task file when the mode is off; `allows` decides.
        guard mode.isOn(job.cwd.path, now: now) else { return false }
        let folders = folders(job)
        if action == .merge, folders.count > 1 { return false }
        let facts = DangerMode.JobFacts(editsCode: job.isCodeTask, resolvesConflicts: job.resolvesMerge, foreign: isForeign(job), scheduled: isScheduled(job))
        // The job changes all of them: the mode must be on in each.
        return folders.allSatisfy { mode.allows(action, facts, project: $0.path, now: now) }
    }

    /// Outside text in the task, its parent or fork source; a task file that can't be read counts too.
    private func isForeign(_ job: Job) -> Bool { hasForeignSource(job) || hasForeignLog(job) }

    private func hasForeignLog(_ job: Job) -> Bool {
        // Other repositories of a task share its session.
        job.home.foreignLog || self.job(job.parentID)?.foreignLog == true || self.job(job.forkOf)?.foreignLog == true
    }

    func hasForeignSource(_ job: Job) -> Bool {
        if job.foreignSource { return true }
        // Conflicts in the main folder belong to no task.
        if let path = job.taskPath {
            guard let t = Codec.task(at: URL(fileURLWithPath: path)) else { return true }
            if !t.source.isEmpty { return true }
        }
        return self.job(job.parentID)?.foreignSource == true || self.job(job.forkOf)?.foreignSource == true
    }

    /// Work of a schedule: the task, its follow-ups and forks.
    func isScheduled(_ job: Job) -> Bool {
        if job.scheduled || self.job(job.parentID)?.scheduled == true || self.job(job.forkOf)?.scheduled == true { return true }
        return job.taskPath.flatMap { Codec.task(at: URL(fileURLWithPath: $0)) }.map { !$0.automation.isEmpty } ?? false
    }

    /// Fixed when the job is queued, like `foreignSource`; an earlier job of the same task counts too.
    func markScheduled(_ job: Job) {
        if isScheduled(job) || (job.taskPath != nil && jobs.contains { $0.taskPath == job.taskPath && $0.scheduled }) {
            job.scheduled = true
        }
    }

    /// Fixed when the job is queued, so that removing `source:` later changes nothing.
    func markForeign(_ job: Job) {
        let inFile = job.taskPath.flatMap { Codec.task(at: URL(fileURLWithPath: $0)) }.map { !$0.source.isEmpty } ?? false
        if inFile || self.job(job.parentID)?.foreignSource == true || self.job(job.forkOf)?.foreignSource == true {
            job.foreignSource = true
        }
        if hasForeignLog(job) { job.foreignLog = true }
    }

    /// Automatic decisions are visible in the job's log.
    func danger(_ job: Job, _ text: String) { job.log.append("⚙︎ Опасный режим: " + text) }

    /// Unapproved `teardown:` this job may run now, nil = only an approved one.
    func dangerTeardown(_ job: Job) -> String? {
        let cmd = WorktreeScripts.load(projectAt: job.cwd).teardown
        guard !cmd.isEmpty, !ScriptStore.approvals.isApproved(.teardown, cmd, project: job.cwd), allows(.teardown, job) else { return nil }
        danger(job, "teardown без подтверждения: $ \(cmd)")
        return cmd
    }

    /// New code job of a project in the mode: its own worktree. Continued work stays where it was.
    func forcesWorktree(_ job: Job) -> Bool {
        job.kind == .runTask && job.state == .pending && job.worktree == nil && !job.mustUseMain && job.resumeSession == nil && job.rewind == nil && job.limitWait == nil && job.pendingHandoff == nil
            && allows(.worktreeOnDirtyMain, job)
    }

    /// The mode was turned on, off or ran out.
    func dangerChanged() {
        for job in jobs {
            if job.awaitingPlan { autoApprovePlan(job) }
            for r in job.permissions { autoAnswer(job, r) }
        }
        noteOutlived()
        pump()
    }

    /// Running processes keep the flag after the mode ended: say so in their log and offer to stop them.
    @discardableResult
    func noteOutlived() -> [Job] {
        let mode = dangerMode(), now = Date()
        let left = fullAccessRunning.filter { !$0.outlivedNoted && !folders($0).allSatisfy { mode.isOn($0.path, now: now) } }
        guard !left.isEmpty else { return [] }
        for j in left {
            j.outlivedNoted = true
            j.log.append("⚙︎ Опасный режим выключен, но этот запуск идёт с прежними правами до конца. Остановить: «Стоп всё» в очереди или отмена задачи")
        }
        Notifier.shared.post(title: "Опасный режим выключен, задачи ещё идут: \(left.count)",
                             body: left.map(\.title).joined(separator: ", ") + " — с прежними правами. Остановить можно в очереди",
                             jobID: left[0].id)
        return left
    }

    /// Once, never «always»: the rule would stay in the project's settings after the mode.
    @discardableResult
    func autoAnswer(_ job: Job, _ r: PermissionRequest) -> Bool {
        // An agent that can't have full access doesn't get it by automatic answers.
        guard [.runTask, .fix, .review, .reply].contains(job.kind), capabilities(job).contains(.bypass), allows(.answerRequest, job) else { return false }
        danger(job, "разрешено: " + r.title)
        answer(job, r, allow: true)
        return true
    }

    static let planUnchecked = "⚙︎ В папке работала другая задача: проверка «код не изменён» пропущена"

    /// Also when the «code untouched» check was skipped (another job in the folder): with parallel jobs that is
    /// nearly every plan. A plan that did change code fails in `planChecked`.
    func autoApprovePlan(_ job: Job) {
        // A stop written in a pipeline is the person's own.
        guard job.state == .pending, job.awaitingPlan, job.pipeline == nil, allows(.approvePlan, job) else { return }
        // Read anew: no approval over questions, or when it isn't known whether there are any.
        guard !job.answering, refreshQuestions(job), job.questions?.waits != true else { return }
        danger(job, "план одобрен автоматически")
        approvePlan(job)
    }

    /// One fix per task, only in its own unmerged worktree.
    func autoFix(_ task: Job) {
        guard task.kind == .runTask, task.pipeline == nil, task.verdict == .issues, !task.reviewFixed, !task.autoFixUsed, !task.merged,
              task.worktree != nil, !task.review.isEmpty, !task.worktreeBusy, !task.hasLivePR, !onAutopilot(task), allows(.autoFix, task) else { return }
        task.autoFixUsed = true
        danger(task, "исправление замечаний ревью (один раз)")
        requestFix(task)
    }

    /// Includes unapproved `setup:` (its worktree has no session yet).
    var fullAccessRunning: [Job] { jobs.filter { $0.state == .running && ($0.fullAccess || $0.settingUp) } }

    /// Kills full-access runs together with the commands they started.
    func stopFullAccess() {
        for j in fullAccessRunning {
            j.log.append("⚙︎ Остановлено: выключен опасный режим")
            j.proc?.killTree()
            cancel(j)
        }
    }

    /// Stopped by the limit, they would go on by themselves after the pause.
    func cancelLimitWaits(_ mode: DangerMode, now: Date) {
        for j in jobs where j.limitWait != nil && folders(j).allSatisfy({ mode.isOn($0.path, now: now) }) { cancel(j) }
    }

    func dangerStopAll() {
        paused = true
        // Planning and review have no flag, but their requests were answered: stop every run of these projects.
        let mode = DangerModeStore.shared.mode, now = Date()
        let running = jobs.filter { $0.state == .running && folders($0).allSatisfy { mode.isOn($0.path, now: now) } }
        cancelLimitWaits(mode, now: now)
        // Stopped right below: no need to offer it.
        for j in fullAccessRunning { j.outlivedNoted = true }
        for j in allMembers where j.mergePhase != nil && mode.isOn(j.cwd.path, now: now) { cancelMerge(j) }
        DangerModeStore.shared.disable(Array(DangerModeStore.shared.mode.grants.keys))
        stopFullAccess()
        for j in running where !j.fullAccess && !j.settingUp {
            j.log.append("⚙︎ Остановлено: выключен опасный режим")
            j.proc?.killTree()
            cancel(j)
        }
        save()
    }
}
