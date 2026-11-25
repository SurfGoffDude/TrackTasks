import Foundation
import TrackTasksCore

/// git of the history window and the commit sheet. Nothing here runs on the main thread.
enum GitOps {
    typealias Outcome<T> = Result<T, GitRun.Failure>

    static let git: GitRun.Runner = DiffLoader.runEnv
    static let network: GitRun.Network = { args, dir in
        let r = TimedProcess.gitNetwork(args, in: dir)
        return .init(status: r.ok ? 0 : 1, out: Data(r.out.utf8), err: r.err)
    }

    static func background<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: body()) }
        }
    }

    struct Snapshot: Sendable {
        var page: GitHistory.Page
        var state: GitState
    }

    static func load(_ dir: URL, limit: Int) async -> Snapshot {
        await background {
            Log.git.measure("GitOps.load", dir.lastPathComponent) {
                Snapshot(page: GitHistory.load(dir, limit: limit, git: git), state: GitBranches.load(dir, git: git))
            }
        }
    }

    /// Uncommitted files right now, for the question before switching.
    static func dirty(_ dir: URL) async -> Outcome<[String]> {
        await background { GitStaging.status(dir, git: git).map { $0.map(\.path) } }
    }

    static func diff(_ c: GitCommit, project: String, folder: URL) async -> DiffSource? {
        await background { DiffSource(commit: c, project: project, folder: folder) }
    }

    static func fetch(_ dir: URL) async -> Outcome<String> {
        await background { GitBranches.fetch(dir, git: git, network: network).map { "Получено с сервера" } }
    }

    static func pushPlan(_ dir: URL) async -> Outcome<GitBranches.PushPlan> {
        await background { GitBranches.pushPlan(dir, git: git) }
    }

    static func push(_ plan: GitBranches.PushPlan, in dir: URL, exact: Bool = true) async -> Outcome<String> {
        await background { GitBranches.push(plan, in: dir, exact: exact, git: git, network: network) }
    }

    @MainActor
    static func switchTo(_ b: GitBranch, in dir: URL, confirmed: Set<String>, jobs: JobQueue) async -> GitBranches.SwitchResult {
        let id = b.id
        let r = await jobs.exclusiveGit(dir, locked: true) {
            .success(GitBranches.switchTo(id, in: dir, confirmed: confirmed, git: git))
        }
        switch r {
        case .success(let s): return s
        case .failure(let e): return .failed(e.message)
        }
    }

    /// Fetch outside the lock, then only the fast-forward holds the folder.
    @MainActor
    static func pull(_ dir: URL, jobs: JobQueue) async -> Outcome<String> {
        if let why = jobs.gitBlocked(dir) { return .failure(.init(why)) }
        let fetched = await background { () -> Outcome<String> in
            GitBranches.pullSource(dir, git: git).flatMap { s in
                GitBranches.fetch(dir, remote: s.remote, git: git, network: network).map { s.branch }
            }
        }
        switch fetched {
        case .failure(let e): return .failure(e)
        case .success(let branch):
            return await jobs.exclusiveGit(dir, locked: true) { GitBranches.fastForward(dir, branch: branch, git: git) }
        }
    }

    @MainActor
    static func commit(_ dir: URL, message: String, shown: [GitFile], selected: Set<Data>, mayLose: Bool, jobs: JobQueue) async -> Outcome<String> {
        await jobs.exclusiveGit(dir, locked: false) {
            GitStaging.commit(dir, message: message, shown: shown, selected: selected, mayLose: mayLose, git: git)
        }
    }
}
