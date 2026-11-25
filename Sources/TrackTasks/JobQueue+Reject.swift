import Foundation
import TrackTasksCore

extension JobQueue {
    // MARK: Reject parts of the diff

    /// Why files and hunks of this diff can't be rejected now; nil = can.
    func rejectBlocked(_ s: DiffSource) -> String? {
        guard s.branch != nil else { return "Отклонять можно только правки в worktree — основную папку трекер не трогает" }
        guard let job = rejectOwner(s) else { return "Worktree уже слит или удалён" }
        let path = s.folder.standardizedFileURL.path
        if Terminals.shared.claudeRunning(job.home) { return "В ветке открыт Claude в терминале карточки — закрой его вкладку" }
        if hasActiveChild(job) || job.home.isActive && job.owner != nil || jobs.contains(where: { $0.isActive && $0.worktree?.path.standardizedFileURL.path == path }) {
            return "Агент ещё работает в этой ветке (или ждёт очереди)"
        }
        if job.worktreeBusy { return "В ветке идёт другая операция — дождись её" }
        return nil
    }

    /// The task that owns the worktree. Looked up by folder: a retry replaces the job the window was opened for.
    private func rejectOwner(_ s: DiffSource) -> Job? {
        let path = s.folder.standardizedFileURL.path
        return jobs.filter { !$0.isFollowUp && $0.kind != .review }.flatMap(\.members).first { !$0.merged
            && $0.worktree?.path.standardizedFileURL.path == path }
    }

    /// Runs a reject/undo holding the worktree, so no merge, push or agent starts meanwhile. Returns an error text; nil = done.
    func changeWorktree(_ s: DiffSource, note: String, _ body: @escaping @Sendable () throws -> Void) async -> String? {
        if let why = rejectBlocked(s) { return why }
        guard let job = rejectOwner(s), let w = job.worktree else { return "Worktree уже слит или удалён" }
        let base = job.baseCommit
        job.worktreeBusy = true
        let (error, stat) = await Task.detached(priority: .userInitiated) { () -> (String?, String) in
            do {
                try body()
                return (nil, base.isEmpty ? "" : Worktrees.diffStat(w, base: base))
            } catch {
                return ((error as? DiffReject.Failure)?.message ?? error.localizedDescription, "")
            }
        }.value
        job.worktreeBusy = false
        if error == nil {
            job.mergeCheck = nil
            if !base.isEmpty { job.diffStat = stat }
            job.worktreeNote = note + ". Проверка и ревью были до этого"
                + (job.hasLivePR ? "; PR ещё не обновлён" : "")
        }
        save()
        pump()
        return error
    }
}
