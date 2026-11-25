import Foundation
import TrackTasksCore

extension JobQueue {
    // MARK: Review / fix

    static let autoReviewKey = "autoReview"
    static var autoReview: Bool { UserDefaults.standard.object(forKey: autoReviewKey) as? Bool ?? true }

    func requestReview(_ task: Job) { requestReview(task, step: nil) }

    /// `step`: a step of the task's pipeline; while it goes on there are no other reviews.
    @discardableResult
    func requestReview(_ task: Job, step: Workflow.Step?) -> Bool {
        guard task.kind == .runTask, task.state == .done, !task.worktreeBusy,
              !jobs.contains(where: { $0.parentID == task.id && $0.kind == .review && $0.isActive }),
              step == nil ? !task.pipelineOpen : !hasActiveChild(task) else { return false }
        let j = Job(kind: .review, title: "Ревью: \(task.title)", projectID: task.projectID, projectName: task.projectName,
                    cwd: task.cwd, prompt: ClaudePrompts.review(task: task) + ClaudePrompts.reposDiff(task),
                    systemPrompt: ClaudePrompts.reviewSystem(name: task.projectName, path: task.cwd.path),
                    taskPath: task.taskPath)
        j.parentID = task.id
        j.useAgent(of: task)
        if let step { useStep(j, step, of: task) }
        j.worktree = task.worktree
        j.baseCommit = task.baseCommit
        task.review = ""
        task.verdict = nil
        add(j)
        return true
    }

    /// An agent that works only in a worktree can't fix the main folder.
    func canFix(_ task: Job) -> Bool { task.worktree != nil || !requiresWorktree(task) }

    func requestFix(_ task: Job) { requestFix(task, step: nil) }

    @discardableResult
    func requestFix(_ task: Job, step: Workflow.Step?) -> Bool {
        guard canFix(task), !task.review.isEmpty, !task.worktreeBusy, !hasActiveChild(task),
              step != nil || !task.pipelineOpen else { return false }
        let j = Job(kind: .fix, title: "Исправление: \(task.title)", projectID: task.projectID, projectName: task.projectName,
                    cwd: task.cwd, prompt: ClaudePrompts.fix(task: task),
                    systemPrompt: task.systemPrompt, taskPath: task.taskPath)
        j.parentID = task.id
        j.useAgent(of: task)
        j.worktree = task.worktree
        j.baseCommit = task.baseCommit
        j.mustUseMain = task.worktree == nil
        j.verifyCommand = task.verifyCommand
        j.model = task.model
        if let step { useStep(j, step, of: task) }
        add(j)
        return true
    }

    /// A fix continues the task's own claude session (it already knows the project and the change),
    /// when that session ran in the same folder — claude keeps sessions per working directory.
    /// Another agent's fix starts anew.
    func fixSession(_ job: Job) -> String? {
        guard capabilities(job).contains(.resume), job.resumeSession == nil, let parent = self.job(job.parentID), parent.rewind == nil, parent.agentID == job.agentID, parent.server == job.server, parent.acp == job.acp, let sid = parent.sessionID,
              parent.runDir.standardizedFileURL.path == job.runDir.standardizedFileURL.path else { return nil }
        job.log.append("⚙︎ Продолжает сессию задачи (--resume \(sid.prefix(8))…)")
        return sid
    }

    /// Model for a fix whose task has no recorded model (e.g. restored old queue): heuristic, Sonnet when unclear.
    func fixModel(_ job: Job) -> ClaudeModel {
        guard Self.autoModel, job.profileModel.isEmpty, capabilities(job).contains(.autoModel) else { return .current }
        let t = job.taskPath.flatMap { Codec.task(at: URL(fileURLWithPath: $0)) }
        switch ModelPick.heuristic(title: t?.title ?? job.title, body: t?.body ?? "", size: t?.size ?? "") {
        case .opus(let why): job.modelReason = why; return .opus
        case .sonnet(let why): job.modelReason = why; return .sonnet
        case .ask: return .sonnet
        }
    }

    func applyReview(_ job: Job, text: String) {
        guard let parent = self.job(job.parentID) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        parent.review = t
        let head = t.prefix(200).uppercased()
        parent.verdict = head.contains("ВЕРДИКТ: ОК") || head.contains("ВЕРДИКТ: OK") ? .ok : .issues
        parent.reviewFixed = false
    }
}
