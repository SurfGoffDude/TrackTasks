import Foundation
import TrackTasksCore

/// Worktrees whose folder or repository is gone.
extension JobQueue {
    nonisolated static func damage(_ infos: [Worktrees.Info]) -> WorktreeDamage? {
        // In a container what is inside isn't trusted.
        guard !infos.contains(where: { ContainerStore.shared.isContainer($0.path) }) else { return nil }
        return WorktreeDamage.of(infos.map { w in
            (WorktreeSnapshot.exists(w.path), WorktreeSnapshot.exists(w.main.appendingPathComponent(".git")))
        })
    }

    /// Why the usual removal doesn't fit; nil — it does. Looked at anew.
    func damagedState(_ g: CleanupGroup) async -> (damage: WorktreeDamage, state: WorktreeCleanup.Group)? {
        let infos = g.infos
        guard let d = await OwnThread.run({ Self.damage(infos) }) else { return nil }
        return (d, await groupState(g))
    }

    /// Nothing to delete: the jobs forget the folder, the branch stays. Returns why not.
    func forgetMissing(_ group: CleanupGroup) async -> String? {
        let infos = group.infos
        guard await OwnThread.run({ Self.damage(infos) }) == .folderGone else { return "Папка снова на месте — обнови список" }
        let facts = queueFacts(group, held: false)
        if facts.values.contains(where: { $0[.working] != false || $0[.waiting] != false || $0[.busy] != false }) { return "Задача ещё работает или ждёт" }
        for j in group.jobs {
            for m in j.members where m.worktree.map({ group.paths.contains($0.path.path) }) == true {
                m.worktree = nil
                m.mergeArtifacts = []
                if !m.merged { m.worktreeNote = "Папки worktree больше нет, ветка не тронута" }
            }
            j.setupDone = false
            j.interrupted = false
            j.resumeSession = nil
        }
        if pinnedWorktrees?.isDisjoint(with: group.paths) == false { pin(group.paths, false) }
        saveNow()
        pump()
        return nil
    }

    /// No git, so no snapshot: to the Trash. Only a folder of no task. Returns why not.
    func trashOrphan(_ group: CleanupGroup) async -> String? {
        guard let g = await cleanupGroups().first(where: { $0.id == group.id }), g.paths == group.paths else { return "Список worktree изменился — обнови" }
        guard g.jobs.isEmpty else { return "У папки есть задача" }
        guard trustsQueue, let pins = pinnedWorktrees else { return "Очередь или закрепления не прочитаны" }
        guard pins.isDisjoint(with: g.paths) else { return "Закреплён" }
        guard let (damage, state) = await damagedState(g), damage == .mainGone else { return "Репозиторий снова на месте — обнови список" }
        let blocks = WorktreeDamage.blocks(state)
        if !blocks.isEmpty { return WorktreeCleanup.text(blocks) }
        let infos = g.infos
        return await OwnThread.run {
            guard Self.damage(infos) == .mainGone else { return "Состояние папки изменилось" }
            for w in infos {
                do { try FileManager.default.trashItem(at: w.path, resultingItemURL: nil) } catch { return error.localizedDescription }
            }
            return nil
        }
    }

    /// Asks Haiku whether the leftovers are worth keeping. It only advises: the person presses the button, the code checks again.
    func damageAdvice(_ g: CleanupGroup) async -> WorktreeDamage.Advice? {
        let infos = g.infos
        let prompt = await OwnThread.run { () -> String in
            infos.map { w in
                let all = (try? FileManager.default.subpathsOfDirectory(atPath: w.path.path)) ?? []
                let files = all.filter { $0 != ".git" }
                return WorktreeDamage.prompt(path: w.path.path, main: w.main.path, branch: w.branch, files: Array(files.sorted().prefix(80)), total: files.count)
            }.joined(separator: "\n\n")
        }
        return await withCheckedContinuation { c in
            let p = ClaudeProcess()
            p.onExit = { s in
                // Keeps the process until it ends.
                withExtendedLifetime(p) {
                    Spend.shared.add(s, project: g.project, kind: "Проверка worktree")
                    c.resume(returning: s.failed ? nil : WorktreeDamage.advice(s.resultText))
                }
                p.onExit = nil
            }
            do {
                try p.start(ClaudeOptions.oneShot(cwd: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0], prompt: prompt, model: .haiku))
            } catch {
                p.onExit = nil
                c.resume(returning: nil)
            }
        }
    }
}
