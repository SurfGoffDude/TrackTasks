import Foundation
import TrackTasksCore

/// Where approvals of task commands live: UserDefaults, like those of `setup:`. Tests keep theirs in memory.
final class TaskVerifyStore: @unchecked Sendable {
    static let key = "taskVerifyApprovals"
    static let shared = TaskVerifyStore()
    private let defaults: UserDefaults?
    private var memory = TaskVerifyApprovals()
    private let lock = NSLock()
    /// nil — only in memory.
    init(_ defaults: UserDefaults? = .standard) { self.defaults = defaults }

    private var all: TaskVerifyApprovals {
        get {
            guard let defaults else { return memory }
            return defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(TaskVerifyApprovals.self, from: $0) } ?? TaskVerifyApprovals()
        }
        set {
            if let defaults { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.key) } else { memory = newValue }
        }
    }
    func approved(_ project: URL, _ file: String) -> String? { lock.withLock { all.approved(project, file) } }
    func approve(_ command: String, _ project: URL, _ file: String) {
        lock.withLock {
            var a = all
            a.approve(command, project, file)
            all = a
        }
    }
}

/// Reads the task's `verify:` anew every time it is asked: the string it returns is the one to run.
/// Dangerous mode and the autopilot aren't asked: they can't approve it.
struct TaskVerifyGate: Sendable {
    let project: URL
    let task: URL
    /// The field when the task was queued.
    let queued: String?
    /// The task changes several repositories: one command can't check them.
    let severalRepos: Bool
    /// Where the command would run.
    let folder: URL
    let store: TaskVerifyStore

    var file: String { task.lastPathComponent }

    func decide() -> TaskVerify.Decision {
        let now = TaskVerify.load(taskAt: task), d = TaskVerify.decide(now, queued: queued, approved: store.approved(project, file))
        guard case .command(let c)? = now else { return d }
        // Nothing to approve: it couldn't be run anyway. The way out is to change or remove the field.
        if severalRepos { return .refuse(.init(Self.reposReason)) }
        if MergeRunner.needsMac(c, in: folder) { return .refuse(.init("команде нужен Mac, а код из контейнера на нём не запускается — исправь или убери поле verify задачи")) }
        return d
    }

    static let reposReason = "verify задачи не совместимо с repos: одна команда не относится к каждому репозиторию"
}

extension JobQueue {
    /// Start of `verifyNote` of a task whose own check was not run.
    static let taskCheckRefused = "Проверка задачи не запущена: "
    static let taskCheckApproved = "Проверка задачи подтверждена, выполнится при слиянии"

    /// nil — the job belongs to no task file.
    func taskGate(_ job: Job) -> TaskVerifyGate? {
        let task = group(job)
        guard let path = task.taskPath, [.runTask, .fix, .reply, .review].contains(task.kind) else { return nil }
        return TaskVerifyGate(project: task.cwd, task: URL(fileURLWithPath: path), queued: task.taskVerify,
                              severalRepos: !task.repos.isEmpty || !task.parts.isEmpty, folder: task.runDir, store: taskVerifyStore)
    }

    /// Something to run or to refuse.
    func hasTaskCheck(_ job: Job) -> Bool {
        if case .none? = taskGate(job)?.decide() { return false }
        return taskGate(job) != nil
    }

    /// Fixed when the job is queued: a command that disappears from the file later was taken away by somebody.
    func markTaskVerify(_ job: Job) {
        guard job.taskVerify == nil else { return }
        if let p = job.parentID { job.taskVerify = self.job(p)?.taskVerify }
        else if job.kind == .runTask, let path = job.taskPath { job.taskVerify = TaskVerify.load(taskAt: URL(fileURLWithPath: path))?.text }
    }

    /// What the card asks to approve.
    func refreshTaskCheck(_ job: Job) {
        guard job.kind == .runTask, job.parentID == nil else { return }
        let shown = job.isActive || job.awaitsMerge || job.verifyNote.hasPrefix(Self.taskCheckRefused)
        let r = shown ? taskGate(job)?.decide().refusal : nil
        if r?.id != job.taskCheckRefusal?.id { job.taskCheckRefusal = r }
        // The file was put back as it was approved.
        if shown, r == nil { unparkTaskCheck(job) }
    }

    func refreshTaskChecks() {
        let parked = jobs.filter { $0.auto.parked != nil }.count
        for j in jobs { refreshTaskCheck(j) }
        if jobs.filter({ $0.auto.parked != nil }).count != parked { pump() }
    }

    /// The person saw exactly `refusal.ask`; the file is not read again for it.
    func approveTaskCheck(_ job: Job, _ refusal: TaskVerify.Refusal) {
        guard let text = refusal.ask, let gate = taskGate(job) else { return }
        taskVerifyStore.approve(text, gate.project, gate.file)
        job.log.append(text.isEmpty ? "⚙︎ Подтверждено: проверка задачи убрана" : "⚙︎ Проверка задачи подтверждена: $ \(text)")
        let waited = job.verifyNote.hasPrefix(Self.taskCheckRefused)
        for j in jobs where group(j) === job || j.taskPath == job.taskPath { refreshTaskCheck(j) }
        if job.taskCheckRefusal == nil {
            unparkTaskCheck(job)
            if waited, !job.isActive {
                if text.isEmpty {
                    job.verifyNote = ""
                    job.verifyFailed = false
                } else if job.hasWorktree {
                    // With the project's one, so that `SafeMerge` sees what they leave behind.
                    job.verifyNote = Self.taskCheckApproved
                    job.verifyFailed = true
                } else if job.state == .done, !job.hadWorktree {
                    recheckInMain(job)
                }
            }
        }
        save()
        pump()
    }

    private func unparkTaskCheck(_ job: Job) {
        guard let why = job.auto.parked, why.hasPrefix(Autopilot.taskCheckReason) else { return }
        unpark(job, [why])
    }

    /// Both checks of a task done in the main folder; nothing is sent to the agent.
    func recheckInMain(_ job: Job) {
        guard let gate = taskGate(job), !hasActiveChild(job) else { return }
        let project = MergeRunner.command(job.cwd), dir = job.runDir
        job.lastLine = "Проверка задачи…"
        Task { [weak self] in
            // The queue keeps away from the folder meanwhile.
            let r = await self?.exclusiveGit(gate.project, locked: true) { .success(Verify.pair(project, gate, in: dir)) }
            guard let self, let r else { return }
            job.lastLine = ""
            switch r {
            case .failure(let f): job.verifyNote = Self.taskCheckRefused + f.message
            case .success(let p):
                job.verifyFailed = !p.ok
                if let why = p.refused { job.verifyNote = Self.taskCheckRefused + why }
                else if p.ok { job.verifyNote = Evidence.passedMark + p.passed.joined(separator: "; ") }
                else {
                    job.verifyNote = p.result.timedOut ? "Проверка не уложилась в \(Int(Verify.timeout / 60)) мин: \(p.command)" : "Проверка не прошла: \(p.command)"
                    job.log.append("⚙︎ ✗ " + job.verifyNote + "\n" + p.result.output)
                }
            }
            refreshTaskCheck(job)
            save()
        }
    }
}

extension Verify {
    struct Pair {
        var result = Result(ok: true, output: "")
        /// The last command run.
        var command = ""
        var passed: [String] = []
        /// The last command is the task's own.
        var isTask = false
        /// Why the task's own check was not run.
        var refused: String?
        var ok: Bool { result.ok && refused == nil }
    }

    /// The project's check, then — only if it passed — the task's own, each with its own limit. Separate runs: the
    /// syntax of one must not change the result of the other. The caller holds the project's lock.
    static func pair(_ project: String, _ gate: TaskVerifyGate?, in dir: URL, onStart: ((RunningCommand) -> Void)? = nil) -> Pair {
        var p = Pair()
        if !project.isEmpty {
            p.command = project
            p.result = execute(project, in: dir, onStart: onStart)
            guard p.result.ok else { return p }
            p.passed.append(project)
        }
        switch gate?.decide() {
        case nil, TaskVerify.Decision.none?: break
        case .refuse(let r)?: p.refused = r.why
        case .run(let c)?:
            p.command = c
            p.isTask = true
            p.result = execute(c, in: dir, onStart: onStart)
            if p.result.ok { p.passed.append(c) }
        }
        return p
    }
}
