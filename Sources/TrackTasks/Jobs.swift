import Foundation
import TrackTasksCore

// MARK: - Queue

@Observable @MainActor
final class JobQueue {
    var jobs: [Job] = []
    /// Manual pause (Queue → «Пауза»).
    var paused: Bool {
        didSet {
            if storeURL == Self.storeURL { UserDefaults.standard.set(paused, forKey: "queuePaused") }
            updateSleepGuard()
            if paused { updateHoldTimer() } else { pump() }
        }
    }
    @ObservationIgnored var onStarted: ((Job) -> Void)?
    @ObservationIgnored var onFinished: ((Job) -> Void)?
    @ObservationIgnored var onMerged: ((Job) -> Void)?
    @ObservationIgnored private var saveScheduled = false
    /// False until the sessions of earlier runs are known.
    @ObservationIgnored private var ready = false
    /// Only while a limit holds the queue or a job waits for its reset. No git.
    @ObservationIgnored private(set) var holdTimer: Timer?

    nonisolated static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackTasks/queue.json")
    }

    @ObservationIgnored let agents: AgentRegistry
    @ObservationIgnored let profiles: () -> AgentProfiles
    @ObservationIgnored let recordSpend: @MainActor (AgentRunResult, _ project: String, _ kind: String, _ task: SpendTask?) -> Void
    @ObservationIgnored let dangerMode: @MainActor () -> DangerMode
    @ObservationIgnored let questionNotice: @MainActor (Job) -> Void
    @ObservationIgnored private let storeURL: URL
    var queueFile: URL { storeURL }
    var isReady: Bool { ready }
    @ObservationIgnored let taskVerifyStore: TaskVerifyStore
    /// `repos:` may lead only inside it.
    @ObservationIgnored let projectsRoot: () -> URL
    @ObservationIgnored let worktreesRoot: URL
    /// Cleanup of worktrees (`JobQueue+Cleanup`).
    @ObservationIgnored let snapshots: WorktreeSnapshots
    /// Worktrees kept by the person; nil = not known.
    var pinnedWorktrees: Set<String>?
    @ObservationIgnored let pinsURL: URL
    /// false: the list of jobs is not what it was, so any worktree may belong to a lost one.
    @ObservationIgnored private(set) var queueRead = true
    /// Worktrees without a task: merged or removed now.
    var busyOrphans = Set<String>()
    var cleaning = false
    /// Result of the last automatic cleanup.
    var cleanupNote = ""
    /// Couldn't be removed: not tried again by itself until restart.
    @ObservationIgnored var cleanupFailed: [String: String] = [:]
    @ObservationIgnored var cleanupTimer: Timer?

    /// nil = `executor: docker` is refused: Docker isn't set up in Settings.
    var docker: DockerHost? { dockerHost() }
    @ObservationIgnored private let dockerHost: @MainActor () -> DockerHost?

    @ObservationIgnored let limits: @MainActor () -> Limits.Snapshot
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored let drafts: DiffDrafts
    @ObservationIgnored let previews: PreviewDrafts

    /// Log of a failed check, only if it belongs to the commit; tests give their own.
    @ObservationIgnored var ciLog: @Sendable (CIFix.JobRef, _ commit: String, _ dir: URL) -> Result<String, CIFixError> = GitHubCLI.ciLog
    @ObservationIgnored var ciAutoFix: @MainActor (URL) -> Bool = { CIFixStore.shared.isOn($0) }
    /// Tasks whose logs are being collected automatically.
    @ObservationIgnored var ciFixing = Set<UUID>()

    /// Tests pass their own agents and store.
    init(storeURL: URL = JobQueue.storeURL, agents: AgentRegistry? = nil,
         profiles: @escaping () -> AgentProfiles = { AgentProfileStore.current },
         docker: DockerHost? = nil, dockerHost: (@MainActor () -> DockerHost?)? = nil,
         dangerMode: @escaping @MainActor () -> DangerMode = { DangerModeStore.shared.mode },
         taskVerifyStore: TaskVerifyStore = .shared,
         projectsRoot: @escaping () -> URL = { Store.savedRoot }, worktreesRoot: URL? = nil,
         limits: @escaping @MainActor () -> Limits.Snapshot = { Limits.shared.snapshot }, now: @escaping () -> Date = { Date() },
         drafts: DiffDrafts? = nil, previews: PreviewDrafts? = nil,
         questionNotice: @escaping @MainActor (Job) -> Void = { JobQueue.postQuestionNotice($0) },
         recordSpend: @escaping @MainActor (AgentRunResult, String, String, SpendTask?) -> Void = { Spend.shared.add($0, project: $1, kind: $2, task: $3) }) {
        self.storeURL = storeURL
        self.taskVerifyStore = taskVerifyStore
        self.projectsRoot = projectsRoot
        // A queue with its own store (tests) must not leave worktrees among the real ones.
        self.worktreesRoot = worktreesRoot ?? (storeURL == Self.storeURL ? Worktrees.root : storeURL.deletingLastPathComponent().appendingPathComponent("worktrees", isDirectory: true))
        let dir = storeURL.deletingLastPathComponent()
        snapshots = WorktreeSnapshots(folder: dir.appendingPathComponent("worktree-snapshots", isDirectory: true))
        pinsURL = dir.appendingPathComponent("worktree-cleanup.json")
        self.limits = limits
        self.now = now
        self.drafts = drafts ?? .shared
        self.previews = previews ?? .shared
        self.agents = agents ?? .standard
        self.profiles = profiles
        self.recordSpend = recordSpend
        self.questionNotice = questionNotice
        self.dangerMode = dangerMode
        self.dockerHost = dockerHost ?? { docker }
        // The pause is app-wide state: a queue with its own store neither reads nor changes it.
        paused = storeURL == Self.storeURL && UserDefaults.standard.bool(forKey: "queuePaused")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        pinnedWorktrees = Self.loadPins(pinsURL)
        let removing = returnWorktrees()
        let hadFile = FileManager.default.fileExists(atPath: storeURL.path)
        if let recs = StorageIssues.shared.load([JobRecord].self, from: storeURL, decoder: dec) {
            jobs = recs.map(Job.init)
            forgetRemoved(removing)
            for j in jobs where !j.repos.isEmpty && j.parts.isEmpty { resolveRepos(j) }
            restoreReplies()
            recoverMerges()
        } else if hadFile {
            queueRead = false
        }
        finishCleanups(removing)
        // No periodic polling: pump runs on events — job added/finished, pause off, git changes in a project
        // (`gitChanged`, from Store's FSEvents), limit updates; a timer only while a limit holds something.
        Terminals.shared.onUsed = { [weak self] in self?.save() }
        Limits.shared.onUpdate = { [weak self] in self?.limitsUpdated() }
        if storeURL == Self.storeURL { DangerModeStore.shared.onChange = { [weak self] in self?.dangerChanged() } }
        let begin: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.ready = true
            // Everything was merged, but the app closed before the rest of the group was removed.
            for j in self.jobs where j.members.contains(where: \.merged) && !j.parts.isEmpty { Task { await self.closeGroup(j) } }
            self.restoreQuestions()
            self.refreshTaskChecks()
            // Plans that waited before the restart.
            for job in self.jobs where job.awaitingPlan { self.autoApprovePlan(job) }
            self.pump()
            // Drafts of tasks whose worktree is gone can't be sent.
            if storeURL == Self.storeURL, self.trustsQueue { self.previews.sweep(keep: Set(self.jobs.filter { $0.worktree != nil }.map(\.id))) }
            if storeURL == Self.storeURL { self.scheduleCleanup() }
        }
        // Claude in tmux outlives the app: nothing starts or merges until it is known where.
        if storeURL == Self.storeURL { Terminals.shared.restore({ [weak self] in self?.jobs ?? [] }, then: begin) }
        else { DispatchQueue.main.async { MainActor.assumeIsolated { begin() } } }
    }

    var activeCount: Int { jobs.filter(\.isActive).count }
    var runningCount: Int { jobs.filter { $0.state == .running }.count }
    var waitingApproval: Int { jobs.reduce(0) { $0 + $1.permissions.count } }

    func job(_ id: UUID?) -> Job? {
        guard let id else { return nil }
        return jobs.first { $0.id == id }
    }

    /// Every queue state change ends in `save()`, so the sleep guard follows the queue from there.
    func updateSleepGuard() {
        SleepGuard.shared.update(busy: !paused && runningCount > 0)
    }

    func save() {
        updateSleepGuard()
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.saveScheduled else { return }
                self.saveNow()
            }
        }
    }

    /// Writes the queue at once: what it says must not be lost (a run on a server).
    @discardableResult
    func saveNow() -> Bool {
        saveScheduled = false
        // Keep all active jobs and the latest 100 finished ones.
        let finishedIDs = Set(self.jobs.filter { !$0.isActive }.suffix(100).map(\.id))
        let keep = self.jobs.filter { $0.isActive || finishedIDs.contains($0.id) || $0.hasWorktree || $0.remoteUnclaimed || ($0.state == .done && $0.pipelineOpen)
            || !$0.replyDraft.isEmpty || self.hasActiveChild($0)
            // Its tmux session would lose its card.
            || Terminals.shared.tabs($0).contains(where: \.isRunning) }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        do { return StorageIssues.shared.save(try enc.encode(keep.map(\.record)), to: self.storeURL) }
        catch {
            StorageIssues.shared.report("Не удалось закодировать очередь: \(error.localizedDescription)")
            return false
        }
    }

    func answer(_ job: Job, _ r: PermissionRequest, allow: Bool, always: Bool = false) {
        job.proc?.respond(r, allow: allow, always: always)
        job.permissions.removeAll { $0.id == r.id }
        job.log.append("⚙︎ " + (allow ? (always ? "Разрешено всегда: " : "Разрешено: ") : "Отклонено: ") + r.title)
        Notifier.shared.clear(id: r.id)
    }

    func answer(requestID: String, allow: Bool) {
        for j in jobs {
            if let r = j.permissions.first(where: { $0.id == requestID }) { answer(j, r, allow: allow); return }
        }
    }

    func add(_ job: Job) {
        markForeign(job)
        markScheduled(job)
        markTaskVerify(job)
        resolveRepos(job)
        markExecutor(job)
        // A fix continues its task's files.
        if job.files.isEmpty, let p = job.taskPath { job.files = jobs.last { $0.taskPath == p }?.files ?? [] }
        jobs.append(job)
        refreshTaskCheck(job)
        save()
        pump()
    }

    func job(forTask path: String) -> Job? {
        jobs.last { $0.taskPath == path && $0.isActive && $0.kind == .runTask }
    }

    /// Task job that is still in progress or done but not merged yet — dependents must wait for it.
    func blockingJob(forTask path: String) -> Job? {
        jobs.last { $0.taskPath == path && $0.kind == .runTask && ($0.isActive || ($0.state == .done && ($0.awaitsMerge || $0.pipelineOpen || awaitsAnswers($0)))) }
    }

    /// Why the task file can't be moved to the archive or drafts now, nil — it can.
    func moveBlocked(forTask path: String) -> String? {
        if jobs.contains(where: { $0.taskPath == path && $0.isActive }) { return "задача в очереди Claude" }
        if jobs.contains(where: { $0.taskPath == path && $0.state == .done && $0.pipelineOpen }) { return Self.pipelineUnfinished }
        if jobs.contains(where: { $0.taskPath == path && $0.awaitsMerge }) { return "ветка задачи ещё не слита" }
        return nil
    }

    func cancel(_ job: Job) {
        switch job.state {
        case .pending where job.limitWait != nil:
            // Its work has begun: ends like a running one.
            job.limitWait = nil
            job.lastLine = "Отменено во время ожидания лимита"
            finish(job, .cancelled)
        case .pending:
            if handoffNotStarted(job, "передача отменена") { return }
            job.state = .cancelled
            job.finishedAt = Date()
            settleReply(job)
            save()
            pump()
        case .running:
            if job.settingUp {
                job.settingUp = false
                job.setupRun = nil
                job.setupProcess?.kill()
                job.setupProcess = nil
                job.state = .cancelled
                job.finishedAt = Date()
                job.log.append("⚙︎ Setup отменён")
                if handoffNotStarted(job, "передача отменена") { return }
                if job.worktree != nil, job.handoffs.isEmpty {
                    Terminals.shared.closeAll(job.id)
                    dropWorktrees(job)
                    job.baseCommit = ""
                }
                save()
                pump()
            } else if job.proc == nil, job.planPhase == .planning || job.guardsReview, job.planBaseline == nil {
                // Still taking the code snapshot before the run.
                job.state = .cancelled
                job.finishedAt = Date()
                if job.pipeline != nil { pipelineStepEnded(job, .cancelled, changed: false, commitError: nil) }
                save()
                pump()
            } else if job.checkpointing {
                job.cancelRequested = true
            } else if job.verifying {
                job.cancelRequested = true
                job.verifyProcess?.kill()
            } else {
                job.stopAsked = true
                job.proc?.stop()
            }
        default:
            break
        }
    }

    func clearFinished() {
        // Keep finished jobs that still own a worktree — the branch needs a decision — and ones whose
        // reply/review/fix is still going.
        let busy = Set(jobs.filter(\.isActive).compactMap(\.parentID))
        // A card with live terminal processes stays: they are closed only by the user.
        jobs.removeAll { j in
            guard !j.isActive, !(j.state == .done && j.pipelineOpen), !j.remoteUnclaimed || j.merged, j.isGroup ? !j.hasWorktree : j.worktree == nil || j.merged, !busy.contains(j.id),
                  !Terminals.shared.tabs(j).contains(where: \.isRunning), !Terminals.shared.claudeRunning(j) else { return false }
            Terminals.shared.closeAll(j.id)
            previews.remove(j.id)
            // A plan or review made without a worktree: its copy on the server isn't needed.
            if !j.hadWorktree, j.parentID == nil, let r = j.remote { RemoteCleanup.shared.release(work: r.work) }
            return true
        }
        save()
    }

    /// Re-run a failed/interrupted/cancelled job; continues its claude session when there is one.
    func retry(_ old: Job) {
        // Replies are repeated from their task's history; a task is not restarted under a running reply.
        guard old.kind != .reply, !old.answering, !old.worktreeBusy, !hasActiveChild(old) else { return }
        // A step is repeated by its pipeline; only its result left on a server is taken by the job itself.
        if !old.pipelineStep.isEmpty {
            guard let task = job(old.parentID) else { return }
            guard old.remoteUnclaimed else { return pipelineRepeat(task) }
            guard !task.isActive, !task.worktreeBusy, !hasActiveChild(task) else { return }
        }
        let j = Job(kind: old.kind, title: old.title, projectID: old.projectID, projectName: old.projectName,
                    cwd: old.cwd, prompt: old.prompt, systemPrompt: old.systemPrompt, taskPath: old.taskPath)
        j.verifyCommand = old.verifyCommand
        j.taskVerify = old.taskVerify
        j.evidenceAsked = old.evidenceAsked
        j.parentID = old.parentID
        j.mustUseMain = old.mustUseMain
        j.alwaysWorktree = old.alwaysWorktree
        j.files = old.files
        j.repos = old.repos
        j.targetRepo = old.targetRepo
        j.planPhase = old.planPhase
        j.planFeedback = old.planFeedback
        j.questions = old.questions
        j.questions?.sending = nil
        j.foreignSource = old.foreignSource
        j.foreignLog = old.foreignLog
        j.ciFixTries = old.ciFixTries
        j.scheduled = old.scheduled
        j.autoFixUsed = old.autoFixUsed
        j.limitRetried = old.limitRetried
        j.resolvesMerge = old.resolvesMerge
        j.fixesMergeCheck = old.fixesMergeCheck
        let s = old.sessionID ?? old.resumeSession
        let oldDir = old.runDir
        // Also a finished run: its working copy on the server is used again.
        j.remote = old.remote
        if old.remoteUnclaimed {
            // The run is still on the server: continue watching it, whatever state the job is in.
            j.sessionID = old.sessionID
            j.model = old.model
            old.moveWorktrees(to: j)
            j.hadWorktree = old.hadWorktree
            j.verifyAttempts = old.verifyAttempts
            j.committed = old.committed
        } else if s != nil || old.rewind != nil, old.interrupted || old.state == .cancelled {
            // A rolled back conversation continues from its point, not from the end of the old session.
            if let r = old.rewind { j.rewind = r } else { j.resumeSession = s }
            j.rolledBack = old.rolledBack
            j.rollbackNotice = old.rollbackNotice
            old.moveWorktrees(to: j)
        } else if old.kind == .runTask, old.alwaysWorktree, old.interrupted, let w = old.worktree,
                  FileManager.default.fileExists(atPath: w.path.path) {
            // The app closed before the session id was known: the work is still in this worktree.
            old.moveWorktrees(to: j)
        } else if old.kind == .runTask, !old.handoffs.isEmpty, old.runsInPlace {
            // Another agent's work is there too; the last one continues its session, if it has one.
            if old.state != .done { j.resumeSession = s }
            old.moveWorktrees(to: j)
        } else if old.kind == .fix {
            j.worktree = old.worktree
            j.baseCommit = old.baseCommit
        }
        if !old.handoffs.isEmpty { keepHandoffs(old, j) }
        if let s = old.pipeline { retryPipeline(s, old, j) }
        if j.worktree != nil || old.parentID != nil { j.executor = old.executor }
        // A session belongs to its agent; a fresh start may take a corrected `agent:`.
        if j.remoteUnclaimed || j.resumeSession != nil || j.rewind != nil || old.parentID != nil || !j.handoffs.isEmpty {
            j.useAgent(of: old)
        } else if j.pipeline != nil {
            j.profile = old.profile
        } else {
            let t = old.kind == .runTask ? old.taskPath.flatMap { Codec.task(at: URL(fileURLWithPath: $0)) } : nil
            j.profile = t?.agent ?? old.profile
            if t?.mainFolderOnly == true { j.mustUseMain = true }
            // The list may have been corrected.
            if let t, j.parts.isEmpty { j.repos = t.repos }
        }
        if let s = j.pipeline {
            if s.status == .ready { pipelineEvent(j, .begin) }
            else if s.gate?.kind == .trouble { pipelineEvent(j, j.remoteUnclaimed ? .reattach : .userRepeat) }
        }
        reattachStep(old, j)
        j.replies = old.replies
        j.replyDraft = old.replyDraft
        for c in jobs where c.parentID == old.id { c.parentID = j.id }
        previews.move(from: old.id, to: j.id)
        j.terminalUsed = old.terminalUsed && j.worktree != nil
        Terminals.shared.move(from: oldDir, old, to: j)
        jobs.removeAll { $0 === old }
        add(j)
    }

    var restarting = false
    /// The app is about to restart for an update (not saved, unlike the pause): nothing new starts.
    @ObservationIgnored var frozen = false {
        didSet { if oldValue, !frozen { pump() } }
    }
    @ObservationIgnored var autopiloting = false
    /// Project folders where the autopilot is merging.
    var autoMerging = Set<String>()
    /// Project folders where the user's git operation goes (`JobQueue+Git`).
    var gitBusy = Set<String>()
    /// Merged by the autopilot since the last report, by project.
    @ObservationIgnored var autoReport: [String: [String]] = [:]

    /// Jobs «Перезапустить» can run again. Unfinished: failed or cancelled. Finished tasks: only without
    /// a worktree — unmerged work would be lost.
    func restartable(includingDone: Bool) -> [Job] {
        var seen = Set<String>()
        return Array(jobs.reversed().filter { j in
            guard j.parentID == nil, j.kind != .reply, !j.worktreeBusy, !hasActiveChild(j), !j.hasLivePR else { return false }
            guard let path = j.taskPath else { return j.state == .failed || j.state == .cancelled }
            // Only the latest job of a task decides.
            guard seen.insert(path).inserted, blockingJob(forTask: path) == nil,
                  FileManager.default.fileExists(atPath: path) else { return false }
            switch j.state {
            case .failed, .cancelled: return true
            case .done: return includingDone && j.kind == .runTask && !j.hasWorktree
            case .pending, .running: return false
            }
        }.reversed())
    }

    /// Runs them again in the old order, with their dependencies and waves.
    func restart(includingDone: Bool) {
        let olds = restartable(includingDone: includingDone)
        restarting = true
        var new: [UUID: UUID] = [:]
        for old in olds {
            let wasDone = old.state == .done
            // A finished task starts anew, not from its old session.
            if wasDone { old.interrupted = false }
            retry(old)
            guard let j = jobs.last, !jobs.contains(where: { $0 === old }) else { continue }
            new[old.id] = j.id
            j.dependsOn = old.dependsOn
            j.wave = old.wave
            j.waveCount = old.waveCount
            j.wavePriority = old.wavePriority
            if wasDone {
                j.autoFixUsed = false
                if old.planPhase != nil, old.pipeline == nil { j.planPhase = .planning }
            }
        }
        for j in jobs { j.dependsOn = j.dependsOn.map { new[$0] ?? $0 } }
        restarting = false
        save()
        pump()
    }

    static let parallelKey = "jobsParallel"
    static let parallelRange = 1...16
    static let limitGuardKey = "limitGuard"
    static let fiveHourGuardKey = "fiveHourGuard"

    /// How many jobs of one lane may run at once (Settings → «Параллельно»).
    static var parallelLimit: Int {
        let v = UserDefaults.standard.integer(forKey: parallelKey)
        return v == 0 ? 3 : min(max(v, parallelRange.lowerBound), parallelRange.upperBound)
    }

    /// Pause when less than this % of the weekly limit is left (0 = off).
    static var limitGuard: Int {
        UserDefaults.standard.object(forKey: limitGuardKey) as? Int ?? 10
    }

    /// The same for the five-hour window.
    static var fiveHourGuard: Int { UserDefaults.standard.integer(forKey: fiveHourGuardKey) }

    /// Non-nil when a limit holds the queue.
    var limitHold: String? {
        let s = limits()
        return weeklyHold(s.weekly) ?? fiveHourHold(s.fiveHour)
    }

    private func fiveHourHold(_ w: Limits.Window?) -> String? {
        // Without a known reset the queue would wait for nothing.
        guard let w, let reset = w.knownReset, reset > now() else { return nil }
        let when = LimitWait.clock(reset, now: now())
        // Also with the guard off: every next job would only waste its start.
        if w.status == "rejected" { return "Лимит 5 часов исчерпан. Продолжу после сброса в \(when)." }
        let g = Self.fiveHourGuard, left = Int(((1 - w.utilization) * 100).rounded())
        guard g > 0, left < g else { return nil }
        return "Осталось \(max(0, left))% лимита 5 часов (порог \(g)%). Продолжу после сброса в \(when)."
    }

    private func weeklyHold(_ w: Limits.Window?) -> String? {
        let g = Self.limitGuard
        guard g > 0, let w else { return nil }
        let left = Int(((1 - w.utilization) * 100).rounded())
        guard left < g else { return nil }
        return "Осталось \(left)% недельного лимита (порог \(g)%). Продолжу после сброса \(Limits.resetText(w.resetsAt))."
    }

    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var pumpAgain = false
    /// Back-to-back git snapshots redone because the queue changed meanwhile (see `pumpSnapshotReady`).
    @ObservationIgnored private var pumpRecollects = 0
    private static let maxPumpRecollects = 2
    /// Jobs whose worktree is being created in the background: count as running for the planner.
    private(set) var creatingWorktree = Set<UUID>()
    @ObservationIgnored private var holdWasActive = false
    /// The nearest reset a job waits for.
    @ObservationIgnored private var nextReset: Date?
    /// Folders without git or commits, as of the last git snapshot.
    @ObservationIgnored private var noCommits = Set<String>()

    /// Snapshot of the queue for `QueuePlanner`.
    private var plannerJobs: [QueuePlanner.Job] {
        jobs.map { j in
            var state: QueuePlanner.State = switch j.state {
            case .pending: .pending
            case .running: .running
            case .done: .done
            case .failed: .failed
            case .cancelled: .cancelled
            }
            let creating = state == .pending && creatingWorktree.contains(j.id)
            if creating { state = .running }
            let force = !creating && j.state == .pending && forcesWorktree(j)
            // Continued work of the main folder stays there; only a new task is moved to a worktree.
            let needs = requiresWorktree(j)
            let newTask = j.kind == .runTask && j.resumeSession == nil && j.rewind == nil && j.limitWait == nil && j.pendingHandoff == nil
            var p = QueuePlanner.Job(
                id: j.id, title: j.title, state: state, lane: j.lane == .code ? .code : .light,
                cwd: j.cwd.path, worktree: j.worktree?.path.path, creatingWorktree: creating, depends: j.dependsOn,
                awaitsMerge: j.awaitsMerge || (j.state == .done && j.pipelineOpen),
                mustUseMain: j.mustUseMain || (j.limitWait != nil && j.worktree == nil) || (j.alwaysWorktree && !needs && !newTask && j.worktree == nil),
                worktreeUnavailable: j.worktreeUnavailable, allowDirtyMain: j.allowDirtyMain,
                dirtyMain: j.dirtyMain, wave: j.wave, wavePriority: j.wavePriority?.rawValue,
                awaitingPlan: j.awaitingPlan, forceWorktree: force,
                doneInMain: j.finishedInMain,
                guardedLimit: spendsGuardedLimit(j))
            p.awaitsAnswers = awaitsAnswers(j)
            p.alwaysWorktree = j.alwaysWorktree && newTask
            p.limitWait = j.limitWait != nil
            if let w = j.limitWait, !w.isDue(now()) { p.limitUntil = w.resetsAt }
            p.agentWorktree = needs
            p.realCwd = j.realCwd
            let g = group(j)
            p.extraFolders = g.parts.isEmpty ? (g === j ? j.repoFolders.map(\.path) : []) : g.parts.filter { $0.worktree != nil }.map(\.cwd.path)
            p.pipelineStop = pipelineHold(j)
            // A branch belongs to its task: a finished fix doesn't stand for it.
            p.files = j.kind == .runTask || j.isActive ? j.files : []
            p.ignoresFiles = j.allowSameFiles || !newTask
            p.priority = (j.taskPriority ?? .medium).rank
            return p
        }
    }

    private func plannerSettings(dirty: [String: [String]]? = nil) -> QueuePlanner.Settings {
        var s = QueuePlanner.Settings(limit: Self.parallelLimit, paused: paused, hold: limitHold,
                                      worktreesEnabled: Worktrees.enabled, dirtyFiles: dirty)
        s.noCommits = noCommits
        s.gitBusy = Set(gitBusy.isEmpty ? [] : jobs.flatMap { [$0.cwd] + $0.repoFolders }.filter { gitBusy(around: $0) }.map(\.path))
        return s
    }

    /// `files:` was edited: the queue follows the task file, also for running and unmerged jobs.
    func syncFiles(_ projects: [Project]) {
        guard jobs.contains(where: { $0.taskPath != nil }) else { return }
        var changed = false
        for p in projects {
            let mine = jobs.filter { $0.projectID == p.id && $0.taskPath != nil }
            guard !mine.isEmpty else { continue }
            let files = Dictionary(p.tasks.map { ($0.id, $0.files) }, uniquingKeysWith: { a, _ in a })
            for j in mine {
                guard let f = files[j.taskPath!], f != j.files else { continue }
                j.files = f
                changed = true
            }
        }
        refreshTaskChecks()
        if changed { pump() }
    }

    /// Waits for a job that changes the same files: the user may start it anyway.
    func waitsForFiles(_ job: Job) -> Bool {
        guard job.state == .pending, !job.files.isEmpty, !job.allowSameFiles, !creatingWorktree.contains(job.id) else { return false }
        if case .wait(.files)? = QueuePlanner.decide(jobs: plannerJobs, settings: plannerSettings())[job.id] { return true }
        return false
    }

    func runDespiteSameFiles(_ job: Job) {
        guard job.state == .pending else { return }
        job.allowSameFiles = true
        pump()
    }

    /// `worktree: always` was switched in about.md: jobs not started yet follow it.
    func syncAlwaysWorktree(_ projects: [Project]) {
        var changed = false
        for p in projects {
            for j in jobs where j.state == .pending && j.kind == .runTask && j.projectID == p.id
                && j.alwaysWorktree != p.alwaysWorktree {
                j.alwaysWorktree = p.alwaysWorktree
                changed = true
            }
        }
        if changed { pump() }
    }

    /// `worktree: always`, but no worktree can be made: the user may send the job to the main folder.
    func lacksRequiredWorktree(_ job: Job) -> Bool {
        guard job.state == .pending, job.alwaysWorktree, !Worktrees.enabled || job.worktreeUnavailable,
              !creatingWorktree.contains(job.id) else { return false }
        if case .wait(.alwaysWorktree)? = QueuePlanner.decide(jobs: plannerJobs, settings: plannerSettings())[job.id] { return true }
        return false
    }

    /// git changed in a project folder (commit, merge, checkout, edited files) — FSEvents via Store, debounced.
    /// Only jobs waiting in that folder can be unblocked by it.
    func gitChanged(_ path: String) {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        settlePRs(in: p)
        let real = TaskRepos.canonical(URL(fileURLWithPath: path))
        guard jobs.contains(where: { j in
            j.state == .pending && (j.cwd.standardizedFileURL.path == p || j.repoFolders.contains { $0.path == real })
        }) else { return }
        pump()
    }

    /// Limits changed: pump only when the guard switched on or off (updates come with every Claude event).
    private func limitsUpdated() {
        if (limitHold != nil) != holdWasActive { pump() }
    }

    /// Carry out `QueuePlanner` decisions: start jobs (in a new worktree when the main folder is busy),
    /// cancel broken chains, remember uncommitted files that hold a job back. All choosing is in the planner.
    /// No git on the main actor: uncommitted files are collected in the background first (only for folders
    /// that may need them), worktrees are created in the background too.
    func pump() {
        // «Перезапустить» puts several jobs back: dependencies are set only after all of them are in.
        guard !restarting, !frozen, ready || storeURL != Self.storeURL else { return }
        settlePipelines()
        if !paused { autopilot() }
        guard !pumping else { pumpAgain = true; return }
        guard !paused else { updateHoldTimer(); save(); return }
        let cwds = QueuePlanner.dirtyCandidates(jobs: plannerJobs, settings: plannerSettings())
        guard !cwds.isEmpty else { return carryOut(dirty: [:]) }
        let withFiles = Set(jobs.filter { $0.state == .pending && !$0.files.isEmpty }.map(\.cwd.path))
        pumping = true
        Task.detached(priority: .utility) { [weak self] in
            var snap: [String: [String]] = [:]
            var bare = Set<String>()
            for c in cwds {
                let url = URL(fileURLWithPath: c)
                snap[c] = Worktrees.dirtyFiles(in: url, projectRelative: withFiles.contains(c))
                if !Worktrees.hasCommits(url) { bare.insert(c) }
            }
            let ready = snap, noCommits = bare
            await self?.pumpSnapshotReady(ready, noCommits: noCommits)
        }
    }

    private func pumpSnapshotReady(_ snap: [String: [String]], noCommits bare: Set<String>) {
        pumping = false
        noCommits = noCommits.subtracting(snap.keys).union(bare)
        if paused { pumpRecollects = 0; pumpAgain = false; return pump() }
        // The queue changed while git ran and now needs a folder that isn't in the snapshot: collect again,
        // but only a couple of times in a row — a constantly changing queue mustn't loop git. Folders still
        // missing then fall back to the job's last known `dirtyMain` (the planner handles that).
        let fresh = QueuePlanner.dirtyCandidates(jobs: plannerJobs, settings: plannerSettings()).isSubset(of: snap.keys)
        if !fresh, pumpRecollects < Self.maxPumpRecollects {
            pumpRecollects += 1
            pumpAgain = false
            return pump()
        }
        pumpRecollects = 0
        carryOut(dirty: snap)
    }

    private func carryOut(dirty: [String: [String]]) {
        // Frozen while git ran; the thaw pumps again.
        guard !frozen else { pumping = false; return }
        pumping = true
        let span = Log.queue.begin("pump", "\(jobs.count) jobs")
        defer {
            Log.queue.end("pump", span)
            pumping = false
            updateHoldTimer()
            save()
            if pumpAgain { pumpAgain = false; pump() }
        }
        for job in jobs where job.state == .pending && !job.repoProblem.isEmpty && !creatingWorktree.contains(job.id) {
            if handoffNotStarted(job, job.repoProblem) { continue }
            job.state = .failed
            job.finishedAt = Date()
            job.lastLine = "Не запущено: " + job.repoProblem
            onFinished?(job)
        }
        let snapshot = plannerJobs
        let counts = QueuePlanner.unblockCounts(jobs: snapshot).filter { $0.value > 0 }
        if counts != unblockCounts { unblockCounts = counts }
        let decisions = QueuePlanner.decide(jobs: snapshot, settings: plannerSettings(dirty: dirty))
        for job in jobs where job.state == .pending && !creatingWorktree.contains(job.id) {
            if case .start? = decisions[job.id], failIfTaskMoved(job) { continue }
            if case .needWorktree? = decisions[job.id], failIfTaskMoved(job) { continue }
            if reposChanged(job, decisions[job.id]) { continue }
            switch decisions[job.id] {
            case .start:
                if !job.dirtyMain.isEmpty { job.dirtyMain = [] }
                start(job)
            case .needWorktree:
                createWorktree(job)
            case .cancel(let line):
                if handoffNotStarted(job, line) { continue }
                job.state = .cancelled
                job.finishedAt = Date()
                job.lastLine = line
            case .wait(.sameFolder(.dirtyMain(let files))):
                if job.dirtyMain != files { job.dirtyMain = files }
            case .wait(.files):
                if !job.dirtyMain.isEmpty { job.dirtyMain = [] }
            case .wait, nil:
                break
            }
        }
    }

    /// The task file went to the archive or drafts (retry of an old job, or moved by hand): nothing to run.
    private func failIfTaskMoved(_ job: Job) -> Bool {
        guard job.kind == .runTask, let path = job.taskPath, !FileManager.default.fileExists(atPath: path) else { return false }
        let url = URL(fileURLWithPath: path)
        guard let folder = [TaskFolder.archive, .drafts].first(where: {
            FileManager.default.fileExists(atPath: $0.url(in: url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent).path)
        }) else { return false }
        if handoffNotStarted(job, "задача в разделе «\(folder.title)»") { return true }
        job.state = .failed
        job.finishedAt = Date()
        job.lastLine = "Не запущено: задача в разделе «\(folder.title)»"
        // Its dependents are cancelled by the next pass.
        pumpAgain = true
        return true
    }

    /// `repos:` was edited since the job was queued: decide again about the new folders.
    private func reposChanged(_ job: Job, _ d: QueuePlanner.Decision?) -> Bool {
        guard job.kind == .runTask, job.worktree == nil, job.forkOf == nil, d == .start || d == .needWorktree,
              let t = job.taskPath.flatMap({ Codec.task(at: URL(fileURLWithPath: $0)) }), t.repos != job.repos else { return false }
        job.repos = t.repos
        resolveRepos(job)
        pumpAgain = true
        return true
    }

    /// `git worktree add` in the background; the job holds its slot meanwhile.
    private func createWorktree(_ job: Job) {
        creatingWorktree.insert(job.id)
        job.lastLine = "Создаю worktree…"
        let cwd = job.cwd, title = job.title, id = job.id, container = job.executor == .docker, wtRoot = worktreesRoot
        if !job.repos.isEmpty {
            let repos = job.repos, expected = job.repoFolders, root = projectsRoot()
            Task.detached(priority: .userInitiated) { [weak self] in
                let made = Self.makeGroup(cwd: cwd, title: title, id: id, repos: repos, expected: expected, projectsRoot: root, worktrees: wtRoot)
                await self?.groupCreated(job, made)
            }
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let made = Worktrees.create(for: cwd, title: title, jobID: id, root: wtRoot, container: container)
            let dirty = made == nil ? 0 : Worktrees.dirtyFiles(in: cwd).count
            await self?.worktreeCreated(job, made, dirty: dirty)
        }
    }

    private func groupCreated(_ job: Job, _ result: Result<[MadeWorktree], TaskRepos.Failure>) {
        creatingWorktree.remove(job.id)
        if job.lastLine == "Создаю worktree…" { job.lastLine = "" }
        switch result {
        case .failure(let f):
            guard job.state == .pending else { return pump() }
            job.state = .failed
            job.finishedAt = Date()
            job.lastLine = f.message
            onFinished?(job)
            return pump()
        case .success(let made):
            guard job.state == .pending, !paused else {
                Task.detached(priority: .utility) {
                    for m in made { Worktrees.remove(m.info, deleteBranch: true, force: true, scripts: false) }
                }
                return pump()
            }
            job.worktree = made[0].info
            job.baseCommit = made[0].base
            job.parts = []
            for m in made.dropFirst() { _ = job.addPart(main: m.info.main, worktree: m.info, base: m.base) }
            if !job.dirtyMain.isEmpty { job.dirtyMain = [] }
            start(job)
            save()
            pump()
        }
    }

    private func worktreeCreated(_ job: Job, _ made: (Worktrees.Info, base: String)?, dirty: Int) {
        creatingWorktree.remove(job.id)
        if job.lastLine == "Создаю worktree…" { job.lastLine = "" }
        guard let (w, base) = made else {
            // The planner counted this job as running; decide again without a worktree.
            job.worktreeUnavailable = true
            return pump()
        }
        guard job.state == .pending, !paused else {
            // Cancelled or paused meanwhile: drop the unused worktree, a later start makes a fresh one.
            let wt = w
            Task.detached(priority: .utility) { Worktrees.remove(wt, deleteBranch: true, force: true) }
            return pump()
        }
        if dirty > 0, forcesWorktree(job), !requiresWorktree(job) {
            job.worktreeNote = "От коммита \(base.prefix(8)); в основной папке незакоммичено файлов: \(dirty), сюда они не попали"
            danger(job, "worktree от \(base.prefix(8)), незакоммиченное в основной папке (\(dirty)) не тронуто")
        }
        job.worktree = w
        job.baseCommit = base
        for warning in Worktrees.fileWarnings(of: w.path) { job.log.append("⚠︎ Файлы worktree: " + warning) }
        if !job.dirtyMain.isEmpty { job.dirtyMain = [] }
        start(job)
        save()
        pump()
    }

    /// While a limit holds the queue or a job, look every minute whether it has reset (that comes without an event).
    private func updateHoldTimer() {
        let t = now()
        nextReset = jobs.compactMap { $0.state == .pending ? $0.limitWait : nil }.filter { !$0.isDue(t) }.map(\.resetsAt).min()
        let held = !paused && (limitHold != nil || nextReset != nil)
        holdWasActive = limitHold != nil
        if held, holdTimer == nil {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdTick() }
            }
        } else if !held, let t = holdTimer {
            t.invalidate()
            holdTimer = nil
        }
    }

    /// `pump` may run git: only when something has changed.
    func holdTick() {
        let due = nextReset.map { now() >= $0.addingTimeInterval(LimitWait.grace) } ?? false
        if due || (limitHold != nil) != holdWasActive { pump() } else { updateHoldTimer() }
    }

    /// Why a pending job hasn't started yet — from the same planner as `pump`.
    func waitReason(_ job: Job) -> String {
        guard job.state == .pending else { return "" }
        if creatingWorktree.contains(job.id) { return "создаётся worktree…" }
        switch QueuePlanner.decide(jobs: plannerJobs, settings: plannerSettings())[job.id] {
        case .wait(let r): return r.text
        case .start, .needWorktree: return "запускается…"
        case .cancel(let line): return line
        case nil: return ""
        }
    }

    /// How many unfinished jobs wait for each pending job; refreshed by `pump` (every queue change), so a card only looks it up.
    private(set) var unblockCounts: [UUID: Int] = [:]

    func unblocks(_ job: Job) -> Int { job.state == .pending ? unblockCounts[job.id] ?? 0 : 0 }

    /// «Слить все» is running (`mergeAll`).
    var mergeBatch: MergeBatch?
    /// Result of the last one, shown until closed.
    var lastMergeBatch: MergeBatch?
    @ObservationIgnored var lastPRRefresh = Date.distantPast
    /// Rare poll while a pull request is open; nil = none is.
    @ObservationIgnored var prPoll: Task<Void, Never>?
}
