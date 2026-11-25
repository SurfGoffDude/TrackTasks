import Foundation
import TrackTasksCore

extension JobQueue {
    // MARK: Fork of a task's session

    /// Why this job can't be forked now; nil = can.
    func forkBlocked(_ job: Job) -> String? {
        if job.kind != .runTask { return "Ответвить можно только основной запуск задачи" }
        if !job.repos.isEmpty || job.isGroup { return "Задачу на несколько репозиториев ответвить нельзя" }
        if job.isActive { return "Задача ещё работает" }
        if job.sessionID == nil { return "У запуска нет сессии агента" }
        if !capabilities(job).contains(.fork) { return "Агент этой задачи не умеет ответвлять сессию" }
        if job.rewind != nil { return "Разговор откатан: сначала ответь агенту или оставь прежний разговор" }
        if Terminals.shared.claudeRunning(job) { return "В этой сессии открыт Claude в терминале карточки — закрой его вкладку" }
        if job.worktreeBusy { return "С веткой сейчас что-то делают" }
        if job.planPhase != nil && job.planPhase != .approved { return "План ещё не одобрен" }
        if !Worktrees.enabled { return "Worktree отключены в настройках — ответвление без них затронуло бы ветку исходной задачи" }
        return nil
    }

    /// Branch or commit the fork starts from: the source's branch with its commits, else the commit it was based on.
    /// nil = current HEAD (source ran in the main folder without a worktree, or its branch is already merged).
    static func forkRef(worktreeBranch: String?, baseCommit: String, merged: Bool) -> String? {
        if let b = worktreeBranch { return b }
        return merged || baseCommit.isEmpty ? nil : baseCommit
    }

    /// New job with a copy of the source session (`--resume --fork-session`) in its own worktree.
    /// The source job, its session and its branch are not touched.
    func fork(_ source: Job, prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, forkBlocked(source) == nil, let sid = source.sessionID else { return }
        let ref = Self.forkRef(worktreeBranch: source.worktree?.branch, baseCommit: source.baseCommit, merged: source.merged)
        let j = Job(kind: .runTask, title: "Fork: \(source.title)", projectID: source.projectID, projectName: source.projectName,
                    cwd: source.cwd, prompt: text, systemPrompt: source.systemPrompt, taskPath: source.taskPath)
        j.forkOf = source.id
        j.forkSession = sid
        j.fromPipeline = source.fromPipeline
        j.evidenceAsked = source.evidenceAsked
        j.useAgent(of: source)
        j.forkTitle = source.title
        j.model = source.model
        j.modelReason = "ответвление: модель исходной задачи"
        j.verifyCommand = source.verifyCommand
        j.taskVerify = source.taskVerify
        j.lastLine = "Создаю worktree для ответвления…"
        source.worktreeBusy = true
        let cwd = source.cwd, title = j.title, id = j.id, container = j.executor == .docker
        Task.detached(priority: .userInitiated) { [weak self] in
            let made = Worktrees.create(for: cwd, title: title, jobID: id, from: ref, container: container)
            await self?.forkWorktreeReady(source, j, made)
        }
    }

    private func forkWorktreeReady(_ source: Job, _ j: Job, _ made: (Worktrees.Info, base: String)?) {
        source.worktreeBusy = false
        guard let (w, base) = made else {
            source.worktreeNote = "Ответвление не создано: не удалось сделать worktree"
            save()
            return
        }
        j.lastLine = ""
        j.worktree = w
        j.baseCommit = base
        // Started in its own worktree: it never takes the main folder, so the planner starts it as soon as a slot is free.
        add(j)
    }

    /// Forks of this job, newest first.
    func forks(of job: Job) -> [Job] {
        jobs.filter { $0.forkOf == job.id }.reversed()
    }
}
