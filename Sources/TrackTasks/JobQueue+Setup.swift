import Foundation
import TrackTasksCore

/// Commands of the project's worktree (`setup:` / `teardown:` in about.md): run only after a person approved them.
enum ScriptStore {
    static let key = "worktreeScriptApprovals"
    static let setupTimeout: TimeInterval = 10 * 60
    /// Teardown can run on the main thread (a cancelled job), so it waits less.
    static let teardownTimeout: TimeInterval = 60

    static var approvals: ScriptApprovals {
        get {
            UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ScriptApprovals.self, from: $0) } ?? ScriptApprovals()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// zsh -lc `command` in the worktree; main folder and branch are in the environment.
    static func run(_ command: String, in w: Worktrees.Info, timeout: TimeInterval, proxy: Bool = false,
                    onStart: ((RunningCommand) -> Void)? = nil, onOutput: (@Sendable (String) -> Void)? = nil) -> Worktrees.Result {
        if ContainerStore.shared.isContainer(w.path) {
            return ContainerStore.shared.run(command, in: w.path, timeout: timeout,
                                             variables: ["TRACKTASKS_WORKTREE": ContainerSpec.workspace, "TRACKTASKS_BRANCH": w.branch], proxy: proxy,
                                             onStart: onStart, onOutput: onOutput)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = w.path
        var env = ProcessInfo.processInfo.environment
        env["CI"] = "1"
        env["TRACKTASKS_MAIN"] = w.main.path
        env["TRACKTASKS_WORKTREE"] = w.path.path
        env["TRACKTASKS_BRANCH"] = w.branch
        p.environment = env
        return TimedProcess.run(p, timeout: timeout, killTree: true, onStart: { onStart?(.process($0)) }, onOutput: onOutput)
    }

    /// Before the worktree is deleted. Failure (or an unapproved command) never blocks the deletion.
    static func teardown(_ w: Worktrees.Info, allowed: String? = nil) {
        let scripts = WorktreeScripts.load(projectAt: w.main)
        let cmd = scripts.teardown
        guard !cmd.isEmpty, FileManager.default.fileExists(atPath: w.path.path),
              cmd == allowed || approvals.isApproved(.teardown, cmd, project: w.main) else { return }
        let r = run(cmd, in: w, timeout: teardownTimeout)
        if !r.ok { Log.git.process("teardown failed", project: w.main.lastPathComponent, command: WorktreeScripts.tail(r.message, limit: 300)) }
    }
}

extension JobQueue {
    /// A code job in a fresh worktree runs the project's `setup:` before Claude starts.
    /// Returns true when setup took over (it calls `start` again when done).
    func setupBeforeStart(_ job: Job) -> Bool {
        guard job.kind == .runTask, !job.setupDone, let w = job.worktree else { return false }
        let scripts = WorktreeScripts.load(projectAt: job.cwd)
        guard !scripts.isEmpty else { job.setupDone = true; return false }
        let pending = ScriptStore.approvals.pending(scripts, project: job.cwd)
        if !pending.isEmpty, allows(.setup, job) {
            // Not remembered as approved: after the mode the person is asked again.
            for p in pending { danger(job, "\(p.kind.title) без подтверждения: $ \(p.command)") }
        } else if !pending.isEmpty {
            let names = pending.map(\.kind.title).joined(separator: ", ")
            job.scriptApproval = scripts
            job.log.append("⚙︎ Команда \(names) из about.md не подтверждена — не запускаю:")
            for p in pending { job.log.append("$ \(p.command)") }
            failSetup(job, w, "Нужно подтвердить команды worktree (\(names)) из about.md")
            return true
        }
        guard !scripts.setup.isEmpty else { job.setupDone = true; return false }
        job.settingUp = true
        job.state = .running
        job.scriptApproval = nil
        job.lastLine = "Setup: \(scripts.setup)"
        job.log.append("⚙︎ Setup: $ \(scripts.setup)")
        onStarted?(job)
        let cmd = scripts.setup
        let run = UUID()
        job.setupRun = run
        Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = Date()
            let r = ScriptStore.run(cmd, in: w, timeout: ScriptStore.setupTimeout, proxy: true, onStart: { p in
                Task { @MainActor in
                    if job.setupRun == run { job.setupProcess = p } else { p.kill() }
                }
            }, onOutput: { chunk in
                Task { @MainActor in
                    if job.setupRun == run { job.log.append(WorktreeScripts.tail(chunk)) }
                }
            })
            let secs = Int(Date().timeIntervalSince(t0))
            await self?.setupFinished(job, w, r, secs, run)
        }
        return true
    }

    private func setupFinished(_ job: Job, _ w: Worktrees.Info, _ r: Worktrees.Result, _ secs: Int, _ run: UUID) {
        // Cancelled (or restarted) while it ran: this result belongs to an older run.
        guard job.setupRun == run else { return }
        job.settingUp = false
        job.setupRun = nil
        job.setupProcess = nil
        guard r.ok else {
            failSetup(job, w, "Setup не прошёл (\(secs) с)")
            return
        }
        job.log.append("⚙︎ ✓ Setup за \(secs) с")
        job.setupDone = true
        save()
        start(job)
    }

    /// No Claude run: the worktree is dropped, a retry makes a fresh one.
    private func failSetup(_ job: Job, _ w: Worktrees.Info, _ line: String) {
        job.log.append("⚙︎ ✗ " + line)
        job.lastLine = line
        if handoffNotStarted(job, line) { return }
        if job.handoffs.isEmpty {
            dropWorktrees(job)
            job.baseCommit = ""
        }
        finish(job, .failed)
    }

    /// The person saw the commands in `job.scriptApproval`: remember them and run the job again.
    func approveScripts(_ job: Job) {
        guard let scripts = job.scriptApproval else { return }
        var a = ScriptStore.approvals
        a.approve(scripts, project: job.cwd)
        ScriptStore.approvals = a
        retry(job)
    }
}
