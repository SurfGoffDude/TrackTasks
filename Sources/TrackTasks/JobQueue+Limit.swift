import Foundation
import TrackTasksCore

/// A job stopped by the subscription limit: the same job waits (pending) and goes on in its session after the reset.
extension JobQueue {
    /// The run ended with a refusal of the limit. Not an ordinary failure: no commit, no review, dependents wait.
    func limitRefused(_ job: Job, _ s: AgentRunResult, _ limit: RunLimit) {
        // A new session would be refused too.
        job.resumedParent = false
        if job.stopAsked { return finish(job, .cancelled) }
        let now = now()
        if let why = LimitWait.refusal(limit, session: job.sessionID, canResume: capabilities(job).contains(.resume),
                                       retried: job.limitRetried, now: now) {
            job.lastLine = why + (job.kind == .reply ? "" : " («Продолжить»)") + ". " + s.errorText
            job.interrupted = true
            return finish(job, .failed)
        }
        guard let reset = limit.resetsAt, let session = job.sessionID else { return }
        job.limitWait = LimitWait(window: limit.window, resetsAt: reset, session: session, planBaseline: job.planBaseline,
                                  planShared: job.planFolderShared ? true : nil)
        job.state = .pending
        let when = LimitWait.clock(reset, now: now)
        job.lastLine = "\(limit.title) исчерпан — продолжу ту же сессию после сброса в \(when)"
        job.log.append("⚙︎ " + job.lastLine)
        Notifier.shared.post(title: "\(limit.title) исчерпан", body: "\(job.projectName): \(job.title). Продолжу после сброса в \(when)", jobID: job.id)
        saveNow()
        pump()
    }

    /// The window has reset. The mark is on disk before the process: a crash in between loses the retry, but never doubles it.
    func continueAfterLimit(_ job: Job, _ w: LimitWait) {
        job.limitRetried = w.resetsAt
        saveNow()
        job.limitWait = nil
        job.resumeSession = w.session
        job.log.append("⚙︎ Лимит сброшен, продолжает сессию \(w.session.prefix(8))…")
        guard capabilities(job).contains(.resume), FileManager.default.fileExists(atPath: job.runDir.path) else {
            job.lastLine = "Продолжить после лимита нельзя: нет папки или агент не продолжает сессии"
            job.interrupted = true
            return finish(job, .failed)
        }
        launch(job, model: job.model ?? .auto)
        // Not started: ↻ still goes on in this session.
        if job.state == .failed { job.interrupted = true }
    }

    /// A code run starts in the folder where a plan waits for the limit: whose edits are there isn't known any more.
    func folderUsed(by job: Job) {
        for j in jobs where j !== job && j.limitWait != nil && j.planPhase == .planning && job.worktree == nil && j.worktree == nil && j.cwd == job.cwd {
            j.planFolderShared = true
            j.limitWait?.planShared = true
        }
    }
}
