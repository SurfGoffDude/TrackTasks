import Foundation
import TrackTasksCore

/// Text for the next agent and the state of the files it describes.
struct HandoffDraft: Sendable {
    let text: Handoff.Draft
    fileprivate let state: JobQueue.HandoffState
    /// Who had the job and which session, when it was made.
    fileprivate let from: Handoff.Side
    fileprivate let session: String?
    /// For the person only.
    let warnings: [String]
}

extension Job {
    /// Its folder is still there: a worktree, or the main folder it worked in.
    var runsInPlace: Bool { worktree.map { FileManager.default.fileExists(atPath: $0.path.path) } ?? !hadWorktree }
    var handoffSide: Handoff.Side { .init(profile: profile, agent: agentID, model: profileModel, server: server, acp: acp) }
    /// Agents before the current one.
    var handedFrom: String { handoffs.filter { $0.status == .accepted }.map(\.from.agent.rawValue).joined(separator: ", ") }
}

/// «Передать другому агенту»: the same job goes on with another agent in the same folder and branch. The previous
/// agent, its session and server are kept in `handoffs`; its session file isn't touched.
extension JobQueue {
    struct HandoffError: Error, Equatable { var message: String }

    struct HandoffState: Equatable, Sendable {
        /// Tree of every folder of the task.
        var trees: [String: String] = [:]
        var task = ""
    }

    private struct Site: Sendable {
        var name: String
        var folder: URL
        var worktree: Worktrees.Info?
        var base: String
    }

    private func sites(_ job: Job) -> [Site] {
        let list = job.worktree == nil ? [job] : job.members.filter { $0.worktree != nil }
        return list.map { Site(name: $0.repoName, folder: $0.runDir, worktree: $0.worktree, base: $0.baseCommit) }
    }

    // MARK: May it be handed over

    func handoffBlocked(_ job: Job) -> String? {
        guard jobs.contains(where: { $0 === job }) else { return "Задачи больше нет в очереди" }
        var f = Handoff.Facts()
        f.isTask = job.kind == .runTask
        f.state = JobFacts.State(rawValue: job.state.rawValue) ?? .failed
        f.limitWait = job.limitWait != nil
        f.started = job.agent != nil
        let path = job.worktree?.path.standardizedFileURL.path
        f.agentWorks = hasActiveChild(job) || jobs.contains { $0 !== job && $0.isActive && path != nil && $0.worktree?.path.standardizedFileURL.path == path }
        f.branchBusy = job.worktreeBusy
        f.merging = job.members.contains { $0.mergePhase != nil }
        f.gitBusy = folders(job).contains { gitBusy(around: $0) }
        f.pipeline = job.pipeline != nil
        f.planUnapproved = job.planPhase != nil && job.planPhase != .approved
        f.answering = job.answering
        f.remoteUnclaimed = job.remoteUnclaimed
        f.rolledBack = job.members.contains { !$0.rolledBack.isEmpty }
        f.rewound = job.rewind != nil
        f.merged = job.members.contains(where: \.merged)
        f.worktreeGone = job.worktree == nil ? job.hadWorktree : !sites(job).allSatisfy { FileManager.default.fileExists(atPath: $0.folder.path) }
        f.queuedAgain = job.taskPath != nil && jobs.contains { $0 !== job && $0.kind == .runTask && $0.isActive && $0.taskPath == job.taskPath && $0.forkOf == nil }
            && job.forkOf == nil
        return Handoff.refusal(f)
    }

    /// Why the profile can't go on with the job; nil = it can.
    func handoffRefusal(_ job: Job, to p: AgentProfile) -> String? {
        let container = job.executor == .docker || ContainerStore.shared.isContainer(job.runDir)
        let a = agents[p.agent].map { (title: $0.title, capabilities: $0.capabilities) }
        return Handoff.refusal(to: .init(p), agent: a, from: job.handoffSide,
                               at: .init(hasWorktree: job.worktree != nil, container: container, dockerReady: docker != nil,
                                         repos: !job.repos.isEmpty || !job.parts.isEmpty))
            ?? Self.executorRefusal(job, docker: docker != nil)
    }

    func handoffTitle(_ s: Handoff.Side) -> String {
        let name = agents[s.agent]?.title ?? s.agent.rawValue
        return s.model.isEmpty ? name : "\(name) (\(s.model))"
    }

    // MARK: Text

    /// Collects what would be sent. Nothing is sent or changed.
    func prepareHandoff(_ job: Job) async -> Result<HandoffDraft, HandoffError> {
        if let why = handoffBlocked(job) { return .failure(.init(message: why)) }
        let sites = sites(job), path = job.taskPath, summary = handoffSummary(job)
        let box = job.executor == .docker || ContainerStore.shared.isContainer(job.runDir)
        let prompt = job.planPhase == .approved ? ClaudePrompts.approved(job.prompt) : job.prompt
        let cwd = job.cwd.path, wt = job.worktree?.path.path
        let from = job.handoffSide, session = job.sessionID
        let made = await Task.detached(priority: .userInitiated) { () -> Result<HandoffDraft, HandoffError> in
            do {
                let state = try Self.handoffState(sites, path)
                let repos = try sites.map { try Self.handoffDiff($0, tree: state.trees[$0.folder.path] ?? "") }
                let text = Handoff.Draft(.init(instruction: prompt, task: state.task, summary: summary, repos: repos)) { s in
                    if box, let wt {
                        return s.replacingOccurrences(of: wt, with: ContainerSpec.workspace).replacingOccurrences(of: cwd, with: ContainerSpec.workspace)
                    }
                    guard wt != nil, let path, !s.contains(path) else { return s }
                    return s.replacingOccurrences(of: "tasks/" + (path as NSString).lastPathComponent, with: path)
                }
                var warnings: [String] = []
                if sites.contains(where: { $0.worktree == nil }) {
                    warnings.append("Задача идёт в основной папке: среди незакоммиченных правок могут быть чужие, а чекпоинт там не делается")
                }
                return .success(HandoffDraft(text: text, state: state, from: from, session: session, warnings: warnings))
            } catch {
                return .failure(.init(message: (error as? HandoffError)?.message ?? error.localizedDescription))
            }
        }.value
        if let why = handoffBlocked(job) { return .failure(.init(message: why)) }
        return made
    }

    nonisolated private static func handoffState(_ sites: [Site], _ taskPath: String?) throws -> HandoffState {
        var s = HandoffState()
        if let taskPath {
            guard let t = try? String(contentsOfFile: taskPath, encoding: .utf8) else { throw HandoffError(message: "Файл задачи не прочитан") }
            s.task = t
        }
        for site in sites {
            if let w = site.worktree {
                s.trees[site.folder.path] = try Checkpoints.currentTree(w.checkpointSite, git: DiffLoader.runEnv)
            } else if Git.isRepo(site.folder) {
                s.trees[site.folder.path] = try Checkpoints.folderTree(site.folder, git: DiffLoader.runEnv)
            }
        }
        return s
    }

    /// Everything since the branch began, also what isn't committed; tracker files aside. An error is never «no changes».
    nonisolated private static func handoffDiff(_ s: Site, tree: String) throws -> Handoff.Repo {
        guard !tree.isEmpty else { return Handoff.Repo(name: s.name, diff: "", files: "В проекте нет git: список изменений неизвестен.") }
        func git(_ args: [String], _ dir: URL) throws -> String {
            let r = DiffLoader.run(args, in: dir)
            guard r.ok else { throw HandoffError(message: "git: " + r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var base = s.base
        if let w = s.worktree {
            if base.isEmpty { base = try git(["merge-base", "HEAD", "refs/heads/\(w.branch)"], w.main) }
        } else {
            base = DiffLoader.run(["rev-parse", "--verify", "-q", "HEAD^{commit}"], in: s.folder).ok
                ? "HEAD" : try git(["hash-object", "-t", "tree", "/dev/null"], s.folder)
        }
        let args = ["-c", "core.quotePath=false"] + DiffCollector.diffArgs
        let paths = [base, tree] + WorktreeGit.stage(excluding: []).dropFirst(2)
        let d = DiffLoader.run(args + paths, in: s.folder, max: 2_000_000)
        guard d.ok else { throw HandoffError(message: "git diff: " + d.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let files = DiffLoader.run(args + ["--name-status"] + paths, in: s.folder, max: 1_000_000)
        guard files.ok else { throw HandoffError(message: "git diff: " + files.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return Handoff.Repo(name: s.name, diff: d.out, files: files.out, cut: d.cut)
    }

    /// No model is asked: what the queue knows itself.
    private func handoffSummary(_ job: Job) -> [(title: String, text: String)] {
        let said = job.log.filter { !$0.hasPrefix("⚙︎ ") }
        let answer = job.replies.last { !$0.answer.isEmpty }?.answer ?? said.last ?? ""
        return [
            ("Состояние", [job.lastLine, job.verifyNote].filter { !$0.isEmpty }.joined(separator: "\n")),
            ("Ревью", job.review),
            ("Последний ответ", answer),
            ("Конец журнала", job.log.suffix(40).joined(separator: "\n")),
        ]
    }

    // MARK: Handing over

    /// Sends exactly `draft.text.message(note:)` to the profile. Returns an error text; nil = the job is in the queue.
    func handOff(_ job: Job, _ draft: HandoffDraft, to profileID: String, note: String = "") async -> String? {
        if let why = handoffBlocked(job) { return why }
        guard let p = profiles().resolve(profileID) else { return "Профиль «\(profileID)» не найден" }
        if let why = handoffRefusal(job, to: p) { return why }
        let stale = "С тех пор файлы или задача изменились — обнови окно"
        guard job.handoffSide == draft.from, job.sessionID == draft.session else { return stale }
        let sites = sites(job), path = job.taskPath, session = job.sessionID
        let label = "Передача: \(handoffTitle(draft.from)) → \(handoffTitle(.init(p)))"
        let want = draft.state
        job.worktreeBusy = true
        let error = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                guard try Self.handoffState(sites, path) == want else { return stale }
                let trees = sites.compactMap(\.worktree)
                let meta = Checkpoints.Meta(kind: .turn, label: label, session: session, point: Self.point(session),
                                            turn: trees.count > 1 ? UUID().uuidString : nil)
                for w in trees { try Checkpoints.create(w.checkpointSite, meta, git: DiffLoader.runEnv) }
                return nil
            } catch {
                return "Не передано: " + ((error as? HandoffError)?.message ?? error.localizedDescription)
            }
        }.value
        job.worktreeBusy = false
        // No suspension from here on.
        if let why = error ?? handoffBlocked(job) ?? (job.handoffSide == draft.from && job.sessionID == draft.session ? nil : stale) {
            pump()
            return why
        }
        guard profiles().resolve(profileID) == p, handoffRefusal(job, to: p) == nil else {
            pump()
            return "Профиль «\(profileID)» с тех пор изменился"
        }
        guard begin(job, p, .init(text: draft.text.message(note: note), label: label)) else {
            pump()
            return "Не передано: очередь не записана на диск"
        }
        startHandedOff(job)
        return nil
    }

    private func startHandedOff(_ job: Job) {
        job.handoffSaved = true
        pump()
        // Waits for a slot: by then the files may be different.
        job.handoffSaved = false
    }

    /// Everything on disk before anything starts; false = nothing has changed.
    private func begin(_ job: Job, _ p: AgentProfile, _ pending: Handoff.Pending) -> Bool {
        let old = job.record, oldChecks = job.parts.map(\.mergeCheck), taskRefusal = job.taskCheckRefusal
        // The last one never got its text.
        if job.pendingHandoff != nil { giveBack(job) }
        var r = Handoff.Record(date: now(), from: job.handoffSide, to: .init(p), session: job.sessionID, resume: job.resumeSession, fork: job.forkSession,
                               picked: job.model?.rawValue, rollbackNotice: job.rollbackNotice, remote: job.remote,
                               limitWait: job.limitWait, limitRetried: job.limitRetried,
                               state: JobFacts.State(rawValue: job.state.rawValue) ?? .failed, interrupted: job.interrupted, mustUseMain: job.mustUseMain, acpFeatures: job.acpFeatures)
        if r.state == .running { r.state = .failed }
        job.handoffs.append(r)
        job.pendingHandoff = pending
        job.profile = p.id
        job.agent = p.agent
        job.profileModel = p.model
        job.server = p.server
        job.acp = p.acp
        job.acpFeatures = nil
        job.model = nil
        job.modelReason = ""
        job.sessionID = nil
        job.resumeSession = nil
        job.forkSession = nil
        job.remote = nil
        job.limitWait = nil
        job.limitRetried = nil
        job.rollbackNotice = ""
        job.interrupted = false
        // Work of the main folder stays there.
        if job.worktree == nil { job.mustUseMain = true }
        job.review = ""
        job.verdict = nil
        job.reviewFixed = false
        job.verifyAttempts = 0
        job.verifyNote = ""
        job.verifyFailed = false
        for m in job.members { m.mergeCheck = nil }
        job.state = .pending
        job.finishedAt = nil
        job.lastLine = pending.label
        guard saveNow() else {
            let was = Job(old)
            job.handoffs = was.handoffs
            job.pendingHandoff = was.pendingHandoff
            job.profile = old.profile ?? ""
            job.agent = old.agent
            job.profileModel = old.profileModel ?? ""
            job.server = old.server
            job.acp = old.acp
            job.acpFeatures = old.acpFeatures
            job.model = was.model
            job.modelReason = old.modelReason
            job.sessionID = old.sessionID
            job.resumeSession = old.resumeSession
            job.forkSession = old.forkSession
            job.remote = old.remote
            job.limitWait = old.limitWait?.value
            job.limitRetried = old.limitRetried
            job.rollbackNotice = old.rollbackNotice ?? ""
            job.interrupted = old.interrupted
            job.mustUseMain = old.mustUseMain
            job.review = old.review
            job.verdict = old.verdict
            job.reviewFixed = old.reviewFixed
            job.verifyAttempts = old.verifyAttempts
            job.verifyNote = old.verifyNote
            job.verifyFailed = old.verifyFailed
            job.taskCheckRefusal = taskRefusal
            job.mergeCheck = old.mergeCheck
            for (m, c) in zip(job.parts, oldChecks) { m.mergeCheck = c }
            job.state = old.state
            job.finishedAt = old.finishedAt
            job.lastLine = old.lastLine
            return false
        }
        job.log.append("⚙︎ " + pending.label.replacingOccurrences(of: "Передача:", with: "Передано:")
            + (r.session.map { " · прежняя сессия \($0.prefix(8))… сохранена" } ?? ""))
        return true
    }

    /// The new agent's first turn: the shown text, a session of its own.
    func startHandoff(_ job: Job, _ h: Handoff.Pending) {
        guard FileManager.default.fileExists(atPath: job.runDir.path) else { return failStart(job, "Папка задачи удалена: \(job.runDir.path)") }
        let model: ClaudeModel
        if !job.profileModel.isEmpty || !capabilities(job).contains(.autoModel) { model = .auto }
        else if !Self.autoModel { model = .current }
        else {
            // No other model is asked.
            let t = job.taskPath.flatMap { Codec.task(at: URL(fileURLWithPath: $0)) }
            switch ModelPick.heuristic(title: t?.title ?? job.title, body: t?.body ?? "", size: t?.size ?? "") {
            case .opus(let why): model = .opus; job.modelReason = why
            case .sonnet(let why): model = .sonnet; job.modelReason = why
            case .ask: model = .sonnet
            }
        }
        launch(job, model: model, prompt: h.text, turn: h.label, checkpoint: !job.handoffSaved)
    }

    /// The new agent has the text: it isn't needed any more.
    func handoffAccepted(_ job: Job) {
        guard job.pendingHandoff != nil else { return }
        job.pendingHandoff = nil
        if let i = job.handoffs.indices.last { job.handoffs[i].status = .accepted }
        saveNow()
    }

    /// The new agent never began: the job is the previous one's again, as it was. false = not being handed over.
    func handoffNotStarted(_ job: Job, _ why: String) -> Bool {
        guard job.pendingHandoff != nil, let r = job.handoffs.last else { return false }
        giveBack(job)
        job.proc = nil
        job.permissions = []
        job.cancelRequested = false
        job.state = switch r.state {
        case .done: .done
        case .cancelled: .cancelled
        case .pending where r.limitWait != nil: .pending
        default: .failed
        }
        job.limitWait = job.state == .pending ? r.limitWait : nil
        job.interrupted = job.state == .failed || r.interrupted
        job.finishedAt = job.state == .pending ? nil : Date()
        job.lastLine = "Не передано: \(why)"
        job.log.append("⚙︎ \(job.lastLine). Задача осталась у прежнего агента (\(handoffTitle(r.from)))")
        onFinished?(job)
        saveNow()
        pump()
        return true
    }

    /// Puts the previous agent and its session back; the entry stays as a failed one.
    private func giveBack(_ job: Job) {
        guard job.pendingHandoff != nil, let i = job.handoffs.indices.last else { return }
        let r = job.handoffs[i]
        job.handoffs[i].status = .failed
        job.pendingHandoff = nil
        job.profile = r.from.profile
        job.agent = r.from.agent
        job.profileModel = r.from.model
        job.server = r.from.server
        job.acp = r.from.acp
        job.acpFeatures = r.acpFeatures
        job.model = r.picked.flatMap(ClaudeModel.init(rawValue:))
        job.modelReason = ""
        job.sessionID = r.session
        job.resumeSession = r.resume
        job.forkSession = r.fork
        job.remote = r.remote
        job.rollbackNotice = r.rollbackNotice
        job.limitRetried = r.limitRetried
        job.mustUseMain = r.mustUseMain
    }

    /// «↻»: the new job goes on with the same agent, branch and history.
    func keepHandoffs(_ old: Job, _ j: Job) {
        j.handoffs = old.handoffs
        j.pendingHandoff = old.remoteUnclaimed ? nil : old.pendingHandoff
        j.forkSession = nil
        guard j.worktree != nil else { return }
        // What the branch already had.
        j.hadWorktree = true
        j.committed = old.committed
        j.merged = old.merged
        j.mergeArtifacts = old.mergeArtifacts
        j.pullRequest = old.pullRequest
        j.rolledBack = old.rolledBack
    }
}
