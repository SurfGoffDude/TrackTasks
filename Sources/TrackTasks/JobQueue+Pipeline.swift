import Foundation
import TrackTasksCore

/// Pipelines: `Pipeline.next` (core) chooses the step, the queue carries it out. Plan and code run in the task's own
/// job, review and fix are its follow-up jobs. No step merges anything.
extension Job {
    /// The pipeline has steps left or waits for the person.
    var pipelineOpen: Bool { home.pipeline?.isOpen ?? false }
    var isPipelineReview: Bool { kind == .review && !pipelineStep.isEmpty }
    /// The code is compared before and after the review. An ACP agent may edit without asking in any of them.
    var guardsReview: Bool { isPipelineReview || (kind == .review && agent == .acp) }
}

extension JobQueue {
    /// The task whose pipeline this job belongs to: itself or its parent.
    func pipelineTask(_ job: Job) -> Job? {
        if job.pipeline != nil { return job }
        guard let p = self.job(job.parentID), p.pipeline != nil else { return nil }
        return p
    }

    /// Step the job carries out now.
    func pipelineStep(_ job: Job) -> Workflow.Step? {
        if let s = job.pipeline {
            guard let step = s.step, step.type == .plan || step.type == .code else { return nil }
            return step
        }
        guard !job.pipelineStep.isEmpty else { return nil }
        return self.job(job.parentID)?.pipeline?.workflow.steps.first { $0.title == job.pipelineStep }
    }

    /// Reason for the planner and the row: the task isn't started until the person decides.
    func pipelineHold(_ job: Job) -> String? {
        guard job.state == .pending, !job.awaitingPlan, case .stopped(let g)? = job.pipeline?.status else { return nil }
        return g.reason
    }

    /// Before the job is added to the queue.
    func beginPipeline(_ job: Job, name: String, workflow: Workflow) {
        job.fromPipeline = true
        job.planPhase = nil
        job.pipeline = PipelineState(name: name, workflow: workflow, taskProfile: job.profile)
        pipelineEvent(job, .begin)
    }

    func pipelineEvent(_ job: Job, _ event: Pipeline.Event) {
        guard var s = job.pipeline else { return }
        let action = Pipeline.next(&s, event)
        job.pipeline = s
        switch action {
        case .none: break
        case .start(let i):
            let step = s.workflow.steps[i]
            job.log.append("⚙︎ Пайплайн: шаг «\(step.title)» (\(step.type.title.lowercased())), заход \(s.visits[i])")
            switch step.type {
            case .plan, .code: enterStep(job, step, repeated: s.visits[i] > 1)
            case .review:
                if !requestReview(job, step: step) { pipelineEvent(job, .failed("ревью сейчас не начать (терминал или операция с веткой)")) }
            case .fix:
                if !requestFix(job, step: step) { pipelineEvent(job, .failed("исправление сейчас не начать (терминал или операция с веткой)")) }
            }
        case .gate(let why):
            job.log.append("⚙︎ Пайплайн остановлен: \(why)")
            if job.awaitingPlan {
                // The plan's own stop has its card and notification.
                if s.gate?.kind == .after { break }
                job.planPhase = .approved
            }
            // The questions have their own notification.
            if why == Pipeline.awaitsAnswersReason { break }
            PhonePush.send(.permission, job: job)
            Notifier.shared.post(title: "Пайплайн ждёт решения", body: "\(job.projectName): \(job.title). \(why)", jobID: job.id)
        case .finished:
            job.log.append("⚙︎ Пайплайн завершён")
            PhonePush.send(.done, job: job, verifyFailed: job.verifyFailed)
            Notifier.shared.post(title: "Пайплайн завершён", body: "\(job.projectName): \(job.title)", jobID: job.id,
                                 canMerge: job.awaitsMerge && !job.hasLivePR)
        }
        save()
    }

    /// Plan and code run in the task's job. Another agent never gets the session of the previous one.
    private func enterStep(_ job: Job, _ step: Workflow.Step, repeated: Bool) {
        let before = job.agent, beforeServer = job.server, beforeACP = job.acp, wasDone = job.state == .done
        let name = step.agent.isEmpty ? job.pipeline?.taskProfile ?? "" : step.agent
        let p = profiles().resolve(name)
        job.profile = name
        job.agent = p?.agent
        job.server = p?.server
        job.acp = p?.acp
        if beforeACP != job.acp { job.acpFeatures = nil }
        releasePlanCopy(job)
        job.profileModel = p.map { step.model.isEmpty ? $0.model : step.model } ?? ""
        job.model = nil
        job.modelReason = ""
        // Claude keeps sessions per folder, so the code run never continues the plan's one either.
        if let p, before == p.agent, beforeServer == p.server, beforeACP == p.acp, repeated, step.type == .plan || job.worktree != nil {
            if wasDone { job.resumeSession = job.sessionID }
        } else {
            job.sessionID = nil
            job.resumeSession = nil
            job.rewind = nil
        }
        if step.type == .plan {
            job.planPhase = .planning
            job.planBaseline = nil
            job.planFeedback = ""
        } else if job.planPhase != nil {
            job.planPhase = .approved
        }
        guard wasDone else { return }
        job.state = .pending
        job.finishedAt = nil
        job.interrupted = false
        job.verifyAttempts = 0
        job.verifyFailed = false
        job.verifyNote = ""
        job.worktreeNote = ""
        job.review = ""
        job.verdict = nil
        job.reviewFixed = false
        for m in job.members { m.mergeCheck = nil }
        if job.worktree == nil {
            job.baseCommit = ""
            job.setupDone = false
            job.worktreeUnavailable = false
        }
    }

    /// The copy on a server where a plan was made, when the next step isn't done there.
    private func releasePlanCopy(_ job: Job) {
        guard let r = job.remote, !job.remoteUnclaimed, r.server != job.server,
              job.worktree.map({ RemoteRun.key($0.path.path) }) != r.work else { return }
        RemoteCleanup.shared.release(work: r.work)
        job.remote = nil
    }

    /// «↻» of a follow-up whose run is still on its server: `j` continues watching it in the same step.
    func reattachStep(_ old: Job, _ j: Job) {
        guard !old.pipelineStep.isEmpty, let task = job(old.parentID), let s = task.pipeline else { return }
        j.pipelineStep = old.pipelineStep
        // A finished review has given its folder back.
        if j.worktree == nil { j.worktree = task.worktree }
        j.baseCommit = task.baseCommit
        j.model = old.model
        guard s.step?.title == old.pipelineStep, s.gate?.kind == .trouble else { return }
        pipelineEvent(task, .reattach)
        task.pipeline?.child = j.id
    }

    /// Follow-up of a step: its own agent and model. An unknown profile fails at the start, never another agent.
    func useStep(_ child: Job, _ step: Workflow.Step, of task: Job) {
        child.pipelineStep = step.title
        child.profile = step.agent.isEmpty ? task.pipeline?.taskProfile ?? "" : step.agent
        let p = profiles().resolve(child.profile)
        child.agent = p?.agent
        child.server = p?.server
        child.acp = p?.acp
        if child.acp != task.acp { child.acpFeatures = nil }
        child.profileModel = p.map { step.model.isEmpty ? $0.model : step.model } ?? ""
        child.model = p?.agent == task.agent ? task.model : nil
        task.pipeline?.child = child.id
    }

    /// Text of the step for the agent.
    func stepPrompt(_ job: Job) -> String {
        guard let step = pipelineStep(job) else { return "" }
        var out = ""
        if step.type == .code, let s = job.pipeline, s.visits.indices.contains(s.current), s.visits[s.current] > 1 {
            out += "\n\nШаг повторяется: в worktree может быть уже сделанная работа — проверь её и доведи до конца."
        }
        if !step.text.isEmpty { out += "\n\nУказания шага «\(step.title)»:\n\(step.text)" }
        return out
    }

    /// A run of the job ended; `changed`: its commit got into the branch.
    func pipelineStepEnded(_ job: Job, _ state: Job.State, changed: Bool, commitError: String?) {
        guard let task = pipelineTask(job) else { return }
        let failure: Pipeline.Event? = switch state {
        case .done: commitError.map { .failed("не удалось закоммитить: " + $0) }
        case .cancelled: .failed("остановлено")
        default: .failed(job.lastLine)
        }
        if task === job {
            if let failure { return pipelineEvent(task, failure) }
            let committed = job.members.contains(where: \.committed)
            if job.questions?.open.isEmpty == false { return pipelineEvent(task, .questions(changed: committed)) }
            guard committed else { return pipelineEvent(task, .nothingChanged) }
            return pipelineEvent(task, job.verifyFailed ? .verifyRed : .succeeded)
        }
        if task.pipeline?.child == job.id {
            if let failure { return pipelineEvent(task, failure) }
            if job.kind == .review {
                return pipelineEvent(task, job.reviewTampered ? .tampered : .verdict(ok: Pipeline.verdict(task.review)))
            }
            if !changed { return pipelineEvent(task, .nothingChanged) }
            return pipelineEvent(task, job.verifyFailed ? .verifyRed : .succeeded)
        }
        // A reply, a conflict or check repair. An unfinished one may have left edits too.
        guard job.isFollowUp, job.isCodeTask else { return }
        let completed = state == .done && task.pipeline?.status == .running
        if changed || completed || (state != .done && job.sessionID != nil) {
            task.verdict = nil
            pipelineEvent(task, .changedOutside)
        } else if state == .done, task.questions?.waits != true {
            pipelineEvent(task, .answered)
        }
    }

    /// Follow-ups that ended without `finish`: cancelled in the queue, not started, cut off by the end of the app.
    func settlePipelines() {
        for task in jobs where task.state == .done && task.pipeline?.status == .running {
            guard let s = task.pipeline, s.step?.type == .review || s.step?.type == .fix else { continue }
            let child = job(s.child)
            if child?.isActive == true { continue }
            pipelineEvent(task, .failed(child.map { $0.lastLine.isEmpty ? "остановлено" : $0.lastLine } ?? "прервано"))
        }
    }

    /// «↻» of a task: the cut off step is repeated, not the whole pipeline; a finished one starts anew.
    /// Work already in the worktree stays.
    func retryPipeline(_ s: PipelineState, _ old: Job, _ j: Job) {
        let anew = old.state == .done
        j.pipeline = anew ? s.restarted() : s
        j.fromPipeline = true
        j.alwaysWorktree = false
        if anew {
            j.planPhase = nil
            j.profile = s.taskProfile
            return
        }
        if j.worktree == nil, let w = old.worktree, FileManager.default.fileExists(atPath: w.path.path) {
            old.moveWorktrees(to: j)
        }
        j.committed = old.committed && j.worktree != nil
        // Continuing without its folder would lead to the main one.
        if j.worktree == nil, s.step?.type != .plan {
            j.resumeSession = nil
            j.rewind = nil
        }
    }

    // MARK: The person's decisions

    /// Why the pipeline can't be moved now; nil = can.
    func pipelineBlocked(_ job: Job) -> String? {
        if job.state != .done && job.state != .pending { return "задача не завершена — повтори её («Повторить»)" }
        if job.worktreeBusy { return "с веткой сейчас что-то делают" }
        if hasActiveChild(job) { return "идёт ответ, ревью, исправление или Claude в терминале карточки" }
        if !job.rolledBack.isEmpty { return Self.uncommittedRollback }
        return nil
    }

    func pipelineContinue(_ job: Job) { decide(job, .userContinue) }
    func pipelineRepeat(_ job: Job) {
        // The server still has the run: a second one in the same copy is not allowed.
        if pipelineBlocked(job) == nil, job.pipeline?.gate?.kind == .trouble,
           let left = jobs.last(where: { $0.parentID == job.id && !$0.isActive && $0.remoteUnclaimed && $0.pipelineStep == job.pipeline?.step?.title }) {
            return retry(left)
        }
        decide(job, .userRepeat)
    }
    /// Only after the code: before it there is nothing to merge, the task is cancelled instead.
    func pipelineFinish(_ job: Job) { if job.state == .done { decide(job, .userFinish) } }

    private func decide(_ job: Job, _ event: Pipeline.Event) {
        guard !job.awaitingPlan, pipelineBlocked(job) == nil else { return }
        pipelineEvent(job, event)
        pump()
    }

    // MARK: A reviewer must not change code

    /// All repositories of the task.
    nonisolated private static func reviewFingerprint(_ dirs: [URL]) -> String? {
        var out = ""
        for dir in dirs {
            guard let head = Git.run(["rev-parse", "HEAD"], in: dir), let code = codeFingerprint(dir) else { return nil }
            out += head + code + "\n"
        }
        return out
    }

    private func reviewFolders(_ job: Job) -> [URL] { [job.runDir] + group(job).parts.compactMap(\.worktree?.path) }

    func snapshotThenReview(_ job: Job) {
        job.state = .running
        job.lastLine = "Запоминаю состояние кода перед ревью…"
        onStarted?(job)
        let dirs = reviewFolders(job)
        Task.detached(priority: .userInitiated) { [weak self] in
            let f = Self.reviewFingerprint(dirs)
            await self?.reviewBaselineReady(job, f)
        }
    }

    private func reviewBaselineReady(_ job: Job, _ fingerprint: String?) {
        guard job.state == .running else { return }
        guard let fingerprint else {
            job.lastLine = "Не удалось снять состояние кода (git)"
            return finish(job, .failed)
        }
        job.planBaseline = fingerprint
        start(job)
    }

    func reviewRunFinished(_ job: Job, text: String) {
        // A server works on its own copy of the code and a review returns nothing.
        if capabilities(job).contains(.remote) { return reviewChecked(job, text, job.planBaseline) }
        let dirs = reviewFolders(job)
        Task.detached(priority: .userInitiated) { [weak self] in
            let f = Self.reviewFingerprint(dirs)
            await self?.reviewChecked(job, text, f)
        }
    }

    private func reviewChecked(_ job: Job, _ text: String, _ after: String?) {
        job.reviewTampered = after != job.planBaseline
        if job.reviewTampered, !job.isPipelineReview {
            job.lastLine = "Ревью изменило код — вывод не принят, проверь diff ветки"
            return finish(job, .failed)
        }
        applyReview(job, text: text)
        if let parent = self.job(job.parentID) {
            parent.verdict = job.reviewTampered ? nil : Pipeline.verdict(parent.review).map { $0 ? .ok : .issues }
        }
        finish(job, .done)
    }
}
