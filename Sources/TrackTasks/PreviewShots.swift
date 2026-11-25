import Foundation
import TrackTasksCore

/// Puts the snapshot where the agent can read it and git can't see it.
enum PreviewShots {
    /// Not on the main thread. Throws = don't send.
    nonisolated static func place(_ png: Data, _ shot: String, in w: Worktrees.Info) throws {
        guard !ContainerStore.shared.isContainer(w.path) else { throw PreviewFolder.Failure(message: "Задача идёт в контейнере: снимок передать нельзя") }
        guard FileManager.default.fileExists(atPath: w.path.path) else { throw PreviewFolder.Failure(message: "Папка worktree удалена") }
        try PreviewFolder.put(png, shot, in: w.path)
        guard Worktrees.git(["check-ignore", "-q", "--", PreviewFolder.path(shot)], in: w.path).ok else {
            try? SafeFolder(w.path).remove(PreviewFolder.path(shot))
            throw PreviewFolder.Failure(message: "git не игнорирует папку снимков \(PreviewFolder.name) — снимок мог бы попасть в ветку, сообщение не отправлено")
        }
    }

    /// How this task's agent gets it.
    @MainActor static func shot(_ d: PreviewDraft, _ w: Worktrees.Info, images: Bool) -> PreviewDraft.Shot {
        images ? .attached : .file(w.path.appendingPathComponent(PreviewFolder.path(d.shotName)).path)
    }
}

extension JobQueue {
    /// Why a comment with a snapshot can't go to this task's agent; nil = can.
    func previewBlocked(_ job: Job) -> String? {
        guard job.worktree != nil else { return "Комментарий недоступен: у задачи нет worktree, снимок негде хранить вне git" }
        return replyBlocked(job)
    }

    func previewMessage(_ job: Job, _ d: PreviewDraft) -> String? {
        guard let w = job.worktree else { return nil }
        return d.message(PreviewShots.shot(d, w, images: capabilities(job).contains(.images)))
    }

    /// Only from the person's button: `shown` is the message they saw. nil = sent, otherwise why not.
    func sendPreview(_ job: Job, shown: String) async -> String? {
        if let why = previewBlocked(job) { return why }
        guard let w = job.worktree, let d = previews.draft(job.id), !d.isBlank else { return "Напиши комментарий" }
        guard d.delivery?.state != .sending else { return "Комментарий уже отправляется" }
        guard let png = previews.shot(job.id) else { return "Снимок черновика потерян — выбери элемент заново" }
        previews.save(job.id)
        let name = d.shotName
        do { try await Task.detached(priority: .userInitiated) { try PreviewShots.place(png, name, in: w) }.value } catch { return error.localizedDescription }
        // Anything could have changed meanwhile.
        guard previews.draft(job.id) == d, job.worktree == w, previewMessage(job, d) == shown else { return "Черновик изменился — проверь его и отправь снова" }
        return sendReply(job, text: shown, preview: SentPreview(draft: d.id, shot: name)) ? nil : previewBlocked(job) ?? "Сейчас отправить нельзя"
    }
}
