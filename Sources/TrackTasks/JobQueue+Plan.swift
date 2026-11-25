import Foundation
import TrackTasksCore

/// «Согласование плана до кода»: the agent first writes «## План» into the task file and waits.
/// planning (light lane, read-only) → awaiting (pending, takes no slot, survives a restart) → approved (code run).
extension JobQueue {
    static let planLargeKey = "planLarge"
    /// Tasks with `size: l` get a plan first (Settings); `plan: true` in the task file asks for it per task.
    static var planLarge: Bool { UserDefaults.standard.object(forKey: planLargeKey) as? Bool ?? true }

    static func wantsPlan(_ t: TaskItem) -> Bool { t.plan || (planLarge && !t.planOff && t.size == "l") }

    /// The user agreed: the same job goes on to the code run (in the same claude session when it can be resumed).
    func approvePlan(_ job: Job) {
        guard job.state == .pending, !job.answering, let next = PlanFlow.approve(job.planPhase) else { return }
        job.planPhase = next
        job.planFeedback = ""
        job.lastLine = "План одобрен"
        job.log.append("⚙︎ План одобрен")
        // A step without a stop waited for answers only.
        pipelineEvent(job, job.pipeline?.status == .running ? .succeeded : .userContinue)
        save()
        pump()
    }

    /// «Доработать»: the comment goes to the agent, which rewrites «## План» and waits again.
    func reworkPlan(_ job: Job, comment: String) {
        guard job.state == .pending, !job.answering, let r = PlanFlow.rework(job.planPhase, comment: comment) else { return }
        job.planPhase = r.phase
        job.planFeedback = r.feedback
        pipelineEvent(job, .userRework)
        // The user may have edited files while the plan waited: the next run takes a fresh snapshot.
        job.planBaseline = nil
        job.lastLine = "План дорабатывается: \(r.feedback.prefix(120))"
        job.log.append("⚙︎ План на доработку: " + r.feedback)
        save()
        pump()
    }

    /// Fingerprint of code changes in the folder (tracker files excluded): equal before and after = code untouched.
    /// Not a git repo: `PlanFlow.noGit` (nothing to compare); git failure: nil.
    nonisolated static func codeFingerprint(_ cwd: URL) -> String? {
        guard Git.isRepo(cwd) else { return PlanFlow.noGit }
        guard let st = Git.run(["status", "--porcelain", "-z", "-uall"], in: cwd) else { return nil }
        let files = DirtyFiles.significant(DirtyFiles.parsePorcelainZ(st))
        let diff = (Git.run(["diff", "HEAD", "--numstat"], in: cwd) ?? "").split(separator: "\n").filter {
            !DirtyFiles.isTrackerFile(String($0.split(separator: "\t", maxSplits: 2).last ?? ""))
        }
        return (files + diff.map(String.init)).joined(separator: "\n")
    }

    /// Another code job runs in this job's folder (main): the code fingerprint can't tell whose changes they are.
    private func folderShared(with job: Job) -> Bool {
        job.worktree == nil
            && jobs.contains { $0 !== job && $0.state == .running && $0.lane == .code && $0.worktree == nil && $0.cwd == job.cwd }
    }

    /// The code state is taken first and the run starts only after it: the baseline always exists.
    /// The job holds its slot meanwhile.
    func snapshotThenStart(_ job: Job) {
        let wasRunning = job.state == .running
        job.state = .running
        job.lastLine = "Запоминаю состояние кода перед планом…"
        if !wasRunning { onStarted?(job) }
        let cwd = job.runDir
        Task.detached(priority: .userInitiated) { [weak self] in
            let f = Self.codeFingerprint(cwd)
            await self?.baselineReady(job, f)
        }
    }

    private func baselineReady(_ job: Job, _ fingerprint: String?) {
        guard job.state == .running, job.planPhase == .planning else { return }
        guard let fingerprint else {
            job.lastLine = "Не удалось снять состояние кода (git) — повтори запуск («Повторить»)"
            return finish(job, .failed)
        }
        job.planBaseline = fingerprint
        job.planFolderShared = folderShared(with: job)
        start(job)
    }

    /// The planning run ended without errors: check the plan is in the file and the code is untouched.
    func planRunFinished(_ job: Job) {
        // A server works on its own copy of the code and returns only the task file.
        let away = capabilities(job).contains(.remote)
        let path = job.taskPath, cwd = job.runDir, base = away ? PlanFlow.noGit : job.planBaseline
        if !away, folderShared(with: job) { job.planFolderShared = true }
        let shared = job.planFolderShared && !away
        Task.detached(priority: .utility) { [weak self] in
            let text = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
            let after = shared || away ? nil : Self.codeFingerprint(cwd)
            await self?.planChecked(job, hasPlan: !MD.plan(text).isEmpty, before: base, after: after, shared: shared)
        }
    }

    private func planChecked(_ job: Job, hasPlan: Bool, before: String?, after: String?, shared: Bool) {
        refreshQuestions(job, .turnEnded)
        let asks = job.questions?.open.isEmpty == false
        // Questions instead of a plan are no failure: it would cancel the dependents.
        switch PlanFlow.afterRun(hasPlan: hasPlan || asks, before: before, after: after, unreliable: shared) {
        case .failed(let message):
            job.lastLine = message
            finish(job, .failed)
        case .awaitApproval:
            job.planPhase = .awaiting
            job.state = .pending
            job.planFeedback = ""
            // The planning run read them from the file.
            answersTaken(job)
            job.lastLine = asks ? "План ждёт ответов" : "План готов — ждёт одобрения"
            if shared { job.log.append(Self.planUnchecked) }
            if job.pipeline != nil {
                // The step decides whether it stops here; with questions it never goes on.
                if !asks || job.pipeline?.step?.stops == .after { pipelineEvent(job, .succeeded) }
                guard job.awaitingPlan else { return pump() }
            }
            autoApprovePlan(job)
            guard job.awaitingPlan else { return }
            if !noteQuestions(job) {
                PhonePush.send(.permission, job: job, wait: .plan)
                Notifier.shared.post(title: "План ждёт одобрения", body: "\(job.projectName): \(job.title)", jobID: job.id)
                Attention.request()
            }
            save()
            pump()
        }
    }
}

extension ClaudePrompts {
    static let planSystem = """


        РЕЖИМ ПЛАНА. Сейчас ты НЕ выполняешь задачу и НЕ меняешь код. Изучи проект (только чтение), затем запиши в файл задачи раздел «## План» (если он уже есть — замени его): нумерованный список шагов, у каждого — какие файлы меняешь и чем рискуешь; без чекбоксов «- [ ]». Если без решения пользователя план не составить, дополнительно допиши в файл задачи раздел «## \(AgentQuestions.heading)»: вопрос — пункт верхнего уровня («1. …»), варианты — вложенные пункты («   - …»), рекомендуемый помечай «(рекомендую)»; строку «Ответ:» не пиши — ответит пользователь, сам на свои вопросы не отвечай. Если ответы в этом разделе уже есть — учти их и не задавай те же вопросы. Больше в файле задачи ничего не меняй (status, чек-лист, критерии, заметки оставь как есть), другие файлы не трогай. Затем остановись и ответь одной строкой.
        """

    static func planOnly(_ prompt: String, feedback: String) -> String {
        var s = "ТОЛЬКО ПЛАН: не выполняй задачу и не меняй код — запиши раздел «## План» в файл задачи и остановись. Исходная инструкция ниже нужна лишь чтобы понять задачу.\n\n" + prompt
        if !feedback.isEmpty { s += "\n\nПользователь отклонил предыдущий план. Его комментарий: " + feedback }
        return s
    }

    static func planRework(_ feedback: String) -> String {
        "План нужно доработать. Комментарий пользователя: \(feedback)\nПерепиши раздел «## План» в файле задачи (замени, а не дописывай) и остановись. Код не меняй."
    }

    static func approved(_ prompt: String) -> String {
        "План одобрен, режим «только план» снят: теперь выполняй задачу по разделу «## План» файла задачи (отступление от плана — с причиной в «## Заметки»). Раздел «## План» не удаляй.\n\n" + prompt
    }
}
