import Foundation
import TrackTasksCore

/// What a card can do now and what it says about it. The card draws exactly these offers,
/// so the status text (`JobGuide`) can't promise a button that isn't there.
extension JobQueue {
    func guide(_ job: Job) -> JobGuide { JobGuide.of(facts(job)) }

    /// `brief`: for lists and counters — no planner run, no buttons.
    func facts(_ job: Job, brief: Bool = false) -> JobFacts {
        var f = JobFacts()
        f.state = JobFacts.State(rawValue: job.state.rawValue) ?? .failed
        f.isTask = job.kind == .runTask
        f.isChild = job.parentID != nil
        f.interrupted = job.interrupted
        let children = jobs.filter { $0.parentID == job.id && $0.isActive }
        f.permissions = job.permissions.count + children.reduce(0) { $0 + $1.permissions.count }
        f.questions = questionStatus(job)
        f.plan = job.planPhase
        f.gate = job.pipeline?.gate?.reason
        f.pipelineOpen = job.pipelineOpen
        f.merging = job.members.lazy.compactMap(\.mergePhase).first?.title
        f.child = children.first.map { kindTitle($0.kind) }
        f.branchBusy = job.worktreeBusy
        f.setup = job.scriptApproval != nil
        f.remoteUnclaimed = job.remoteUnclaimed
        f.isGroup = job.isGroup
        f.awaitsMerge = job.awaitsMerge
        f.merged = job.fullyMerged
        let live = job.members.filter { !$0.merged }
        f.mainConflict = live.contains { $0.mainConflict && $0.worktree != nil }
        f.conflict = live.contains { $0.mergeFailed && $0.worktree != nil }
        f.mergeRed = live.contains { $0.mergeCheck?.state == .red && $0.worktree != nil }
        f.rolledBack = live.contains { !$0.rolledBack.isEmpty && $0.committed }
        // A newer check together with main says more than the branch alone.
        // «Not run yet» isn't red, though the flag is set to hold what depends on the check.
        let notRun = job.verifyNote.hasPrefix(Self.taskCheckRefused)
        f.verifyFailed = job.verifyFailed && job.mergeCheck?.state != .passed && !notRun && job.verifyNote != Self.taskCheckApproved
        f.taskCheck = job.taskCheckRefusal?.why
        f.taskCheckToRun = notRun && job.taskCheckRefusal == nil && !job.hadWorktree
        f.remarks = job.verdict == .issues && !job.reviewFixed
        let waiting = live.filter(\.ownAwaitsMerge)
        if !waiting.isEmpty, waiting.allSatisfy(\.hasLivePR) {
            f.prMerged = waiting.contains { $0.pullRequest?.pr.state == .merged }
            f.prOpen = !f.prMerged
        }
        f.parked = job.auto.parked
        f.autopilot = job.awaitsMerge && job.auto.parked == nil && onAutopilot(job)
        guard !brief else { return f }
        f.lastLine = job.lastLine
        f.offers = offers(job)
        f.waitReason = waitReason(job)
        if job.isGroup, !job.isActive { f.repoActions = Set(job.members.flatMap { branchOffers($0).keys }) }
        return f
    }

    /// The branch is occupied: why.
    private func busy(_ job: Job) -> String? {
        if job.worktreeBusy { return "с веткой сейчас что-то делают" }
        return childBusy(job)
    }

    private func childBusy(_ job: Job) -> String? {
        guard hasActiveChild(job) else { return nil }
        return Terminals.shared.claudeRunning(job.home) ? "в терминале карточки открыт Claude" : "идёт ответ, ревью или исправление"
    }

    private var waitsForPipeline: String { "сначала пайплайн должен завершиться" }

    /// Nothing from its folder runs on the host.
    private func inContainer(_ job: Job) -> Bool { job.executor == .docker || ContainerStore.shared.isContainer(job.runDir) }

    func offers(_ job: Job) -> [JobAction: JobOffer] {
        var o: [JobAction: JobOffer] = [:]
        let child = childBusy(job), embedded = Terminals.embedded
        if job.isActive { o[.stop] = JobOffer(job.state == .running ? "Остановить" : "Убрать из очереди", icon: "stop.fill", help: "Отменить задачу") }
        if job.state == .pending {
            if lacksRequiredWorktree(job) {
                o[.runInMain] = JobOffer("Запустить в основной папке", icon: "folder", help: "Запустить в основной папке, когда она свободна")
            } else if waitsForFiles(job) {
                o[.startDespiteFiles] = JobOffer("Запустить всё равно", icon: "play", help: "Не ждать задачи с теми же файлами — при слиянии возможен конфликт")
            } else if !job.dirtyMain.isEmpty && !job.allowDirtyMain {
                o[.startDespiteDirty] = JobOffer("Запустить всё равно", icon: "play", help: "Стартовать в worktree от последнего коммита — незакоммиченных правок там не будет")
                if !requiresWorktree(job), job.repos.isEmpty {
                    o[.runInMain] = JobOffer("Запустить в основной папке", icon: "folder", help: "Дождаться, когда основная папка освободится, и запустить там (с незакоммиченными правками)")
                }
            }
        }
        if job.state == .failed, job.scriptApproval != nil {
            o[.approveScripts] = JobOffer("Подтвердить команды…", icon: "checkmark.shield", help: "Команды setup/teardown из about.md запускаются только после подтверждения")
        }
        if let r = job.taskCheckRefusal, r.ask != nil {
            o[.approveTaskCheck] = JobOffer("Проверка задачи…", icon: "checkmark.shield", help: "Команда verify задачи запускается только после подтверждения её текста")
        } else if job.taskCheckRefusal == nil, job.state == .done, !job.hadWorktree, job.verifyNote.hasPrefix(Self.taskCheckRefused) {
            o[.recheckMain] = JobOffer("Проверить", icon: "checkmark.seal", help: "Запустить проверку проекта и проверку задачи")
        }
        if job.kind != .reply, job.state == .failed || job.state == .cancelled {
            o[.retry] = JobOffer(job.interrupted ? "Продолжить" : "Повторить", icon: "arrow.clockwise",
                                 help: job.interrupted ? "Продолжить с того места, где прервалось" : "Запустить заново", blocked: child)
        }
        let container = inContainer(job)
        if job.sessionID != nil, !job.isActive, job.agentID == .claude, !container {
            o[.resumeTerminal] = JobOffer("Продолжить диалог в терминале", icon: "apple.terminal.on.rectangle", blocked: embedded ? terminalClaudeBlocked(job) : nil)
            if embedded { o[.resumeExternal] = JobOffer("Продолжить диалог во внешнем терминале", icon: "apple.terminal.on.rectangle") }
        }
        if !container, embedded ? job.state != .pending : (job.worktree != nil && !job.isActive) {
            let t = Terminals.shared, running = t.tabs(job).contains(where: \.isRunning)
            o[.terminal] = JobOffer((embedded && t.shown.contains(job.id) ? "Скрыть терминал" : job.worktree == nil ? "Терминал в папке проекта" : "Терминал в worktree")
                                    + (running ? " (идёт процесс)" : ""),
                                    icon: running ? "terminal.fill" : "terminal", blocked: job.worktreeBusy ? "с веткой сейчас что-то делают" : nil)
            if embedded { o[.terminalExternal] = JobOffer("Внешний терминал", icon: "macwindow") }
        }
        if job.kind == .runTask, job.state != .pending, !job.worktreeBusy, !container {
            o[.server] = JobOffer(DevServers.shared.isRunning(in: job.runDir) ? "Dev-сервер (запущен)…" : "Dev-сервер…", icon: "play.circle")
        }
        if job.kind == .runTask, job.sessionID != nil, capabilities(job).contains(.fork) {
            o[.fork] = JobOffer("Ответвить (fork)…", icon: "arrow.triangle.branch", blocked: forkBlocked(job))
        }
        if job.kind == .runTask, job.agent != nil, job.pipeline == nil, !job.fullyMerged, job.state != .running, job.state != .pending || job.limitWait != nil {
            o[.handoff] = JobOffer("Передать другому агенту…", icon: "arrow.left.arrow.right",
                                   help: "Другой профиль продолжит задачу в той же ветке; перед отправкой покажу текст", blocked: handoffBlocked(job))
        }
        if job.kind == .runTask && job.state == .done {
            o[.review] = JobOffer(job.verdict == nil ? "Ревью" : "Ревью заново", icon: "text.magnifyingglass",
                                  blocked: child ?? (job.merged ? "уже слито" : job.pipelineOpen ? waitsForPipeline : nil))
        }
        // Main-folder job. A job with `baseCommit` had a worktree that is gone: the main folder isn't its diff.
        let inMain = job.kind == .runTask && job.worktree == nil && !job.merged
        if inMain && job.state != .pending && job.baseCommit.isEmpty || job.worktree != nil && job.state != .pending {
            o[.diff] = JobOffer("Изменения", icon: "plusminus", help: "Просмотр изменений")
            o[.diffTerminal] = JobOffer("Изменения в терминале", icon: "plusminus")
        }
        if inMain && job.state == .done && job.projectID != nil {
            o[.commit] = JobOffer("Коммит и пуш…", icon: "checkmark.diamond", help: "Коммит (Claude напишет сообщение) и пуш")
        }
        if job.worktree != nil, !job.isFollowUp, job.kind != .review {
            o[.checkpoints] = JobOffer("Чекпоинты…", icon: "clock.arrow.circlepath")
        }
        if job.verdict == .issues && !job.reviewFixed, canFix(job), !job.pipelineOpen {
            o[.fixReview] = JobOffer("Исправить замечания", icon: "wrench.and.screwdriver", help: "Агент исправит замечания ревью", blocked: child)
        }
        if !job.isGroup, job.worktree != nil, let pr = job.pullRequest, pr.pr.state == .merged, !pr.leftover {
            o[.pullBase] = JobOffer("Подтянуть \(pr.pr.base)", icon: "arrow.down",
                                    help: "git fetch и merge --ff-only в основной папке; потом worktree удалится и зависимые задачи стартуют",
                                    blocked: job.worktreeBusy ? "с веткой сейчас что-то делают" : nil)
        }
        if job.hasWorktree, !job.isActive {
            if job.isGroup {
                if job.awaitsMerge, !job.members.contains(where: { $0.mergePhase != nil }) {
                    o[.mergeAll] = JobOffer("Слить все", icon: "arrow.triangle.merge",
                                            help: "Репозитории задачи сливаются по очереди, каждый отдельно: сбой одного не откатывает остальные",
                                            blocked: busy(job) ?? (job.pipelineOpen ? waitsForPipeline : nil))
                }
            } else {
                o.merge(branchOffers(job)) { a, _ in a }
            }
            if let why = job.auto.parked, onAutopilot(job) {
                o[.returnAutopilot] = JobOffer("Вернуть автопилоту", icon: "arrow.clockwise", help: "Отложено: \(why). Попробовать ещё раз", blocked: busy(job))
            }
            o[.discard] = JobOffer(job.isGroup ? "Удалить worktree и ветки во всех репозиториях" : "Удалить worktree и ветку \(job.worktree?.branch ?? "")",
                                   icon: "trash", blocked: busy(job))
        }
        if !job.isActive, job.sessionID != nil || !job.log.isEmpty {
            o[.snapshot] = JobOffer("Снимок задачи…", icon: "square.and.arrow.up", help: "Разговор в markdown без ключей и домашних путей")
        }
        if job.projectID != nil { o[.openProject] = JobOffer("Открыть проект", icon: "arrow.right.circle") }
        return o
    }

    /// What can be done with one branch: of the task, or of one of its repositories.
    func branchOffers(_ m: Job) -> [JobAction: JobOffer] {
        guard let w = m.worktree else { return [:] }
        var o: [JobAction: JobOffer] = [:]
        let busy = busy(m), red = m.mergeCheck?.state == .red
        if m.mergeFailed, canResolve(m) {
            o[.resolveConflict] = JobOffer("Разрешить конфликт", icon: "arrow.triangle.branch",
                                           help: "Claude вливает основную ветку в эту ветку (в worktree) и разрешает конфликт", blocked: busy)
        }
        if red {
            o[.fixCheck] = JobOffer("Исправить с main", icon: "wrench.and.screwdriver",
                                    help: "Продолжить сессию агента: ветка не проходит проверку вместе с основной веткой", blocked: busy)
        }
        if m.mainConflict, canResolveMain {
            o[.resolveMain] = JobOffer("Конфликты в main", icon: "exclamationmark.triangle",
                                       help: "В основной папке висят неразрешённые конфликты — агент разрешит их")
        }
        let blocked = busy ?? (m.pipelineOpen ? waitsForPipeline : nil)
        let open = m.pullRequest?.pr.state == .open
        if m.committed, !m.merged, open || !m.hasLivePR {
            o[.pullRequest] = JobOffer(open ? "Обновить PR" : "Создать PR", icon: "arrow.triangle.pull",
                                       help: open ? "Отправить новые коммиты ветки — с предпросмотром"
                                           : "Пуш ветки и pull request через gh — с предпросмотром, до подтверждения ничего не отправляется", blocked: blocked)
        }
        if let phase = m.mergePhase {
            o[.stopMerge] = JobOffer("Остановить слияние", icon: "stop.fill", help: "Основная папка не тронута",
                                     blocked: phase == .landing ? "ветка уже сливается" : nil)
        } else if m.committed && !m.hasLivePR && !m.merged {
            o[.merge] = JobOffer(red ? "Проверить снова" : "Слить", icon: "arrow.triangle.merge",
                                 help: red ? "Повторить проверку вместе с основной веткой; если пройдёт — ветка сольётся"
                                     : "Влить основную ветку в \(w.branch), проверить там и слить проверенное в текущую ветку проекта", blocked: blocked)
        }
        return o
    }
}
