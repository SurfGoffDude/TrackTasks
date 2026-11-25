import Foundation
import TrackTasksCore

extension Worktrees.Info {
    var checkpointSite: Checkpoints.Site { .init(folder: path, branch: branch, links: Set(Worktrees.links(of: path))) }
}

extension JobQueue {
    // MARK: Checkpoints and rollback

    nonisolated static var claudeProjects: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".claude/projects")
    }

    /// Reads the session's file: off the main actor.
    nonisolated static func point(_ session: String?) -> String? {
        session.flatMap { SessionLog.file(session: $0, in: claudeProjects) }.flatMap(SessionLog.lastAssistant(path:))
    }

    /// Name of the turn in the checkpoint list.
    static func turnLabel(_ job: Job, resumes: Bool) -> String {
        func short(_ s: String) -> String { String(s.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(100)) }
        return switch job.kind {
        case .reply: "Ответ: " + short(job.prompt)
        case .runTask: job.forkSession != nil && job.sessionID == nil ? "Ответвление: " + short(job.prompt)
            : resumes ? "Продолжение" : "Первый запуск"
        default: short(job.title)
        }
    }

    /// Saves the worktree before a turn, then calls `go` on the main actor. The job holds its slot meanwhile.
    /// A failed checkpoint doesn't stop the turn, the reason goes to the log.
    func checkpointThen(_ job: Job, _ w: Worktrees.Info, label: String, resume: String?, resumeAt: String?, go: @escaping @MainActor @Sendable () -> Void) {
        let wasRunning = job.state == .running
        job.state = .running
        job.checkpointing = true
        job.lastLine = "Сохраняю чекпоинт…"
        if !wasRunning { onStarted?(job) }
        let parts = group(job).parts
        let sites = [w.checkpointSite] + parts.compactMap { $0.worktree?.checkpointSite }
        let turn = parts.isEmpty ? nil : UUID().uuidString
        Task.detached(priority: .userInitiated) { [weak self] in
            var errors: [String] = []
            let meta = Checkpoints.Meta(kind: .turn, label: label, session: resume, point: resumeAt ?? Self.point(resume), turn: turn)
            for site in sites {
                do { try Checkpoints.create(site, meta, git: DiffLoader.runEnv) } catch let e { errors.append(e.localizedDescription) }
            }
            let failed = errors.isEmpty ? nil : errors.joined(separator: "; ")
            await self?.checkpointReady(job, failed, go)
        }
    }

    private func checkpointReady(_ job: Job, _ error: String?, _ go: @MainActor () -> Void) {
        job.checkpointing = false
        if let error { job.log.append("⚙︎ Чекпоинт не сохранён: \(error)") }
        if job.cancelRequested {
            job.cancelRequested = false
            cancelledBeforeTurn(job)
        } else {
            go()
        }
    }

    func checkpoints(_ w: Worktrees.Info) async -> Result<[Checkpoints.Checkpoint], Checkpoints.Failure> {
        await Task.detached(priority: .userInitiated) {
            do { return .success(try Checkpoints.list(branch: w.branch, in: w.main, git: DiffLoader.runEnv)) }
            catch { return .failure(Checkpoints.Failure(error.localizedDescription)) }
        }.value
    }

    func rollbackBlocked(_ job: Job) -> String? { rejectBlocked(DiffSource(job: job)) }

    /// Puts the worktree's files back to the checkpoint; the current state becomes a checkpoint first.
    /// `talk`: the next message continues the conversation from that point in a new session.
    /// Returns an error text; nil = done.
    func rollback(_ job: Job, to c: Checkpoints.Checkpoint, talk: Bool) async -> String? {
        guard let w = job.worktree, !job.isFollowUp, !(talk && !canRewind(job, c)) else { return "Откат недоступен" }
        if let p = job.parts.first(where: { $0.worktree == nil }) { return "Репозиторий «\(p.repoName)» уже слит — откатить задачу целиком нельзя" }
        let site = w.checkpointSite, now = job.rewind, session = job.sessionID
        let box = ResultBox()
        let base = job.baseCommit
        let others = job.parts.compactMap { p in p.worktree.map { (name: p.repoName, w: $0, base: p.baseCommit) } }
        let turn = others.isEmpty ? nil : UUID().uuidString
        let error = await changeWorktree(DiffSource(job: job), note: "Откат к чекпоинту №\(c.number)") {
            // Files of an older checkpoint don't have main that was merged into the branch later: the rollback would undo it.
            if !base.isEmpty, !Worktrees.git(["merge-base", "--is-ancestor", base, c.oid], in: site.folder).ok {
                throw Checkpoints.Failure("После этого чекпоинта в ветку влили основную ветку — откат убрал бы чужие правки")
            }
            // Every repository is checked before the first one changes.
            var targets: [Checkpoints.Checkpoint] = []
            for o in others {
                guard let t = c.meta.turn, let same = try Checkpoints.list(branch: o.w.branch, in: o.w.main, git: DiffLoader.runEnv).last(where: { $0.meta.turn == t }) else {
                    throw Checkpoints.Failure("В репозитории «\(o.name)» нет снимка этого хода — откат не начат")
                }
                if !o.base.isEmpty, !Worktrees.git(["merge-base", "--is-ancestor", o.base, same.oid], in: o.w.path).ok {
                    throw Checkpoints.Failure("После этого чекпоинта в ветку «\(o.name)» влили основную ветку — откат убрал бы чужие правки")
                }
                targets.append(same)
            }
            let here = now ?? SessionRewind(session: session, point: Self.point(session))
            let meta = Checkpoints.Meta(kind: .rollback, label: "Перед откатом к №\(c.number)", session: here.session, point: here.point, turn: turn)
            box.matchesHead = try Checkpoints.restore(site, to: c, before: meta, git: DiffLoader.runEnv).matchesHead
            for (o, t) in zip(others, targets) {
                do { box.others.append(try Checkpoints.restore(o.w.checkpointSite, to: t, before: meta, git: DiffLoader.runEnv).matchesHead) }
                catch { box.failed = "Откат прерван на репозитории «\(o.name)»: \(error.localizedDescription). Вернуть остальные можно чекпоинтом «\(meta.label)»"; break }
            }
        }
        if let error { return error }
        let matches = box.matchesHead
        job.mergeArtifacts = []
        job.rolledBack = matches ? "" : "№\(c.number) «\(c.meta.label)»"
        // Told to the agent with the next message, unless its conversation goes back too.
        job.rollbackNotice = talk ? "" : "№\(c.number) «\(c.meta.label)»"
        for (p, same) in zip(job.parts, box.others) {
            p.mergeArtifacts = []
            p.mergeCheck = nil
            p.rolledBack = same ? "" : "№\(c.number) «\(c.meta.label)»"
        }
        if talk, box.failed == nil { job.rewind = SessionRewind(session: c.meta.session, point: c.meta.point) }
        // The old verdict and check are about other code.
        job.review = ""
        job.verdict = nil
        job.reviewFixed = false
        job.verifyNote = ""
        job.verifyFailed = false
        job.worktreeNote = "Откат к чекпоинту №\(c.number). "
            + (matches ? "Код совпадает с веткой." : "Ветка не изменена: откат — незакоммиченные правки в worktree.")
        save()
        return box.failed
    }

    /// Commits the rolled back files to the task's branch — only when the user asks.
    func commitRollback(_ job: Job) async -> String? {
        for p in job.parts where !p.rolledBack.isEmpty {
            if let error = await commitRollback(p) { return "\(p.repoName): \(error)" }
        }
        guard let w = job.worktree, !job.rolledBack.isEmpty else { return nil }
        let message = "TrackTasks: откат к чекпоинту \(job.rolledBack)"
        let error = await changeWorktree(DiffSource(job: job), note: "Откат закоммичен в \(w.branch)") {
            let r = Worktrees.commitAll(w, message: message)
            if !r.ok { throw Checkpoints.Failure(r.message) }
        }
        if error == nil {
            job.rolledBack = ""
            job.mergeArtifacts = []
            save()
        }
        return error
    }

    /// The conversation can go back to this checkpoint too.
    func canRewind(_ job: Job, _ c: Checkpoints.Checkpoint) -> Bool {
        c.meta.canRewind && (c.meta.session == nil || capabilities(job).contains(.resumeAt))
    }

    func cancelRewind(_ job: Job) {
        job.rewind = nil
        save()
    }

    private final class ResultBox: @unchecked Sendable {
        var matchesHead = false
        var others: [Bool] = []
        var failed: String?
    }

    /// A rolled back code that isn't in the branch yet would be lost by a merge.
    static let uncommittedRollback = "откат не закоммичен в ветку — «Закоммитить откат» или ответь агенту"

    /// First message after a rollback: what the agent must know besides the text.
    func replyPrompt(_ job: Job, parent: Job) -> String? {
        if let r = parent.rewind {
            guard r.session == nil else { return nil }
            let task = parent.planPhase == .approved ? ClaudePrompts.approved(parent.prompt) : parent.prompt
            return task + "\n\nРабота начата заново, дополнительное указание пользователя:\n" + job.prompt
        }
        guard !parent.rollbackNotice.isEmpty else { return nil }
        return "Пользователь вернул файлы worktree к чекпоинту \(parent.rollbackNotice): они могут отличаться от того, что ты помнишь, "
            + "перечитай их перед работой.\n\n" + job.prompt
    }
}
