import Foundation
import TrackTasksCore

extension JobQueue {
    // MARK: Worktree actions

    /// Waiting for a commit in main: start in a worktree anyway (uncommitted changes won't be there).
    func runDespiteDirtyMain(_ job: Job) {
        guard job.state == .pending else { return }
        job.allowDirtyMain = true
        job.dirtyMain = []
        pump()
    }

    /// Waiting for a commit in main: wait for the main folder instead (sees uncommitted changes).
    func runInMainFolder(_ job: Job) {
        guard job.state == .pending, job.worktree == nil, job.repos.isEmpty, !requiresWorktree(job) else { return }
        job.mustUseMain = true
        job.dirtyMain = []
        pump()
    }

    /// Merge a finished worktree job into the project's current branch: main is merged into the branch in its worktree,
    /// `verify` runs there, and only the checked result gets into the main folder (`SafeMerge`).
    /// Unless `force`, stops when the branch touches files with uncommitted changes in main:
    /// sets `mergeOverlap` — the UI shows the list and asks. `force` confirms exactly the files that were shown.
    /// `redCI`: the user confirmed the merge despite red CI (`force` comes after that question).
    /// A task on several repositories: all of them, one by one; `single` — only the given one.
    func merge(_ job: Job, force: Bool = false, redCI: Bool = false, single: Bool = false) {
        Task {
            if single || job.parts.isEmpty { await mergeNow(job, force: force, redCI: redCI, ask: true) }
            else { await mergeGroup(job, ask: true) }
        }
    }

    /// Not atomic: each repository is merged on its own, what is merged stays merged. A question or an error stops
    /// only its repository. Bulk (`ask: false`) skips the ones known not to merge. True = nothing is left to merge.
    @discardableResult
    func mergeGroup(_ job: Job, ask: Bool) async -> Bool {
        guard !job.parts.isEmpty else { return await mergeNow(job, ask: ask) }
        for m in job.members where m.ownAwaitsMerge && (ask || canMerge(m)) {
            await mergeNow(m, ask: ask)
            if m.mergeStopped { break }
        }
        return !job.awaitsMerge
    }

    /// Every branch of the queue: a task on several repositories has one in each.
    var allMembers: [Job] { jobs.flatMap(\.members) }

    /// Nothing known about the branch stops its merge.
    private func canMerge(_ m: Job) -> Bool {
        m.ownAwaitsMerge && m.rolledBack.isEmpty && !m.mergeFailed && !m.hasLivePR && m.mergeCheck?.state != .red
    }

    static let pipelineUnfinished = "пайплайн не завершён"

    /// Why the branch can't be merged now, apart from what git says.
    private func mergeBlocked(_ job: Job) -> String? {
        if gitBusy(around: job.cwd) { return "в основной папке идёт операция git" }
        if job.hasLivePR { return "у ветки есть PR #\(job.pullRequest?.pr.number ?? 0)" }
        // Also reachable from a notification: never remove the folder under a running reply/fix/review.
        if hasActiveChild(job) { return "в ветке ещё идёт ответ, ревью, исправление или Claude в терминале карточки" }
        if job.isGroup, job.home.isActive { return "задача ещё выполняется" }
        if !job.rolledBack.isEmpty { return Self.uncommittedRollback }
        if job.pipelineOpen { return Self.pipelineUnfinished }
        if let r = taskGate(job)?.decide().refusal { return MergeRunner.taskCheckRefused(r) }
        return nil
    }

    /// One merge, awaited — `mergeAll` runs them one by one.
    /// `ask: false` (bulk): an overlap with uncommitted files is reported in the row instead of an alert.
    @discardableResult
    func mergeNow(_ job: Job, force: Bool = false, redCI: Bool = false, ask: Bool = true,
                  automatic: Bool = false) async -> Bool {
        guard let w = job.worktree, !job.worktreeBusy, !job.merged else { return false }
        job.mergeRedCI = false
        job.mergeStopped = false
        // The session of a task on several repositories lives in the project's worktree: it goes last (`closeGroup`).
        let keep = !job.parts.isEmpty
        if let why = mergeBlocked(job) {
            job.worktreeNote = "Не слито: " + why
            refreshTaskCheck(job.home)
            save()
            return false
        }
        let confirmedCI = force || redCI
        if !confirmedCI, let warning = job.pullRequest?.ciWarning {
            job.mergeRedCI = ask
            job.worktreeNote = "Не слито: " + warning
                + (ask ? "" : ". Нажми «Слить» у задачи, чтобы слить всё равно.")
            save()
            return false
        }
        let token = MergeToken()
        job.worktreeBusy = true
        job.mergeOverlap = []
        job.mergeToken = token
        job.mergePhase = .waiting
        job.worktreeNote = ""
        let report = await MergeRunner.run(
            w, known: job.mergeCheck, artifacts: job.mergeArtifacts, allowed: .files(force ? Set(job.mergeOverlapAsked) : []), token: token, task: taskGate(job),
            keep: keep, scripts: job.owner == nil,
            onPhase: { if job.mergeToken === token { job.mergePhase = $0 } },
            mayLand: { [weak self] in
                guard let self else { return "очередь закрыта" }
                // Turned off or paused while the check ran.
                if automatic, self.paused || !self.onAutopilot(job) { return "автопилот выключен" }
                return self.mergeBlocked(job)
            })
        job.worktreeBusy = false
        job.mergeToken = nil
        job.mergePhase = nil
        job.mergeOverlapAsked = []
        job.mergeCheck = report.check
        // The next merge replaces the check: its output stays in the log.
        if report.outcome == .timedOut, let c = report.check {
            job.log.append("⚙︎ ✗ Проверка при слиянии не уложилась в \(Int(Verify.timeout / 60)) мин: \(c.failedCommand)\n" + c.output)
        }
        job.mergeArtifacts = report.artifacts
        // Main is in the branch now: diff, review and PR must show only the task's own changes.
        if let m = report.mergedMain { job.baseCommit = m }
        job.worktreeNote = MergeRunner.text(report)
        job.mainConflict = false
        job.mergeFailed = false
        job.mergeWaits = false
        var ok = false
        switch report.outcome {
        case .merged(_, let note, let markers):
            ok = true
            job.merged = true
            if !keep {
                Terminals.shared.closeAll(job.id)
                job.worktree = nil
                job.mergeArtifacts = []
            }
            if markers {
                Notifier.shared.post(title: "Слито, но есть пересечения", body: "\(job.projectName): поправь маркеры конфликта", jobID: job.home.id)
            } else if note.contains("git stash") {
                Notifier.shared.post(title: "Слито, правки остались в git stash", body: "\(job.projectName): \(job.title)", jobID: job.home.id)
            }
        case .overlap(let files):
            job.mergeWaits = true
            if ask {
                job.mergeOverlapAsked = files
                job.mergeOverlap = files
            } else {
                job.worktreeNote += ". Нажми «Слить» у задачи, чтобы слить всё равно."
            }
        case .conflict:
            job.mergeFailed = true
            if ask { Notifier.shared.post(title: "Конфликт при слиянии", body: "\(job.projectName): \(job.title)", jobID: job.home.id) }
        case .mainConflict:
            job.mainConflict = true
            job.mergeWaits = true
        case .red:
            if ask { Notifier.shared.post(title: "Не слито: проверка красная", body: "\(job.projectName): \(job.title)", jobID: job.home.id) }
        case .timedOut, .moved, .failed:
            if ask { Notifier.shared.post(title: "Не слито", body: "\(job.projectName): \(job.title)", jobID: job.home.id) }
        case .cancelled:
            job.mergeWaits = true
            job.mergeStopped = token.isCancelled
        }
        refreshTaskCheck(job.home)
        // What `taskCheckApproved` promised.
        if ok || report.check?.state == .passed, job.home.verifyNote == Self.taskCheckApproved {
            job.home.verifyNote = ""
            job.home.verifyFailed = false
        }
        save()
        if ok { await closeGroup(job) }
        onMerged?(job)
        pump()
        return ok
    }

    /// Stops a merge; not once main is being moved.
    func cancelMerge(_ job: Job) {
        guard job.mergePhase != .landing else { return }
        job.mergeToken?.cancel()
    }

    /// Merges cut off by the end of the app: finished if main has the commit, otherwise main is untouched.
    func recoverMerges() {
        for j in jobs where j.parentID == nil && !j.isActive {
            let list = j.members.filter { $0.worktree != nil && !$0.merged }
            guard !list.isEmpty else { continue }
            j.worktreeBusy = true
            let sites = list.map { m in (m, m.worktree!, m.mergeArtifacts, keep: !m.parts.isEmpty, own: m.owner == nil) }
            Task { [weak self] in
                for (m, w, artifacts, keep, own) in sites {
                    let (r, left, removed) = await Task.detached(priority: .userInitiated) { () -> (SafeMerge.Recovery?, [String], [String]) in
                        let git: SafeMerge.Runner = DiffLoader.runEnv
                        let r = SafeMerge.recover(w.mergeSite, git: git)
                        var left: [String] = [], removed: [String] = []
                        if case .landed = r, !keep {
                            left = SafeMerge.uncommitted(w.mergeSite, ignoring: artifacts, git: git)
                            if left.isEmpty {
                                removed = SafeMerge.uncommitted(w.mergeSite, git: git)
                                MergeRunner.cleanUp(w, scripts: own)
                            }
                        }
                        return (r, left, removed)
                    }.value
                    self?.mergeRecovered(m, r, left, removed, last: m === list.last)
                }
                await self?.closeGroup(j)
            }
        }
    }

    private func mergeRecovered(_ job: Job, _ r: SafeMerge.Recovery?, _ left: [String], _ removed: [String], last: Bool) {
        // One flag for the whole task (a part's flag is its task's): free after the last repository.
        if last { job.home.worktreeBusy = false }
        let stash: String?
        switch r {
        case nil: return pump()
        case .landed(let s):
            stash = s
            job.merged = true
            if left.isEmpty, job.parts.isEmpty {
                job.worktree = nil
                job.mergeArtifacts = []
            }
            job.worktreeNote = "Слито в основную ветку (приложение закрылось сразу после слияния)"
                + (left.isEmpty ? "" : ". Worktree оставлен: в нём незакоммиченное — \(DirtyFiles.summary(left))")
                + (removed.isEmpty ? "" : ". " + MergeRunner.removed(removed))
        case .landedElsewhere(let branches, let s):
            stash = s
            job.worktreeNote = MergeRunner.elsewhere(branches)
            // Autopilot must not merge it once more, into the branch that happens to be checked out.
            if job.owner == nil, job.kind == .runTask { job.auto.parked = "слито в другую ветку: \(DirtyFiles.summary(branches))" }
        case .interrupted(let s):
            stash = s
            job.worktreeNote = "Слияние прервано закрытием приложения, основная ветка не тронута — слей ещё раз"
        }
        job.worktreeNote += MergeRunner.stashNote(stash)
        save()
        onMerged?(job)
        pump()
    }

    // MARK: Bulk actions (Queue toolbar)

    /// A review, fix or reply is going, or claude is open in the card's terminal (same session and folder).
    func hasActiveChild(_ job: Job) -> Bool {
        let job = job.home
        return jobs.contains { $0.parentID == job.id && $0.isActive } || Terminals.shared.claudeRunning(job)
    }

    /// Done tasks with changes that haven't been reviewed yet.
    var reviewable: [Job] {
        jobs.filter { $0.kind == .runTask && $0.state == .done && !$0.fullyMerged && $0.verdict == nil && !$0.pipelineOpen
            && ($0.hasWorktree || $0.committed) && !hasActiveChild($0) }
    }
    /// Reviewed with remarks and not fixed yet.
    var fixable: [Job] {
        jobs.filter { $0.kind == .runTask && $0.verdict == .issues && !$0.reviewFixed && !$0.fullyMerged && !$0.review.isEmpty && canFix($0) && !$0.pipelineOpen
            && !hasActiveChild($0) }
    }
    /// Branches ready to merge. Skips ones with unfixed review remarks, a red check or a conflict.
    var mergeable: [Job] {
        jobs.filter { $0.awaitsMerge && !$0.pipelineOpen && !$0.worktreeBusy && !$0.isActive && !hasActiveChild($0) && $0.members.contains(where: canMerge)
            && !($0.verdict == .issues && !$0.reviewFixed) }
            .sorted { $0.created < $1.created }
    }
    /// Unmerged branches «Слить все» skips, with the reason.
    var notMergeable: [(job: Job, why: String)] {
        let ready = Set(mergeable.map(\.id))
        return jobs.filter { $0.awaitsMerge && !ready.contains($0.id) && !$0.isFollowUp && $0.kind != .review }.map { j in
            let why: String =
                if hasActiveChild(j) { "идёт ответ, ревью или исправление" }
                else if j.isActive { "задача ещё идёт" }
                else if j.worktreeBusy { "идёт операция с веткой" }
                else if j.pipelineOpen { Self.pipelineUnfinished }
                else if !j.parts.isEmpty, !j.groupSummary.isEmpty { j.groupSummary }
                else if j.hasLivePR { "открыт PR" }
                else if !j.rolledBack.isEmpty { "откат не закоммичен" }
                else if j.mergeFailed { "конфликт с основной веткой" }
                else if j.mergeCheck?.state == .red { "не проходит проверку вместе с основной веткой" }
                else { "замечания ревью не исправлены" }
            return (j, why)
        }
    }
    /// Branches whose merge hit a conflict — Claude merges main into them and resolves.
    var resolvable: [Job] {
        allMembers.filter { $0.mergeFailed && canResolve($0) && $0.worktree != nil && !hasActiveChild($0) }
    }
    /// Projects where an unresolved conflict sits in the main folder (one job per folder).
    var mainConflicts: [Job] {
        var seen = Set<String>()
        return allMembers.filter { $0.mainConflict && $0.worktree != nil && seen.insert($0.cwd.standardizedFileURL.path).inserted }
    }
    var retryable: [Job] { jobs.filter {
        $0.kind != .reply && $0.pipelineStep.isEmpty && ($0.state == .failed || ($0.state == .cancelled && $0.interrupted)) && !hasActiveChild($0)
    } }
    var pendingJobs: [Job] { jobs.filter { $0.state == .pending } }

    func reviewAll() { reviewable.forEach(requestReview) }
    func fixAll() { fixable.forEach(requestFix) }
    func resolveAll() { resolvable.forEach(requestResolve) }
    func retryAll() { retryable.forEach(retry) }
    func cancelPending() { pendingJobs.forEach(cancel) }

    /// Allow every pending permission request (once, not «always»).
    func allowAll() {
        for j in jobs { for r in j.permissions { answer(j, r, allow: true) } }
    }

    /// Merge all ready branches one by one, oldest first; a branch that can't be merged is skipped with its reason.
    @discardableResult
    func mergeAll() async -> MergeBatch? {
        guard mergeBatch == nil else { return nil }
        mergeBatch = MergeBatch(mergeable.map(\.id))
        while let id = mergeBatch?.next() {
            guard let j = job(id) else { mergeBatch?.record("Задача", skipped: "убрана из очереди"); continue }
            guard mergeable.contains(where: { $0 === j }) else {
                mergeBatch?.record(j.title, skipped: "больше не готова к слиянию")
                continue
            }
            if j.members.contains(where: { m in m.worktree.map { MergeRunner.needsMac(MergeRunner.command($0.main), in: $0.path) } ?? false }) {
                mergeBatch?.record(j.title, skipped: MergeRunner.macOnly)
                continue
            }
            let ok = await mergeGroup(j, ask: false)
            mergeBatch?.record(j.title, skipped: ok ? nil : j.parts.isEmpty ? j.worktreeNote : j.groupSummary)
        }
        let batch = mergeBatch
        mergeBatch = nil
        if let batch {
            Notifier.shared.post(title: "Слито веток: \(batch.merged) из \(batch.total)", body: batch.summary)
            lastMergeBatch = batch
        }
        return batch
    }

    func stopMergeAll() {
        mergeBatch?.stop()
        for j in allMembers where j.mergePhase != nil { cancelMerge(j) }
    }

    /// The agent repairs what fails only together with main — in the task's session.
    func requestMergeFix(_ repo: Job) {
        let task = repo.home
        guard let c = repo.mergeCheck, c.state == .red, let rw = repo.worktree, task.worktree != nil, !task.worktreeBusy, !hasActiveChild(task) else { return }
        let j = Job(kind: .fix, title: "Исправление проверки: \(task.title)", projectID: task.projectID, projectName: task.projectName,
                    cwd: task.cwd, prompt: (repo.owner == nil ? "" : ClaudePrompts.inRepo(repo.repoName, rw.path.path)) + ClaudePrompts.fixMergeCheck(task: task.title, command: c.failedCommand, output: c.output),
                    systemPrompt: task.systemPrompt, taskPath: task.taskPath)
        j.parentID = task.id
        j.useAgent(of: task)
        j.worktree = task.worktree
        j.baseCommit = task.baseCommit
        j.verifyCommand = c.command
        j.model = task.model
        j.fixesMergeCheck = true
        j.targetRepo = repo.owner == nil ? nil : repo.cwd.path
        repo.worktreeNote = "Агент исправляет проверку…"
        add(j)
    }

    /// A server returns files, not merge commits.
    /// Nor does a container: it has no history of the repository.
    func canResolve(_ task: Job) -> Bool { !capabilities(task.home).contains(.remote) && task.home.executor != .docker }

    /// Claude merges the project's current HEAD into the task branch (in its worktree) and resolves conflicts.
    func requestResolve(_ repo: Job) {
        let task = repo.home
        guard canResolve(task), let rw = repo.worktree, let w = task.worktree, !task.worktreeBusy, !hasActiveChild(task) else { return }
        let j = Job(kind: .fix, title: "Конфликт: \(task.title)", projectID: task.projectID, projectName: task.projectName,
                    cwd: task.cwd, prompt: (repo.owner == nil ? "" : ClaudePrompts.inRepo(repo.repoName, rw.path.path))
                        + ClaudePrompts.resolveMerge(task: task.title, branch: rw.branch, main: rw.main.path),
                    systemPrompt: task.systemPrompt, taskPath: task.taskPath)
        j.parentID = task.id
        j.useAgent(of: task)
        j.worktree = w
        j.baseCommit = task.baseCommit
        j.verifyCommand = task.verifyCommand
        j.model = task.model
        j.resolvesMerge = true
        j.targetRepo = repo.owner == nil ? nil : repo.cwd.path
        repo.worktreeNote = "\(agentTitle(task)) разрешает конфликт…"
        add(j)
    }

    /// The job goes to the default profile's agent; hidden when that one can't work in the main folder.
    var canResolveMain: Bool {
        guard let id = profiles().resolve("")?.agent else { return false }
        return agents[id]?.capabilities.contains(.requiresWorktree) == false
    }

    /// The agent fixes unresolved conflicts left in the main folder (e.g. after an interrupted merge or stash pop).
    func resolveMain(_ task: Job) {
        guard canResolveMain else { return }
        let path = task.cwd.standardizedFileURL.path
        guard !jobs.contains(where: { $0.resolvesMerge && $0.worktree == nil && $0.isActive
            && $0.cwd.standardizedFileURL.path == path }) else { return }
        let j = Job(kind: .fix, title: "Конфликты в основной папке: \(task.projectName)", projectID: task.projectID,
                    projectName: task.projectName, cwd: task.cwd, prompt: ClaudePrompts.resolveMain,
                    systemPrompt: task.systemPrompt)
        j.mustUseMain = true
        j.verifyCommand = task.verifyCommand
        j.resolvesMerge = true
        add(j)
    }

    /// Throw away the worktree and its branch.
    func discard(_ job: Job) {
        guard job.owner == nil, job.hasWorktree, !job.worktreeBusy, !job.isActive, !hasActiveChild(job) else { return }
        job.worktreeBusy = true
        Terminals.shared.closeAll(job.id)
        let teardown = dangerTeardown(job)
        let list = job.members.compactMap { m in m.worktree.map { (m, $0, m.owner == nil) } }
        Task {
            for (m, w, own) in list {
                await Task.detached(priority: .userInitiated) {
                    Worktrees.remove(w, deleteBranch: true, force: true, teardown: own ? teardown : nil, scripts: own)
                }.value
                m.worktree = nil
                if !m.merged { m.worktreeNote = "Ветка \(w.branch) удалена" }
            }
            job.worktreeBusy = false
            // Given up together with the branch; what is on the server is listed in Settings.
            job.remote?.returned = true
            pipelineEvent(job, .userFinish)
            save()
        }
    }

    /// Worktrees on disk that no job owns (left after a crash or manual cleanup of the queue).
    func orphanWorktrees() async -> [Worktrees.Info] {
        let root = worktreesRoot
        // git in every worktree: not on the main thread.
        let found = await OwnThread.run { Worktrees.scan(root: root) }
        let owned = Set(allMembers.compactMap { $0.worktree?.path.path })
        return found.filter { !owned.contains($0.path.path) }
    }
}
