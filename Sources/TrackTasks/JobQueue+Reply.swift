import Foundation
import TrackTasksCore

extension JobQueue {
    // MARK: Reply to the agent

    /// Why the user can't answer this job's agent now; nil = can.
    func replyBlocked(_ job: Job) -> String? {
        if job.answering { return "Отправляются ответы на вопросы агента" }
        if Terminals.shared.claudeRunning(job) { return "В этой сессии открыт Claude в терминале карточки — закрой его вкладку" }
        if job.sessionID != nil, !capabilities(job).contains(.resume) { return "Агент этой задачи не продолжает сессии" }
        if job.worktree == nil, worktreeOnly(job) { return "\(agentTitle(job)) работает только в worktree, а у задачи его нет" }
        if job.worktree == nil, job.kind != .updateAbout, job.kind != .quickAdd, job.kind != .review, requiresWorktree(job) {
            return "\(agentTitle(job)) правит код только в worktree, а у задачи его нет"
        }
        // `baseCommit` is set only for jobs that ran in a worktree and stays after its removal.
        return AgentReply.blocked(isActive: job.isActive, hasSession: job.sessionID != nil,
                           ranInWorktree: job.worktree != nil || !job.baseCommit.isEmpty,
                           hasWorktree: job.worktree != nil, merged: job.fullyMerged,
                           worktreeBusy: job.worktreeBusy, hasActiveChild: hasActiveChild(job))
    }

    /// Send a message to the finished job's session: a child job with `--resume` in the same folder.
    /// Returns false (and leaves the caller's text alone) when it can't be sent.
    @discardableResult
    func sendReply(_ target: Job, text: String, remote: RemoteRun? = nil, comments: SentComments? = nil,
                   preview: SentPreview? = nil, repeats: AgentReply? = nil) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, replyBlocked(target) == nil else { return false }
        let j = Job(kind: .reply, title: "Ответ: \(target.title)", projectID: target.projectID, projectName: target.projectName,
                    cwd: target.cwd, prompt: text, systemPrompt: target.systemPrompt, taskPath: target.taskPath)
        j.parentID = target.id
        j.useAgent(of: target)
        j.lightReply = target.lane == .light
        j.worktree = target.worktree
        j.baseCommit = target.baseCommit
        j.mustUseMain = target.worktree == nil
        j.verifyCommand = target.verifyCommand
        j.model = target.model
        j.remote = remote
        j.sessionID = remote == nil ? nil : target.sessionID
        var reply = AgentReply(id: j.id, text: text)
        reply.drafts = comments?.key ?? repeats?.drafts
        reply.preview = preview?.draft ?? repeats?.preview
        reply.shots = preview.map { [$0.shot] } ?? repeats?.shots
        target.replies.append(reply)
        // Before the start: it may fail at once.
        if let comments { drafts.change(comments.key) { DiffComments.markSent(comments.list, reply: j.id, in: &$0) } }
        if let repeats, let key = repeats.drafts { drafts.change(key) { DiffComments.markSent($0.filter { $0.delivery?.reply == repeats.id }, reply: j.id, in: &$0) } }
        if let id = reply.preview { previews.markSent(target.id, id, reply: j.id) }
        add(j)
        return true
    }

    struct SentComments {
        var key: String
        var list: [DiffComment]
    }

    struct SentPreview {
        var draft: UUID
        /// Already in `PreviewFolder` of the worktree.
        var shot: String
    }

    /// Snapshots of the message this job carries.
    func shots(_ job: Job) -> [String] {
        guard let (parent, i) = replyEntry(job) else { return [] }
        return parent.replies[i].shots ?? []
    }

    // MARK: Delivery

    /// The agent has the message: drafts of its comments aren't needed any more.
    func replyAccepted(_ job: Job) {
        guard let (parent, i) = replyEntry(job), parent.replies[i].delivery != .accepted else { return }
        parent.replies[i].delivery = .accepted
        // First the queue: drafts left by a crash are removed when their diff is opened.
        saveNow()
        settleDrafts(parent.replies[i])
    }

    /// false: marked before.
    func markLaunched(_ job: Job) -> Bool {
        guard let (parent, i) = replyEntry(job), parent.replies[i].delivery == nil else { return false }
        parent.replies[i].delivery = .launched
        saveNow()
        return true
    }

    func unmarkLaunched(_ job: Job) {
        guard let (parent, i) = replyEntry(job), parent.replies[i].delivery == .launched else { return }
        parent.replies[i].delivery = nil
    }

    private func replyEntry(_ job: Job) -> (Job, Int)? {
        guard job.kind == .reply, let parent = self.job(job.parentID),
              let i = parent.replies.firstIndex(where: { $0.id == job.id }) else { return nil }
        return (parent, i)
    }

    private func settleDrafts(_ r: AgentReply) {
        let state = r.draftState(active: job(r.id)?.isActive == true)
        if let id = r.preview, let owner = job(r.id)?.parentID { previews.settle(owner, id, reply: r.id, state) }
        guard let key = r.drafts else { return }
        drafts.change(key) { DiffComments.settle(r.id, state, in: &$0) }
    }

    /// The diff is opened: drafts that were being sent when the app quit. Nothing is sent again.
    func openDrafts(_ key: String) {
        drafts.open(key)
        let replies = jobs.flatMap(\.replies)
        for id in Set(drafts.comments(key).compactMap { $0.delivery?.reply }) {
            let state: DiffDelivery.State?
            if let r = replies.first(where: { $0.id == id }) { state = r.draftState(active: job(id)?.isActive == true) }
            // Its card is gone.
            else if drafts.comments(key).contains(where: { $0.delivery?.reply == id && $0.delivery?.state == .failed }) { continue }
            else { state = .unclear }
            drafts.change(key) { DiffComments.settle(id, state, in: &$0) }
        }
    }

    /// The preview is opened: a draft that was being sent when the app quit. Nothing is sent again.
    func openPreviewDraft(_ job: Job) {
        previews.open(job.id)
        guard let d = previews.draft(job.id), let sent = d.delivery else { return }
        if let r = job.replies.first(where: { $0.id == sent.reply }) {
            previews.settle(job.id, d.id, reply: sent.reply, r.draftState(active: self.job(r.id)?.isActive == true))
        } else if sent.state == .sending { previews.settle(job.id, d.id, reply: sent.reply, .unclear) }
    }

    /// Send a failed or cancelled message again.
    func repeatReply(_ target: Job, _ reply: AgentReply) {
        guard reply.canRepeat else { return }
        // A message that is already on the server isn't sent again: its run is continued.
        let old = job(reply.id)
        guard sendReply(target, text: reply.text, remote: old?.remoteUnclaimed == true ? old?.remote : nil, repeats: reply) else { return }
        if old?.remoteUnclaimed == true { old?.remote?.returned = true }
        if target.questions?.sending == reply.id { target.questions?.sending = target.replies.last?.id }
        target.replies.removeAll { $0.id == reply.id }
        save()
    }

    func startReply(_ job: Job) {
        guard let parent = self.job(job.parentID), let sid = parent.sessionID else {
            return failReply(job, "Не найдена задача или её сессия")
        }
        guard FileManager.default.fileExists(atPath: job.runDir.path) else {
            return failReply(job, "Папка сессии удалена: \(job.runDir.path)")
        }
        let model = job.lane == .light ? .background : (job.model ?? fixModel(job))
        let prompt = replyPrompt(job, parent: parent)
        if let r = parent.rewind {
            job.rewind = r
            job.log.append("⚙︎ Новая сессия с точки отката" + (r.session.map { " (сессия \($0.prefix(8))…)" } ?? ""))
            return launch(job, model: model, prompt: prompt, resume: r.session, fork: r.session != nil, resumeAt: r.point)
        }
        job.log.append("⚙︎ Продолжает сессию задачи (--resume \(sid.prefix(8))…)")
        launch(job, model: model, prompt: prompt, resume: sid)
    }

    private func failReply(_ job: Job, _ error: String) {
        job.lastLine = error
        finish(job, .failed)
    }

    /// The agent exited: keep the answer and follow the session id. A resume that never started gets no fresh
    /// session — the user is told instead — and its new id must not replace the working one.
    func replyExited(_ job: Job, _ s: AgentRunResult) {
        guard let parent = self.job(job.parentID) else { return }
        if s.gotResult, !s.failed, !s.stopped, s.turns > 0 { replyAccepted(job) }
        if s.failed, s.turns == 0, s.limit == nil {
            job.sessionID = nil
        } else if let sid = job.sessionID {
            // Stopped before the new session was written: the next message starts from the same point again.
            if job.rewind == nil || SessionLog.file(session: sid, in: Self.claudeProjects) != nil {
                parent.sessionID = sid
                parent.rewind = nil
                parent.rollbackNotice = ""
            }
        }
        let answer = s.resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.failed, !answer.isEmpty, let i = parent.replies.firstIndex(where: { $0.id == job.id }) {
            parent.replies[i].answer = answer
        }
    }

    /// Copy the final state of a reply job into its task's history. Call after `job.state` is final.
    func settleReply(_ job: Job) {
        guard job.kind == .reply else { return }
        // The worktree belongs to the task.
        job.worktree = nil
        guard let parent = self.job(job.parentID),
              let i = parent.replies.firstIndex(where: { $0.id == job.id }) else { return }
        switch job.state {
        case .pending, .running: break
        case .done: parent.replies[i].state = .done
        case .cancelled: parent.replies[i].state = .cancelled
        case .failed:
            parent.replies[i].state = .failed
            parent.replies[i].error = job.lastLine
        }
        settleDrafts(parent.replies[i])
    }

    /// After loading queue.json: messages that were running when the app quit are interrupted.
    func restoreReplies() {
        let active = Set(jobs.filter(\.isActive).map(\.id))
        for j in jobs where !j.replies.isEmpty {
            j.replies = AgentReply.restored(j.replies, activeJobs: active)
        }
        for j in jobs where j.kind == .reply && !j.isActive { j.worktree = nil }
    }
}
