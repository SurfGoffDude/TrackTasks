import Foundation
import TrackTasksCore

@Observable @MainActor
final class Job: Identifiable {
    enum Kind: String, Codable { case runTask, updateAbout, quickAdd, review, fix, reply }
    /// Code jobs edit project code; light jobs only read or touch tasks/ and about.md.
    enum Lane { case code, light }
    enum State: String, Codable { case pending, running, done, failed, cancelled }
    enum Verdict: String, Codable { case ok, issues }
    /// «Согласование плана до кода». nil = the task runs without a plan.
    /// planning: read-only run that writes «## План»; awaiting: plan written, waits for the user (pending, no slot);
    /// approved: the code run itself (same session when it can be resumed).
    typealias PlanPhase = PlanFlow.Phase

    let id: UUID
    let kind: Kind
    let title: String
    let projectID: String?
    let projectName: String
    let cwd: URL
    let prompt: String
    let systemPrompt: String
    let taskPath: String?
    let created: Date

    var state: State = .pending
    var lastLine = ""
    var log: [String] = []
    var diffStat = ""
    var finishedAt: Date?
    @ObservationIgnored var proc: (any AgentRun)?

    // Run results (kept across restarts).
    var sessionID: String?
    var summary = ""
    var cost = AgentCost()
    var interrupted = false
    /// Continue this claude session instead of starting fresh (retry after restart).
    var resumeSession: String?

    /// Set when the job runs in its own git worktree (project was busy with another code job).
    var worktree: Worktrees.Info? {
        didSet { if worktree != nil { hadWorktree = true } }
    }
    /// The job got a worktree at some point; stays after the worktree is removed.
    var hadWorktree = false
    var baseCommit = ""
    var worktreeNote = ""
    /// Something is being done with a branch of the task. One for all its repositories.
    var worktreeBusy: Bool {
        get { owner?.ownBusy ?? ownBusy }
        set { if let owner { owner.ownBusy = newValue } else { ownBusy = newValue } }
    }
    private var ownBusy = false
    /// `repos:` of the task: what was asked for.
    var repos: [String] = []
    /// Their folders, as resolved when the job was queued or loaded; or why they can't be used.
    @ObservationIgnored var repoFolders: [URL] = []
    @ObservationIgnored var repoProblem = ""
    /// Work in those repositories (see `JobRepos.swift`).
    var parts: [Job] = []
    @ObservationIgnored weak var owner: Job?
    /// Fix of a merge: main folder of the repository it is about, nil = the project's own.
    var targetRepo: String?
    /// A settle that waits until another repository of the task is free.
    @ObservationIgnored var settleLater = false
    /// `cwd` as the disk names it.
    @ObservationIgnored private(set) lazy var realCwd = TaskRepos.canonical(cwd)
    var merged = false
    var worktreeUnavailable = false
    /// `setup:` of about.md ran in this worktree. Not repeated when the job continues.
    var setupDone = false
    /// `setup:` is running now (not persisted): the job holds its slot, cancel stops waiting for it.
    var settingUp = false
    /// Identifies the running setup: a result of an older run (after cancel + retry) is ignored.
    @ObservationIgnored var setupRun: UUID?
    @ObservationIgnored var setupProcess: RunningCommand?
    /// The worktree commands waiting for a person to approve them (not persisted).
    var scriptApproval: WorktreeScripts?
    var committed = false
    /// Fix jobs for a main-folder task must run in the main folder (the changes are there, uncommitted).
    var mustUseMain = false
    /// `worktree: always` of the project (kept so that a restart decides the same before projects are scanned).
    var alwaysWorktree = false
    /// User chose «Запустить всё равно»: start in a worktree even with uncommitted code in the main folder.
    var allowDirtyMain = false
    /// `files:` of the task (follows the task file).
    var files: [String] = []
    /// Priority of the task when it was queued: the queue puts jobs that unblock more first among equal ones.
    var taskPriority: Priority?
    /// User chose «Запустить всё равно»: don't wait for jobs that change the same files.
    var allowSameFiles = false
    /// Uncommitted code files in the main folder that hold this job back (not persisted, re-checked by pump).
    var dirtyMain: [String] = []
    /// Set by merge() when the branch touches files with uncommitted main-folder changes: UI asks to confirm.
    var mergeOverlap: [String] = []
    /// Set by merge() when the branch's CI is red: UI asks to confirm (not persisted).
    var mergeRedCI = false
    /// Last merge stopped on a conflict between the branch and main — Claude can resolve it in the worktree.
    var mergeFailed = false
    /// Last merge was blocked by unresolved conflicts already sitting in the main folder.
    var mainConflict = false
    /// Files of the last `mergeOverlap` question: what «Слить всё равно» confirms.
    @ObservationIgnored var mergeOverlapAsked: [String] = []
    /// Last check of the branch together with main.
    var mergeCheck: SafeMerge.Check?
    /// Untracked files left in the worktree by checks of the merge: they don't block it.
    @ObservationIgnored var mergeArtifacts: [String] = []
    /// A merge is going (not persisted: git refs tell about an interrupted one).
    var mergePhase: SafeMerge.Phase?
    @ObservationIgnored var mergeToken: MergeToken?
    /// The last merge was stopped by the user: the other repositories of the task wait too.
    @ObservationIgnored var mergeStopped = false
    /// This fix job repairs the check that failed with main merged in (not a review fix).
    var fixesMergeCheck = false
    /// This fix job merges main into the task branch and resolves conflicts (not a review fix).
    var resolvesMerge = false
    /// Pull request created from this job's branch.
    var pullRequest: PullRequestLink?

    /// Tool uses waiting for approval.
    var permissions: [PermissionRequest] = []

    /// Model the job ran with (auto-picked by Haiku or from Settings).
    var model: ClaudeModel?
    var modelReason = ""
    /// Model name from queue.json this version doesn't know; kept as it was.
    @ObservationIgnored var unknownModel: String?
    /// `agent:` of the task — profile name; empty = the default profile.
    var profile = ""
    /// Agent and model of that profile, fixed when the job first starts.
    var agent: AgentID?
    var profileModel = ""
    /// Server of the profile, fixed with the agent.
    var server: RemoteServer?
    /// Command of the profile's ACP agent, fixed with the agent, and what that agent announced (nil = not known yet).
    var acp: ACPCommand?
    var acpFeatures: ACPFeatures?
    /// The last run on the server.
    var remote: RemoteRun?
    /// The result of that run is still on the server: the next start continues watching it.
    var remoteUnclaimed: Bool { remote?.returned == false }
    /// `executor:` of the project and the task, when docker is available; never goes back to local in the same worktree.
    var executor: Executor?
    /// Fix job started with `--resume` of its task's session (not persisted): on a failed resume, retry fresh once.
    @ObservationIgnored var resumedParent = false

    /// Build/test command from about.md `verify:`; run after Claude, failures go back to Claude.
    var verifyCommand: String?
    /// `verify:` of the task when it was queued (`TaskVerify.text`), nil = not known. Never an approval.
    var taskVerify: String?
    /// Why the task's own check can't be run now (not persisted).
    var taskCheckRefusal: TaskVerify.Refusal?
    var verifyAttempts = 0
    var verifyNote = ""
    var verifyFailed = false

    /// Chains and `depends:`: start only after all these jobs are done (and merged, if they ran in a worktree).
    var dependsOn: [UUID] = []
    /// «Волнами по приоритету»: 1-based wave number, total waves, and the wave's priority.
    var wave: Int?
    var waveCount: Int?
    var wavePriority: Priority?
    /// Review/fix jobs point at the task job they belong to.
    var parentID: UUID?
    /// On task jobs: the review text and verdict.
    var review = ""
    var verdict: Verdict?
    var reviewFixed = false

    /// Messages sent to this job's session from its card, and the unsent text of the next one.
    var replies: [AgentReply] = []
    var replyDraft = ""
    /// A terminal was opened in its folder: the worktree may hold edits made by hand.
    var terminalUsed = false
    /// Reply to a light job: same limited tools, no verify.
    var lightReply = false

    /// Agents that had this job before, oldest first. Non-empty: the worktree holds somebody's work and is never dropped by itself.
    var handoffs: [Handoff.Record] = []
    /// Text for the new agent until it has begun its turn.
    var pendingHandoff: Handoff.Pending?
    /// The folder was saved just now (not persisted): no second checkpoint of the same state.
    @ObservationIgnored var handoffSaved = false

    /// Fork: this job continues a copy of the source job's session (`--resume --fork-session`) on its own branch.
    var forkOf: UUID?
    var forkSession: String?
    var forkTitle = ""

    /// Rollback to a checkpoint that is not committed to the branch yet (checkpoint name); empty = none.
    var rolledBack = ""
    /// The agent's conversation still knows the code before the rollback: tell it with the next message.
    var rollbackNotice = ""
    /// Conversation rolled back: the next turn continues from here in a new session.
    var rewind: SessionRewind?
    /// The worktree is being saved before a turn (not persisted); cancel waits for it.
    var checkpointing = false
    @ObservationIgnored var cancelRequested = false

    /// The check is running (not persisted); cancel kills it.
    var verifying = false
    @ObservationIgnored var verifyProcess: RunningCommand?

    /// Text from outside (`source:`): no full access. Kept even if the line is later removed from the file.
    var foreignSource = false
    /// A log of CI was sent to this task's session: the same limits, whoever sent it.
    var foreignLog = false
    /// Automatic «Исправить CI» of all repositories of the task.
    var ciFixTries = CIFix.Tries()
    /// The task was created by a schedule: no automatic merge. Kept even if the line is later removed from the file.
    var scheduled = false
    /// The one automatic fix of «Опасный режим» was used.
    var autoFixUsed = false
    /// Automatic steps of «Автопилот» and why it gave up (nil = goes on).
    var auto = AutoSteps()
    /// Not before: uncommitted files in main are in the way.
    @ObservationIgnored var autoHold: Date?
    /// The last merge stopped on something that passes by itself (uncommitted files in main, cancelled).
    @ObservationIgnored var mergeWaits = false
    /// The last run had full access.
    var fullAccess = false
    /// The person was told that this run outlived the mode.
    @ObservationIgnored var outlivedNoted = false

    /// The task goes through a pipeline (`workflow:`): its own copy of the steps and how far it has got.
    var pipeline: PipelineState?
    /// Set on follow-ups that carry out a step: its title.
    var pipelineStep = ""
    /// The task (or the one it was forked from) was queued with a pipeline: never merged by the autopilot.
    var fromPipeline = false
    /// The agent was told to give evidence for every ticked criterion.
    var evidenceAsked = false
    /// The review changed code (not persisted).
    @ObservationIgnored var reviewTampered = false

    /// Stopped by the limit: pending until the reset, then goes on in the same session.
    var limitWait: LimitWait?
    /// Reset time of the window whose one automatic retry has begun.
    var limitRetried: Date?
    /// The user asked to stop the running agent (not persisted): nothing is repeated by itself.
    @ObservationIgnored var stopAsked = false

    /// What the agent asked; on the task's own job.
    var questions: JobQuestions?
    /// Answers are being written (not persisted): no second submit, approval or reply meanwhile.
    var answering = false

    var planPhase: PlanPhase?
    /// User's comment for «Доработать»; goes to the agent with the next planning run.
    var planFeedback = ""
    /// Code fingerprint taken when planning started: the plan must not change code (not persisted).
    @ObservationIgnored var planBaseline: String?
    /// Another code job worked in this folder during planning: the fingerprint comparison means nothing.
    @ObservationIgnored var planFolderShared = false

    /// The agent that has (or had) this job's session.
    var agentID: AgentID { agent ?? .claude }
    /// Shown in the queue.
    var modelTitle: String? { profileModel.isEmpty ? model?.title : profileModel }

    /// Follow-ups (review, fix, reply, fork) run with the agent of their task.
    func useAgent(of task: Job) {
        profile = task.profile
        agent = task.agentID
        profileModel = task.profileModel
        server = task.server
        acp = task.acp
        acpFeatures = task.acpFeatures
        executor = task.executor
    }

    /// Where the agent actually runs.
    var runDir: URL { worktree?.path ?? cwd }

    var lane: Lane {
        switch kind {
        case .runTask: planPhase == .planning ? .light : .code
        case .fix: .code
        case .reply: lightReply ? .light : .code
        case .updateAbout, .quickAdd, .review: .light
        }
    }
    var isActive: Bool { state == .pending || state == .running }
    var isCodeTask: Bool { lane == .code }
    /// Code job that finished in the main folder: its changes may be uncommitted there.
    var finishedInMain: Bool { state == .done && isCodeTask && !hadWorktree }
    var awaitingPlan: Bool { planPhase == .awaiting }
    /// Edits its parent's folder; results belong to the parent.
    var isFollowUp: Bool { kind == .fix || kind == .reply }

    init(id: UUID = UUID(), kind: Kind, title: String, projectID: String?, projectName: String, cwd: URL,
         prompt: String, systemPrompt: String, taskPath: String? = nil, created: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.projectID = projectID
        self.projectName = projectName
        self.cwd = cwd
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.taskPath = taskPath
        self.created = created
    }
}

// MARK: - Persistence

/// Codable snapshot of a Job — the queue survives app restarts.
struct JobRecord: Codable {
    var id: UUID
    var kind: Job.Kind
    var title: String
    var projectID: String?
    var projectName: String
    var cwd: URL
    var prompt: String
    var systemPrompt: String
    var taskPath: String?
    var created: Date
    var state: Job.State
    var lastLine: String
    var log: [String]
    var diffStat: String
    var finishedAt: Date?
    var sessionID: String?
    var summary: String
    var cost: Double
    var interrupted: Bool
    var resumeSession: String?
    var worktree: Worktrees.Info?
    var baseCommit: String
    var worktreeNote: String
    var merged: Bool
    var committed: Bool
    var mustUseMain: Bool
    var allowDirtyMain: Bool?
    var model: String?
    var modelReason: String
    var verifyCommand: String?
    var taskVerify: String?
    var verifyAttempts: Int
    var verifyNote: String
    var verifyFailed: Bool
    /// Legacy single dependency (old queue.json); read only, merged into `depends`.
    var dependsOn: UUID?
    var depends: [UUID]?
    var wave: Int?
    var waveCount: Int?
    var wavePriority: String?
    var parentID: UUID?
    var review: String
    var verdict: Job.Verdict?
    var reviewFixed: Bool
    var replies: [AgentReply]?
    var replyDraft: String?
    var lightReply: Bool?
    var pullRequest: PullRequestLink?
    var planPhase: Job.PlanPhase?
    var planFeedback: String?
    var forkOf: UUID?
    var forkSession: String?
    var forkTitle: String?
    var rolledBack: String?
    var rollbackNotice: String?
    var rewind: SessionRewind?
    var terminalUsed: Bool?
    var setupDone: Bool?
    var foreignSource: Bool?
    var foreignLog: Bool?
    var ciFixTries: CIFix.Tries?
    var scheduled: Bool?
    var autoFixUsed: Bool?
    var auto: AutoSteps?
    var fullAccess: Bool?
    var profile: String?
    var agent: AgentID?
    var profileModel: String?
    /// `cost` stays a number: older versions of the app require it.
    var costUnknown: Bool?
    var mergeCheck: SafeMerge.Check?
    /// nil in records of older versions: the list was only in `mergeCheck`.
    var mergeArtifacts: [String]?
    var mergeFailed: Bool?
    var resolvesMerge: Bool?
    var fixesMergeCheck: Bool?
    var alwaysWorktree: Bool?
    var files: [String]?
    var taskPriority: String?
    var allowSameFiles: Bool?
    var hadWorktree: Bool?
    var repos: [String]?
    var extraRepos: LenientRepoWorks?
    var targetRepo: String?
    var pipeline: PipelineState?
    var pipelineStep: String?
    var fromPipeline: Bool?
    var evidenceAsked: Bool?
    var server: RemoteServer?
    var acp: ACPCommand?
    var acpFeatures: ACPFeatures?
    var remote: RemoteRun?
    var executor: Executor?
    var limitWait: LenientLimitWait?
    var limitRetried: Date?
    var questions: LenientJobQuestions?
    var handoffs: Handoff.Records?
    var pendingHandoff: Handoff.Pending?
}

extension Job {
    var record: JobRecord {
        JobRecord(id: id, kind: kind, title: title, projectID: projectID, projectName: projectName, cwd: cwd,
                  prompt: prompt, systemPrompt: systemPrompt, taskPath: taskPath, created: created,
                  state: state, lastLine: lastLine, log: Array(log.suffix(200)), diffStat: diffStat,
                  finishedAt: finishedAt, sessionID: sessionID, summary: summary, cost: cost.usd,
                  interrupted: interrupted, resumeSession: resumeSession, worktree: worktree,
                  baseCommit: baseCommit, worktreeNote: worktreeNote, merged: merged, committed: committed,
                  mustUseMain: mustUseMain, allowDirtyMain: allowDirtyMain ? true : nil, model: model?.rawValue ?? unknownModel, modelReason: modelReason,
                  verifyCommand: verifyCommand, taskVerify: taskVerify, verifyAttempts: verifyAttempts, verifyNote: verifyNote,
                  verifyFailed: verifyFailed, dependsOn: nil, depends: dependsOn,
                  wave: wave, waveCount: waveCount, wavePriority: wavePriority?.rawValue, parentID: parentID, review: review,
                  verdict: verdict, reviewFixed: reviewFixed, replies: replies.isEmpty ? nil : replies,
                  replyDraft: replyDraft.isEmpty ? nil : replyDraft, lightReply: lightReply ? true : nil,
                  pullRequest: pullRequest, planPhase: planPhase, planFeedback: planFeedback.isEmpty ? nil : planFeedback,
                  forkOf: forkOf, forkSession: forkSession, forkTitle: forkTitle.isEmpty ? nil : forkTitle,
                  rolledBack: rolledBack.isEmpty ? nil : rolledBack,
                  rollbackNotice: rollbackNotice.isEmpty ? nil : rollbackNotice, rewind: rewind,
                  terminalUsed: terminalUsed ? true : nil, setupDone: setupDone ? true : nil,
                  foreignSource: foreignSource ? true : nil, foreignLog: foreignLog ? true : nil,
                  ciFixTries: ciFixTries == CIFix.Tries() ? nil : ciFixTries, scheduled: scheduled ? true : nil, autoFixUsed: autoFixUsed ? true : nil,
                  auto: auto == AutoSteps() ? nil : auto,
                  fullAccess: fullAccess ? true : nil,
                  profile: profile.isEmpty ? nil : profile, agent: agent, profileModel: profileModel.isEmpty ? nil : profileModel,
                  costUnknown: cost.unknown ? true : nil, mergeCheck: mergeCheck,
                  mergeArtifacts: mergeArtifacts.isEmpty && mergeCheck == nil ? nil : mergeArtifacts, mergeFailed: mergeFailed ? true : nil,
                  resolvesMerge: resolvesMerge ? true : nil, fixesMergeCheck: fixesMergeCheck ? true : nil,
                  alwaysWorktree: alwaysWorktree ? true : nil,
                  files: files.isEmpty ? nil : files, taskPriority: taskPriority?.rawValue, allowSameFiles: allowSameFiles ? true : nil,
                  hadWorktree: hadWorktree, repos: repos.isEmpty ? nil : repos,
                  extraRepos: parts.isEmpty ? nil : LenientRepoWorks(parts.map { RepoWork($0) }), targetRepo: targetRepo,
                  pipeline: pipeline, pipelineStep: pipelineStep.isEmpty ? nil : pipelineStep,
                  fromPipeline: fromPipeline ? true : nil, evidenceAsked: evidenceAsked ? true : nil, server: server, acp: acp, acpFeatures: acpFeatures, remote: remote, executor: executor,
                  limitWait: limitWait.map(LenientLimitWait.init), limitRetried: limitRetried,
                  questions: questions.map(LenientJobQuestions.init),
                  handoffs: handoffs.isEmpty ? nil : Handoff.Records(handoffs), pendingHandoff: pendingHandoff)
    }

    convenience init(_ r: JobRecord) {
        self.init(id: r.id, kind: r.kind, title: r.title, projectID: r.projectID, projectName: r.projectName,
                  cwd: r.cwd, prompt: r.prompt, systemPrompt: r.systemPrompt, taskPath: r.taskPath, created: r.created)
        state = r.state
        lastLine = r.lastLine
        log = r.log
        diffStat = r.diffStat
        finishedAt = r.finishedAt
        sessionID = r.sessionID
        summary = r.summary
        cost = AgentCost(usd: r.cost, unknown: r.costUnknown ?? false)
        interrupted = r.interrupted
        resumeSession = r.resumeSession
        worktree = r.worktree
        baseCommit = r.baseCommit
        // Records saved before the flag existed: a base commit was set only together with a worktree.
        hadWorktree = r.hadWorktree ?? (r.worktree != nil || !r.baseCommit.isEmpty)
        worktreeNote = r.worktreeNote
        merged = r.merged
        committed = r.committed
        mustUseMain = r.mustUseMain
        allowDirtyMain = r.allowDirtyMain ?? false
        model = r.model.flatMap(ClaudeModel.init(rawValue:))
        if model == nil { unknownModel = r.model }
        modelReason = r.modelReason
        profile = r.profile ?? ""
        // Saved before agents existed and already run: that was Claude.
        agent = r.agent ?? (r.sessionID != nil || r.resumeSession != nil || r.forkSession != nil || r.parentID != nil ? .claude : nil)
        // A step whose profile wasn't found must not become Claude's.
        if r.pipelineStep != nil || (r.pipeline != nil && r.sessionID == nil && r.resumeSession == nil) { agent = r.agent }
        profileModel = r.profileModel ?? ""
        server = r.server
        acp = r.acp
        acpFeatures = r.acpFeatures
        remote = r.remote
        executor = r.executor
        verifyCommand = r.verifyCommand
        taskVerify = r.taskVerify
        verifyAttempts = r.verifyAttempts
        verifyNote = r.verifyNote
        verifyFailed = r.verifyFailed
        dependsOn = r.depends ?? r.dependsOn.map { [$0] } ?? []
        wave = r.wave
        waveCount = r.waveCount
        wavePriority = r.wavePriority.flatMap(Priority.init(rawValue:))
        parentID = r.parentID
        review = r.review
        verdict = r.verdict
        reviewFixed = r.reviewFixed
        replies = r.replies ?? []
        replyDraft = r.replyDraft ?? ""
        lightReply = r.lightReply ?? false
        pullRequest = r.pullRequest
        planPhase = r.planPhase
        planFeedback = r.planFeedback ?? ""
        forkOf = r.forkOf
        forkSession = r.forkSession
        forkTitle = r.forkTitle ?? ""
        rolledBack = r.rolledBack ?? ""
        rollbackNotice = r.rollbackNotice ?? ""
        rewind = r.rewind
        terminalUsed = r.terminalUsed ?? false
        setupDone = r.setupDone ?? false
        foreignSource = r.foreignSource ?? false
        foreignLog = r.foreignLog ?? false
        ciFixTries = r.ciFixTries ?? CIFix.Tries()
        scheduled = r.scheduled ?? false
        autoFixUsed = r.autoFixUsed ?? false
        auto = r.auto ?? AutoSteps()
        fullAccess = r.fullAccess ?? false
        mergeCheck = r.mergeCheck
        mergeArtifacts = r.mergeArtifacts ?? r.mergeCheck?.artifacts ?? []
        mergeFailed = r.mergeFailed ?? false
        resolvesMerge = r.resolvesMerge ?? false
        fixesMergeCheck = r.fixesMergeCheck ?? false
        alwaysWorktree = r.alwaysWorktree ?? false
        files = r.files ?? []
        taskPriority = r.taskPriority.flatMap(Priority.init(rawValue:))
        pipeline = r.pipeline
        pipelineStep = r.pipelineStep ?? ""
        fromPipeline = r.fromPipeline ?? false
        evidenceAsked = r.evidenceAsked ?? false
        allowSameFiles = r.allowSameFiles ?? false
        repos = r.repos ?? []
        for w in r.extraRepos?.list ?? [] { addPart(w) }
        targetRepo = r.targetRepo
        limitWait = r.limitWait?.value
        limitRetried = r.limitRetried
        questions = r.questions?.value
        handoffs = r.handoffs?.list ?? []
        pendingHandoff = r.pendingHandoff
        if let p = pendingHandoff, p.text.isEmpty {
            pendingHandoff = nil
            if state == .pending {
                state = .failed
                interrupted = true
                finishedAt = Date()
                lastLine = "Передача не прочитана из очереди, агенту ничего не отправлено. Нажми «Продолжить» или передай снова."
            }
        }
        planBaseline = limitWait?.planBaseline
        planFolderShared = limitWait?.planShared ?? false
        // The wait can't be read, or the retry had begun: it isn't known how far it got, so no second one.
        if state == .pending, let w = r.limitWait, w.value.map({ LimitWait.sameWindow(r.limitRetried, $0.resetsAt) }) ?? true {
            state = .failed
            interrupted = true
            finishedAt = Date()
            lastLine = "Прервано при продолжении после лимита. Нажми «Продолжить»."
        }
        if state != .pending { limitWait = nil }
        // A run can't survive a restart: mark it so the user can retry or continue it.
        if state == .running {
            state = .failed
            interrupted = true
            finishedAt = Date()
            lastLine = remoteUnclaimed ? "Приложение было закрыто, запуск на сервере не прерывался. «Продолжить» подключится к нему."
                : "Прервано: приложение было закрыто. Нажми «Продолжить»."
        }
    }
}
