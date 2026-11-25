import Foundation

/// Decides what the background queue does with each pending job: start it, start it in a new
/// worktree, keep it waiting (and why), or cancel it because its chain broke.
///
/// Pure logic: the app takes a snapshot of its jobs, asks `decide`, and carries out the decisions
/// (`JobQueue.pump`). `JobQueue.waitReason` reads the same decisions, so the reason shown in the UI
/// is exactly what holds the job back.
///
/// Jobs are walked in queue order, like the old loop: a job started (or cancelled) earlier in the walk
/// already counts as running (or cancelled) for the jobs after it.
public enum QueuePlanner {
    public enum Lane: Sendable, Equatable { case code, light }
    public enum State: String, Sendable, Equatable { case pending, running, done, failed, cancelled }

    public struct Job: Sendable, Equatable {
        public var id: UUID
        public var title: String
        public var state: State
        public var lane: Lane
        /// Project folder (main checkout).
        public var cwd: String
        /// Path of the job's own worktree, nil = runs in the main folder (unless `creatingWorktree`).
        public var worktree: String?
        /// Its own worktree is being created (path not known yet): the job takes a slot, not the main folder.
        public var creatingWorktree: Bool
        public var depends: [UUID]
        /// Finished in a worktree with a commit that isn't merged yet.
        public var awaitsMerge: Bool
        /// Finished (or planned) with questions of the agent that aren't closed.
        public var awaitsAnswers = false
        /// Must run in the main folder (fix of a main-folder task).
        public var mustUseMain: Bool
        /// Worktree creation failed before (no git / no commits).
        public var worktreeUnavailable: Bool
        /// User allowed a worktree despite uncommitted code in main.
        public var allowDirtyMain: Bool
        /// Last known uncommitted code files in main that hold the job back.
        public var dirtyMain: [String]
        /// «Волнами по приоритету»: 1-based wave number and the wave's priority (nil = not a wave job).
        public var wave: Int?
        public var wavePriority: String?
        /// The agent wrote its plan and waits for approval: not started, takes no slot and no folder.
        public var awaitingPlan: Bool
        /// «Опасный режим»: a new code job always gets a worktree from HEAD, never the main folder.
        public var forceWorktree: Bool
        /// `worktree: always` in about.md: a code job gets a worktree even when the main folder is free.
        public var alwaysWorktree = false
        /// Its agent edits code only in a worktree: never the main folder, also without git.
        public var agentWorktree = false
        /// Its pipeline waits for the person (the reason): not started, takes no slot and no folder.
        public var pipelineStop: String?
        /// Files and folders the task will change (`files:`), empty = unknown.
        public var files: [String] = []
        /// Doesn't wait for jobs with the same files: «Запустить всё равно» or work that has already begun.
        public var ignoresFiles = false
        /// Folders of the other repositories of the task (`repos:`, resolved paths).
        public var extraFolders: [String] = []
        /// `cwd` with symlinks resolved, comparable with `extraFolders`; nil = `cwd`.
        public var realCwd: String?
        /// Code job that finished in the main folder: its changes may be uncommitted there.
        public var doneInMain: Bool
        /// Its agent spends the limit watched by the guard (`Settings.hold`).
        public var guardedLimit: Bool
        /// Stopped by the limit: not finished, its unfinished edits are in its folder.
        public var limitWait = false
        /// When the window resets; nil = it may go on now.
        public var limitUntil: Date?
        /// Task priority (0 low, 1 medium, 2 high): the order of the queue changes only among equal ones.
        public var priority = 0

        public init(id: UUID = UUID(), title: String = "", state: State = .pending, lane: Lane = .code,
                    cwd: String = "/p", worktree: String? = nil, creatingWorktree: Bool = false, depends: [UUID] = [], awaitsMerge: Bool = false,
                    mustUseMain: Bool = false, worktreeUnavailable: Bool = false, allowDirtyMain: Bool = false,
                    dirtyMain: [String] = [], wave: Int? = nil, wavePriority: String? = nil,
                    awaitingPlan: Bool = false, forceWorktree: Bool = false, doneInMain: Bool = false, guardedLimit: Bool = true) {
            self.guardedLimit = guardedLimit
            self.awaitingPlan = awaitingPlan
            self.forceWorktree = forceWorktree
            self.doneInMain = doneInMain
            self.id = id
            self.title = title
            self.state = state
            self.lane = lane
            self.cwd = cwd
            self.worktree = worktree
            self.creatingWorktree = creatingWorktree
            self.depends = depends
            self.awaitsMerge = awaitsMerge
            self.mustUseMain = mustUseMain
            self.worktreeUnavailable = worktreeUnavailable
            self.allowDirtyMain = allowDirtyMain
            self.dirtyMain = dirtyMain
            self.wave = wave
            self.wavePriority = wavePriority
        }

        /// Its work is (or is left) in the main folder: no other code job goes there.
        var holdsMain: Bool { lane == .code && inMain && (state == .running || (state == .pending && limitWait)) }
        var isActive: Bool { state == .pending || state == .running }
        /// Runs (or would run) in the main project folder.
        var inMain: Bool { worktree == nil && !creatingWorktree }
        var folder: String { realCwd ?? cwd }
        /// Holds its extra repositories: its worktrees are there or being made.
        var holdsExtra: Bool { !extraFolders.isEmpty && state == .running && !inMain }
        /// Will get a worktree in every repository, all at once.
        var needsGroup: Bool { !extraFolders.isEmpty && inMain && (lane == .code || forceWorktree) }
    }

    public struct Settings {
        /// Max running jobs per lane.
        public var limit: Int
        /// Manual pause.
        public var paused: Bool
        /// Weekly-limit guard message; non-nil holds the jobs whose agent spends that limit.
        public var hold: String?
        public var worktreesEnabled: Bool
        /// Snapshot of uncommitted code files per project folder, collected in the background before
        /// `decide` (see `dirtyCandidates`). Folders missing here (or nil, for `waitReason`) fall back to
        /// `Job.dirtyMain`. The planner itself never runs git.
        public var dirtyFiles: [String: [String]]?
        /// Project folders without git or commits: a worktree is impossible there, `alwaysWorktree` has no effect.
        public var noCommits: Set<String> = []
        /// Project folders where the user switches the branch, pulls or commits right now.
        public var gitBusy: Set<String> = []

        public init(limit: Int, paused: Bool = false, hold: String? = nil, worktreesEnabled: Bool = true,
                    dirtyFiles: [String: [String]]? = nil) {
            self.limit = limit
            self.paused = paused
            self.hold = hold
            self.worktreesEnabled = worktreesEnabled
            self.dirtyFiles = dirtyFiles
        }
    }

    public enum SameFolder: Sendable, Equatable {
        /// Must use main / plain wait.
        case plain
        case worktreesOff
        case worktreeUnavailable
        /// Uncommitted code in main: a worktree wouldn't see it.
        case dirtyMain([String])
    }

    public enum WaitReason: Sendable, Equatable {
        case paused
        case limitHold(String)
        /// Stopped by the five-hour limit; continues its session after the reset.
        case limitReset(Date)
        /// Previous wave still running: priority, finished and total jobs of that wave, other active deps.
        case wave(priority: String, done: Int, total: Int, others: [String])
        case dependencies([String])
        case merge([String])
        case sameFolder(SameFolder)
        /// Must run in a worktree («Опасный режим»), but it can't be made.
        case worktreeRequired(String)
        /// `worktree: always`, but it can't be made; the job never goes to the main folder silently.
        case alwaysWorktree(String)
        /// The agent edits code only in a worktree, but it can't be made.
        case agentWorktree(String)
        /// A task on several repositories: why worktrees of all of them can't be made now.
        case repos(String)
        /// The user's git operation goes in the main folder.
        case gitBusy
        /// A job runs in the same worktree.
        case worktreeBusy
        /// Jobs that change the same files run, wait before this one or aren't merged yet (`unmerged`: all of them).
        case files([String], titles: [String], unmerged: Bool)
        case slot(limit: Int)
        /// The plan is written; the job waits for the user («Одобрить» / «Доработать»).
        case planApproval
        /// The agent's questions: of the job itself (empty) or of its dependencies.
        case answers([String])
        case pipeline(String)

        public var text: String {
            func titles(_ t: [String]) -> String { t.map { "«\($0)»" }.joined(separator: ", ") }
            switch self {
            case .paused: return "очередь на паузе"
            case .limitHold(let h): return h
            case .limitReset(let d): return "лимит 5 часов исчерпан: продолжу ту же сессию после сброса в \(LimitWait.clock(d))"
            case .wave(let p, let done, let total, let others):
                var s = "ждёт волну \(p) (\(done) из \(total))"
                if !others.isEmpty { s += " и зависимости: " + titles(others) }
                return s
            case .dependencies(let t): return "ждёт зависимости: " + titles(t)
            case .merge(let t): return "ждёт слияния веток: " + titles(t)
            case .sameFolder(.plain): return "ждёт другую задачу этого проекта"
            case .sameFolder(.worktreesOff): return "ждёт другую задачу этого проекта (worktree выключены в Настройках)"
            case .sameFolder(.worktreeUnavailable):
                return "ждёт другую задачу этого проекта (нет git/коммитов — worktree невозможен)"
            case .sameFolder(.dirtyMain(let files)):
                return "ждёт коммита в main: незакоммичено \(files.count) файл(ов) кода (\(DirtyFiles.summary(files))) — worktree их не увидит"
            case .worktreeRequired(let why): return "опасный режим работает только в worktree: " + why
            case .alwaysWorktree(let why): return "проект всегда работает в worktree (about.md): " + why
            case .agentWorktree(let why): return "здесь код правится только в worktree (агент или пайплайн): " + why
            case .repos(let why): return "несколько репозиториев: " + why
            case .gitBusy: return "ждёт операцию git в основной папке"
            case .worktreeBusy: return "ждёт другую задачу в той же ветке"
            case .files(let files, let t, let unmerged):
                return "правит те же файлы: \(DirtyFiles.summary(files)) — ждёт \(unmerged ? "слияния " : "")\(titles(t))"
            case .slot(let limit): return "ждёт свободный слот (\(limit) параллельно)"
            case .answers(let t): return "ждёт ответов" + (t.isEmpty ? "" : " на вопросы: " + titles(t))
            case .planApproval: return "ждёт одобрения плана"
            case .pipeline(let why): return "пайплайн ждёт тебя: " + why
            }
        }
    }

    public enum Decision: Sendable, Equatable {
        case start
        /// Main folder is busy (or the project always uses worktrees): create a worktree, then start there. If creation fails, mark the job
        /// `worktreeUnavailable` and decide again.
        case needWorktree
        case wait(WaitReason)
        /// Chain broken: the dependency failed or was cancelled. `lastLine` is shown in the queue.
        case cancel(lastLine: String)
    }

    /// Decision for every pending job (keyed by id). Non-pending jobs get no entry.
    public static func decide(jobs input: [Job], settings s: Settings) -> [UUID: Decision] {
        var jobs = input
        var index: [UUID: Int] = [:]
        for (i, j) in jobs.enumerated() where index[j.id] == nil { index[j.id] = i }
        var out: [UUID: Decision] = [:]
        // Pending jobs that wait only for files: they keep their place before later jobs with the same files.
        var reserved = Set<UUID>()

        for i in walkOrder(jobs, settings: s) {
            let job = jobs[i]
            let d = decideOne(job, jobs: jobs, index: index, reserved: reserved, settings: s)
            out[job.id] = d
            switch d {
            case .start:
                jobs[i].state = .running
            case .needWorktree:
                jobs[i].state = .running
                jobs[i].creatingWorktree = true
            case .cancel:
                jobs[i].state = .cancelled
            case .wait(.sameFolder(.dirtyMain(let files))):
                jobs[i].dirtyMain = files
            case .wait(.files):
                reserved.insert(job.id)
            case .wait:
                break
            }
        }
        return out
    }

    /// How many unfinished (pending or running) jobs depend on each job, directly or through others; every job counted once.
    public static func unblockCounts(jobs: [Job]) -> [UUID: Int] {
        var index: [UUID: Int] = [:]
        for (i, j) in jobs.enumerated() where index[j.id] == nil { index[j.id] = i }
        var dependents: [[Int]] = Array(repeating: [], count: jobs.count)
        for (i, j) in jobs.enumerated() {
            for d in Set(j.depends) { if let k = index[d], k != i { dependents[k].append(i) } }
        }
        var out: [UUID: Int] = [:]
        for (i, j) in jobs.enumerated() where index[j.id] == i {
            var seen: Set<Int> = [i], stack = dependents[i], count = 0
            while let n = stack.popLast() {
                guard seen.insert(n).inserted else { continue }
                if jobs[n].isActive { count += 1 }
                stack += dependents[n]
            }
            out[j.id] = count
        }
        return out
    }

    /// Indices of the pending jobs in the order `decide` walks them. Queue order, except when a lane has fewer free
    /// slots than pending jobs: then, among jobs of equal priority, those that unblock more come first (ties keep queue
    /// order). Jobs of different priorities keep their places relative to each other: each priority refills its own positions.
    static func walkOrder(_ jobs: [Job], settings s: Settings) -> [Int] {
        let pending = jobs.indices.filter { jobs[$0].state == .pending }
        // Only jobs that could start now (no unfinished dependency) compete for slots.
        var byID: [UUID: Int] = [:]
        for (i, j) in jobs.enumerated() where byID[j.id] == nil { byID[j.id] = i }
        let ready = pending.filter { i in !jobs[i].depends.contains { d in byID[d].map { jobs[$0].isActive } ?? false } }
        var crowded = false
        for lane in [Lane.code, .light] {
            let waiting = ready.filter { jobs[$0].lane == lane }.count
            let running = jobs.filter { $0.state == .running && $0.lane == lane }.count
            if waiting > max(0, s.limit - running) { crowded = true }
        }
        guard crowded, pending.count > 1 else { return pending }
        let counts = unblockCounts(jobs: jobs)
        var result = pending
        for p in Set(pending.map { jobs[$0].priority }) {
            let slots = pending.indices.filter { jobs[pending[$0]].priority == p }
            // Best first, but never ahead of an earlier job of the same project that changes the same files:
            // that one keeps its place (and its claim on the files).
            func conflict(_ x: Int, _ y: Int) -> Bool {
                let a = jobs[x], b = jobs[y]
                return a.lane == .code && b.lane == .code && a.cwd == b.cwd && !a.files.isEmpty && !b.files.isEmpty
                    && !TaskFiles.overlap(a.files, b.files).isEmpty
            }
            var rest = slots.map { pending[$0] }
            var sorted: [Int] = []
            while !rest.isEmpty {
                var best = 0
                for k in rest.indices.dropFirst() {
                    let ck = counts[jobs[rest[k]].id] ?? 0, cb = counts[jobs[rest[best]].id] ?? 0
                    guard ck > cb, !rest[..<k].contains(where: { conflict($0, rest[k]) }) else { continue }
                    best = k
                }
                sorted.append(rest.remove(at: best))
            }
            for (slot, idx) in zip(slots, sorted) { result[slot] = idx }
        }
        return result
    }

    /// Project folders whose uncommitted files `decide` may need: pending code jobs that could reach the
    /// dirty-main check (dependencies settled, worktree allowed) while another code job of the same folder
    /// runs or waits in the main folder; `alwaysWorktree` jobs — even when it is free (and to learn whether the
    /// folder has commits). A superset of what `decide` asks for; empty = no git needed.
    public static func dirtyCandidates(jobs: [Job], settings s: Settings) -> Set<String> {
        guard !s.paused else { return [] }
        var byID: [UUID: Job] = [:]
        for j in jobs where byID[j.id] == nil { byID[j.id] = j }
        // Dependencies done and merged: the job can start now (otherwise it waits or is cancelled).
        func settled(_ j: Job) -> Bool {
            !j.awaitingPlan && j.limitUntil == nil && j.pipelineStop == nil && (s.hold == nil || !j.guardedLimit) && !j.depends.compactMap { byID[$0] }.contains { $0.state != .done || $0.awaitsMerge || $0.awaitsAnswers }
        }
        var out = Set<String>()
        for j in jobs where j.state == .pending && j.needsGroup && settled(j) {
            out.insert(j.cwd)
            out.formUnion(j.extraFolders)
        }
        for j in jobs where (j.alwaysWorktree || j.agentWorktree) && j.state == .pending && j.lane == .code && j.inMain && !j.mustUseMain
            && settled(j) { out.insert(j.cwd) }
        guard s.worktreesEnabled else { return out }
        for j in jobs where j.forceWorktree && j.state == .pending && j.inMain && !j.allowDirtyMain
            && settled(j) && j.depends.contains(where: { byID[$0]?.doneInMain == true }) { out.insert(j.cwd) }
        for j in jobs where j.state == .pending && j.lane == .code && j.inMain && !j.forceWorktree && !j.agentWorktree
            && !j.mustUseMain && !j.worktreeUnavailable && !j.allowDirtyMain && !out.contains(j.cwd) && settled(j) {
            let mainBusy = jobs.contains {
                $0.id != j.id && $0.extraFolders.contains(j.folder) && ($0.holdsExtra || ($0.state == .pending && $0.needsGroup && settled($0)))
            } || jobs.contains {
                $0.id != j.id && $0.lane == .code && $0.cwd == j.cwd && $0.inMain
                    && ($0.holdsMain || ($0.state == .pending && settled($0)))
            }
            if mainBusy { out.insert(j.cwd) }
        }
        return out
    }

    private static func decideOne(_ job: Job, jobs: [Job], index: [UUID: Int], reserved: Set<UUID>,
                                  settings s: Settings) -> Decision {
        // Approval is the user's: the job holds nothing (it is pending, so not counted as running).
        if job.awaitingPlan { return .wait(job.awaitsAnswers ? .answers([]) : .planApproval) }
        if let why = job.pipelineStop { return .wait(.pipeline(why)) }
        if s.paused { return .wait(.paused) }
        // Background jobs spend tokens: wait when the weekly limit is nearly gone.
        if job.guardedLimit, let h = s.hold { return .wait(.limitHold(h)) }
        if let d = job.limitUntil { return .wait(.limitReset(d)) }

        let deps = job.depends.compactMap { index[$0].map { jobs[$0] } }
        let active = deps.filter(\.isActive)
        if !active.isEmpty {
            if let w = job.wave {
                let prev = deps.filter { $0.wave == w - 1 }
                if let p = prev.first?.wavePriority, prev.contains(where: \.isActive) {
                    let others = active.filter { $0.wave != w - 1 }.map(\.title)
                    return .wait(.wave(priority: p, done: prev.filter { !$0.isActive }.count,
                                       total: prev.count, others: others))
                }
            }
            return .wait(.dependencies(active.map(\.title)))
        }
        if let bad = deps.first(where: { $0.state != .done }) {
            return .cancel(lastLine: "Цепочка прервана: зависимость «\(bad.title)» не выполнена")
        }
        let asking = deps.filter(\.awaitsAnswers)
        if !asking.isEmpty { return .wait(.answers(asking.map(\.title))) }
        let unmerged = deps.filter(\.awaitsMerge)
        if !unmerged.isEmpty { return .wait(.merge(unmerged.map(\.title))) }

        // `inMain` is also true for a job whose worktree isn't made yet: it would be made from HEAD, which may be moving.
        // A job with its own worktree doesn't touch the main folder.
        if job.inMain, s.gitBusy.contains(job.cwd) || (job.needsGroup && job.extraFolders.contains(where: s.gitBusy.contains)) { return .wait(.gitBusy) }
        if let w = filesWait(job, jobs: jobs, index: index, reserved: reserved) { return .wait(w) }

        let running = jobs.filter { $0.state == .running && $0.lane == job.lane }
        guard running.count < s.limit else { return .wait(.slot(limit: s.limit)) }

        var decision = Decision.start
        if job.needsGroup {
            if let w = groupWait(job, jobs: jobs, deps: deps, settings: s) { return .wait(w) }
            return .needWorktree
        }
        // Planning too: it can't touch main, and the «code untouched» check works with parallel jobs.
        if job.lane == .code, job.inMain, job.agentWorktree, !job.mustUseMain {
            // Before «Опасный режим»: uncommitted code in main is asked about as usual.
            if !s.worktreesEnabled { return .wait(.agentWorktree("worktree выключены в Настройках")) }
            if job.worktreeUnavailable || s.noCommits.contains(job.cwd) {
                return .wait(.agentWorktree("нет git/коммитов или worktree не создался"))
            }
            if !job.allowDirtyMain {
                let dirty = dirtyFiles(job, deps: deps, settings: s)
                if !dirty.isEmpty { return .wait(.sameFolder(.dirtyMain(dirty))) }
            }
            decision = .needWorktree
        } else if job.inMain, job.forceWorktree, !job.mustUseMain {
            if !s.worktreesEnabled { return .wait(.worktreeRequired("worktree выключены в Настройках")) }
            if job.worktreeUnavailable { return .wait(.worktreeRequired("нет git/коммитов или worktree не создался")) }
            // Uncommitted work of a dependency wouldn't be in the worktree. Other uncommitted files stay in main.
            if deps.contains(where: \.doneInMain), !job.allowDirtyMain {
                let dirty = dirtyFiles(job, deps: deps, settings: s)
                if !dirty.isEmpty { return .wait(.sameFolder(.dirtyMain(dirty))) }
            }
            decision = .needWorktree
        } else if job.lane == .code, job.inMain, job.alwaysWorktree, !job.mustUseMain, !s.noCommits.contains(job.cwd) {
            if !s.worktreesEnabled { return .wait(.alwaysWorktree("worktree выключены в Настройках")) }
            if job.worktreeUnavailable { return .wait(.alwaysWorktree("worktree не создался")) }
            if !job.allowDirtyMain {
                let dirty = dirtyFiles(job, deps: deps, settings: s)
                if !dirty.isEmpty { return .wait(.sameFolder(.dirtyMain(dirty))) }
            }
            decision = .needWorktree
        } else if job.lane == .code, job.inMain,
           // Two stopped jobs of one folder don't wait for each other.
           jobs.contains(where: { $0.id != job.id && $0.holdsMain && $0.cwd == job.cwd && ($0.state == .running || !job.limitWait) })
            // A group branched off this folder: its HEAD and files are better left alone.
            || jobs.contains(where: { $0.id != job.id && $0.holdsExtra && $0.extraFolders.contains(job.folder) }) {
            // Main folder is busy: run in an isolated worktree if possible, otherwise wait.
            if job.mustUseMain { return .wait(.sameFolder(.plain)) }
            if !s.worktreesEnabled { return .wait(.sameFolder(.worktreesOff)) }
            if job.worktreeUnavailable { return .wait(.sameFolder(.worktreeUnavailable)) }
            // The worktree forks from HEAD: uncommitted code in main wouldn't be there. Ask first.
            if !job.allowDirtyMain {
                let dirty = dirtyFiles(job, deps: deps, settings: s)
                if !dirty.isEmpty { return .wait(.sameFolder(.dirtyMain(dirty))) }
            }
            decision = .needWorktree
        }
        // Two jobs never share one worktree at the same time.
        if let w = job.worktree, running.contains(where: { $0.worktree == w }) { return .wait(.worktreeBusy) }
        return decision
    }

    /// All folders are taken by one decision or none is: two groups never hold a part each and wait for the other.
    private static func groupWait(_ job: Job, jobs: [Job], deps: [Job], settings s: Settings) -> WaitReason? {
        func name(_ f: String) -> String { (f as NSString).lastPathComponent }
        if !s.worktreesEnabled { return .repos("worktree выключены в Настройках") }
        if let f = ([job.cwd] + job.extraFolders).first(where: s.noCommits.contains) { return .repos("нет git/коммитов в «\(name(f))»") }
        for f in job.extraFolders {
            if let other = jobs.first(where: { $0.id != job.id && $0.holdsMain && $0.folder == f }) {
                return .repos("в основной папке «\(name(f))» идёт «\(other.title)»")
            }
        }
        guard !job.allowDirtyMain, !job.forceWorktree || deps.contains(where: \.doneInMain) else { return nil }
        var dirty = dirtyFiles(job, deps: deps, settings: s)
        if let known = s.dirtyFiles, job.extraFolders.allSatisfy({ known[$0] != nil }) {
            for f in job.extraFolders { dirty += (known[f] ?? []).map { name(f) + "/" + $0 } }
        } else {
            // Not collected yet: what was last known about all the folders.
            dirty = job.dirtyMain
        }
        return dirty.isEmpty ? nil : .sameFolder(.dirtyMain(dirty))
    }

    /// Uncommitted files of the main folder to ask about. With `files:` — only the common ones, unless a dependency
    /// left its work uncommitted there: the job needs all of it.
    private static func dirtyFiles(_ job: Job, deps: [Job], settings s: Settings) -> [String] {
        let dirty = s.dirtyFiles?[job.cwd] ?? job.dirtyMain
        guard job.files.contains(where: TaskFiles.isValid), !deps.contains(where: \.doneInMain) else { return dirty }
        return dirty.filter { !TaskFiles.overlap(job.files, [$0]).isEmpty }
    }

    /// Jobs of the project that change the same files. Only new work waits: a job with its own worktree has a branch
    /// already, and two such jobs could wait for each other's merge forever. A job never waits for what depends on it.
    private static func filesWait(_ job: Job, jobs: [Job], index: [UUID: Int], reserved: Set<UUID>) -> WaitReason? {
        guard job.lane == .code, !job.files.isEmpty, !job.ignoresFiles, job.inMain else { return nil }
        var paths: [String] = [], titles: [String] = [], unmerged = true
        for other in jobs where other.id != job.id && other.lane == .code && other.cwd == job.cwd && !other.files.isEmpty {
            let merging = other.state == .done && other.awaitsMerge
            guard merging || other.state == .running || (other.state == .pending && other.limitWait) || reserved.contains(other.id) else { continue }
            let common = TaskFiles.overlap(job.files, other.files)
            guard !common.isEmpty, !dependsOn(other, job.id, jobs: jobs, index: index) else { continue }
            paths += common.filter { !paths.contains($0) }
            if !titles.contains(other.title) { titles.append(other.title) }
            if !merging { unmerged = false }
        }
        return paths.isEmpty ? nil : .files(paths, titles: titles, unmerged: unmerged)
    }

    private static func dependsOn(_ job: Job, _ target: UUID, jobs: [Job], index: [UUID: Int]) -> Bool {
        var stack = job.depends, seen = Set<UUID>()
        while let id = stack.popLast() {
            if id == target { return true }
            if seen.insert(id).inserted, let i = index[id] { stack += jobs[i].depends }
        }
        return false
    }
}
