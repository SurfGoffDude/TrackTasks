import Foundation
import TrackTasksCore

extension JobQueue {
    struct RemoteRefusal: Error { let message: String }

    /// Run on the server for this turn: the unclaimed one, or a new one. Written to queue.json before it can start.
    func remoteRequest(_ job: Job) -> Result<AgentRemote, RemoteRefusal> {
        guard let server = job.remoteUnclaimed ? job.remote?.server : job.server else {
            return .failure(.init(message: "В профиле агента «\(job.profile)» не задан сервер (Настройки → «Агенты»)"))
        }
        if let p = server.problem { return .failure(.init(message: "Сервер \(server.title): \(p)")) }
        if job.resolvesMerge { return .failure(.init(message: "Слияние веток на сервере не делается — разреши конфликт локально")) }
        let attach = job.remoteUnclaimed
        // Own copy per worktree; without one (a plan) — per job, kept while the plan is reworked.
        let work = job.worktree.map { RemoteRun.key($0.path.path) }
            ?? (job.remote?.server == server ? job.remote?.work : nil) ?? RemoteRun.key(job.cwd.path + job.id.uuidString)
        if !attach {
            if jobs.contains(where: { $0 !== job && $0.remoteUnclaimed && $0.remote?.work == work }) {
                return .failure(.init(message: "На сервере остался незабранный результат прошлого запуска — сначала повтори его («Повторить»)"))
            }
            // The plan was made in a copy of its own.
            if let old = job.remote, old.work != work { RemoteCleanup.shared.release(work: old.work) }
            job.remote = RemoteRun(server: server, id: RemoteRun.newID(), work: work, project: RemoteRun.key(job.cwd.path))
        }
        saveNow()
        let setup = WorktreeScripts.load(projectAt: job.cwd).setup
        return .success(AgentRemote(
            run: job.remote!, attach: attach, main: job.cwd, taskPath: job.taskPath.map { URL(fileURLWithPath: $0) },
            returnsTask: job.kind != .review, branch: job.worktree?.branch ?? "",
            setup: !setup.isEmpty && ScriptStore.approvals.isApproved(.setup, setup, project: job.cwd) ? setup : ""))
    }

    func watchRemote(_ job: Job, _ p: any RemoteAgentRun) {
        // The offset is saved together with the log lines it covers.
        p.onOffset = { [weak self, weak job] n in
            job?.remote?.offset = n
            self?.save()
        }
        p.onReturned = { [weak self, weak job] in
            job?.remote?.returned = true
            self?.saveNow()
        }
    }
}
