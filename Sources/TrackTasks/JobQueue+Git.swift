import Foundation
import TrackTasksCore

extension JobQueue {
    private static func key(_ url: URL) -> String { TaskRepos.canonical(url) }

    /// The folder itself or one above/below it: a project may be a part of another one's folder.
    private static func related(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    func gitBusy(around folder: URL) -> Bool {
        guard !gitBusy.isEmpty else { return false }
        let path = Self.key(folder)
        return gitBusy.contains { Self.related($0, path) }
    }

    /// Why the branch of the main folder can't be switched, pulled or committed to now; nil = can.
    func gitBlocked(_ folder: URL) -> String? {
        let path = Self.key(folder)
        if gitBusy(around: folder) { return "В этой папке уже идёт операция git" }
        if autoMerging.contains(where: { Self.related(Self.key(URL(fileURLWithPath: $0)), path) }) { return "Автопилот сливает ветку" }
        // A task on several repositories has a branch in each of them.
        for j in jobs where creatingWorktree.contains(j.id) && j.repoFolders.contains(where: { Self.related($0.path, path) }) {
            return "Создаётся worktree для «\(j.title)»"
        }
        for j in allMembers where Self.related(j.realCwd, path) {
            if j.mergePhase != nil { return "Идёт слияние: «\(j.title)»" }
            if j.worktreeBusy { return "Идёт операция с веткой задачи «\(j.title)»" }
            if creatingWorktree.contains(j.id) { return "Создаётся worktree для «\(j.title)»" }
            if mergeBatch != nil, j.ownAwaitsMerge { return "Идёт «Слить все»" }
            guard j.owner == nil, j.worktree == nil else { continue }
            if j.state == .running { return "В основной папке работает агент: «\(j.title)»" }
            if Terminals.shared.claudeRunning(j) { return "В основной папке открыт Claude в терминале карточки «\(j.title)»" }
        }
        return nil
    }

    /// Branches of tasks that will be merged into whatever branch the main folder is on.
    func unmergedWorktrees(_ folder: URL) -> Int {
        let path = Self.key(folder)
        return Set(allMembers.filter { !$0.merged && $0.realCwd == path }.compactMap(\.worktree?.path.path)).count
    }

    /// Runs a git operation of the main folder while the queue keeps away from it.
    /// `locked` — with the project's check lock: `SafeMerge` reads and moves the main folder's branch under it.
    func exclusiveGit<T: Sendable>(_ folder: URL, locked: Bool, wait: TimeInterval = 5,
                                   _ body: @escaping @Sendable () -> Result<T, GitRun.Failure>) async -> Result<T, GitRun.Failure> {
        if let why = gitBlocked(folder) { return .failure(.init(why)) }
        let key = Self.key(folder)
        gitBusy.insert(key)
        defer {
            gitBusy.remove(key)
            pump()
        }
        return await withCheckedContinuation { c in
            // One thread takes and releases the lock.
            OwnThread.start {
                guard locked else { return c.resume(returning: body()) }
                let deadline = Date().addingTimeInterval(wait)
                guard let gate = Verify.acquire(folder, cancelled: { Date() > deadline }) else {
                    return c.resume(returning: .failure(.init("Идёт проверка проекта (verify) — повтори, когда она закончится")))
                }
                let r = body()
                gate.unlock()
                c.resume(returning: r)
            }
        }
    }
}
