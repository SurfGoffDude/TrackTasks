import Foundation
import TrackTasksCore

/// Questions of the agent in the task file, as the queue last saw them. Lives on the task's own job.
struct JobQuestions: Codable, Equatable {
    struct Item: Codable, Equatable {
        var text: String
        var options: [String] = []
        var recommended: [Int] = []
    }
    /// Without an answer.
    var open: [Item] = []
    /// Answered in the file, but the agent hasn't worked with the answers yet.
    var written: [String] = []
    /// The reply that carries them.
    var sending: UUID?
    /// The person was told about these.
    var notified: [String] = []
    /// The record was damaged: which answers the agent knows isn't known.
    var lost = false

    var isEmpty: Bool { self == JobQuestions() }
    var waits: Bool { !open.isEmpty || !written.isEmpty || lost }
}

/// A damaged value must not lose the queue, and it must not let a plan through either.
struct LenientJobQuestions: Codable {
    var value: JobQuestions
    init(_ value: JobQuestions) { self.value = value }
    init(from decoder: Decoder) throws { value = (try? JobQuestions(from: decoder)) ?? JobQuestions(lost: true) }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// The agent asked: only this task and its dependents wait, the slot is free. The app never answers by itself.
extension JobQueue {
    enum AnswerOutcome: Equatable {
        /// In the file; `left` questions are still open (0: the waiting run will read them, or there is no job).
        case saved(left: Int)
        case continued
        /// In the file, but the agent can't go on now; «Отправить» again later.
        case refused(String)
        /// Nothing is written, nothing is started.
        case writeFailed(String)
        /// The answers are being sent or the agent works.
        case busy
    }

    typealias Answers = [(question: String, answer: String)]

    enum QuestionsRead {
        /// The agent isn't at work: what is answered now was answered by the person.
        case idle
        /// A turn has ended: what it answered itself isn't news to it.
        case turnEnded
    }

    // MARK: State

    func latestJob(forTask path: String) -> Job? { jobs.last { $0.taskPath == path && $0.kind == .runTask } }
    private func isLatest(_ job: Job) -> Bool { job.taskPath.map { latestJob(forTask: $0) === job } ?? true }

    /// The agent may be changing the file, or is about to.
    func agentWorks(_ job: Job) -> Bool {
        (job.isActive && !job.awaitingPlan) || jobs.contains { $0.parentID == job.id && $0.isActive }
    }

    /// A finished task or a waiting plan whose questions aren't closed. A merged branch was the person's decision.
    func awaitsAnswers(_ job: Job) -> Bool {
        guard job.kind == .runTask, job.state == .done || job.awaitingPlan && job.state == .pending,
              job.answering || job.questions?.waits == true else { return false }
        return !job.fullyMerged && isLatest(job)
    }

    /// What the person sees: also a failed run, unlike `awaitsAnswers`, which holds the dependents.
    func questionStatus(_ job: Job) -> QuestionStatus {
        guard job.kind == .runTask, let q = job.questions else { return .none }
        return .of(open: q.open.count, undelivered: !q.written.isEmpty || q.lost, busy: agentWorks(job),
                   closed: job.state == .cancelled || job.fullyMerged || !isLatest(job))
    }

    /// «Ждут ответа: N» of the queue and the sidebar.
    var waitingAnswers: String? { QuestionStatus.counter(jobs.map(questionStatus)) }

    /// Reads the file. False: it can't be read, so nothing is known.
    @discardableResult
    func refreshQuestions(_ job: Job, _ how: QuestionsRead = .idle) -> Bool {
        guard job.kind == .runTask, let path = job.taskPath else { return true }
        let url = URL(fileURLWithPath: path)
        guard let t = Codec.task(at: url) else {
            // Archived or deleted: nobody will answer.
            if !job.isActive, !FileManager.default.fileExists(atPath: path) { job.questions = nil }
            return false
        }
        readQuestions(job, t, how)
        return true
    }

    private func readQuestions(_ job: Job, _ t: TaskItem, _ how: QuestionsRead) {
        let old = job.questions ?? JobQuestions()
        let all = t.status == .done ? [] : AgentQuestions.parse(t.body)
        let answered = all.filter { !$0.isOpen }.map(\.text)
        var q = old
        q.open = all.filter(\.isOpen).map { question in
            .init(text: question.text, options: question.options.map(\.text),
                  recommended: question.options.indices.filter { question.options[$0].recommended })
        }
        let openTexts = Set(q.open.map(\.text))
        var written = old.written
        if how == .idle {
            written += old.lost ? answered : old.open.map(\.text)
            q.lost = false
        }
        var seen = Set<String>()
        q.written = written.filter { answered.contains($0) && !openTexts.contains($0) && seen.insert($0).inserted }
        if q.open.isEmpty { q.notified = [] }
        let new = q.isEmpty ? nil : q
        if job.questions != new { job.questions = new }
    }

    /// The agent has worked with all the answers.
    func answersTaken(_ job: Job) {
        guard var q = job.questions else { return }
        q.written = []
        q.sending = nil
        q.lost = false
        job.questions = q.isEmpty ? nil : q
    }

    /// After a turn of the task's agent (its own run, a reply, a fix). Returns the task.
    func questionsAfterTurn(_ job: Job, _ state: Job.State) -> Job? {
        guard let task = job.kind == .runTask ? job : job.isFollowUp ? self.job(job.parentID) : nil else { return nil }
        refreshQuestions(task, .turnEnded)
        if state == .done, job === task || task.questions?.sending == job.id { answersTaken(task) }
        return task
    }

    /// Tells the person once about every new question. Saved before it is sent: a restart doesn't repeat it.
    @discardableResult
    func noteQuestions(_ job: Job) -> Bool {
        guard var q = job.questions, !q.open.isEmpty, job.awaitingPlan || job.state == .done || job.state == .failed,
              job.state != .cancelled, !job.fullyMerged, isLatest(job) else { return false }
        let new = q.open.map(\.text).filter { !q.notified.contains($0) }
        guard !new.isEmpty else { return false }
        q.notified += new
        job.questions = q
        saveNow()
        questionNotice(job)
        return true
    }

    /// Neither the local notice nor the push has the text of the question.
    static func postQuestionNotice(_ job: Job) {
        PhonePush.send(.permission, job: job, wait: .question)
        Notifier.shared.post(title: "Агент ждёт ответа", body: "\(job.projectName): \(job.title)", jobID: job.id)
        Attention.request()
    }

    /// After the queue was loaded.
    func restoreQuestions() {
        let needed = Set(jobs.filter { $0.state == .pending }.flatMap(\.dependsOn))
        for job in jobs where job.kind == .runTask && !agentWorks(job)
            && (job.awaitingPlan || job.questions != nil || (job.state == .done && needed.contains(job.id))) {
            refreshQuestions(job)
            noteQuestions(job)
        }
    }

    /// A task file changed.
    func syncQuestions(_ projects: [Project]) {
        var changed = false
        for p in projects {
            let mine = jobs.filter { $0.projectID == p.id && $0.kind == .runTask && $0.taskPath != nil && !$0.answering && !agentWorks($0) }
            guard !mine.isEmpty else { continue }
            let tasks = Dictionary(p.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for j in mine {
                let open = tasks[j.taskPath!].map { AgentQuestions.open(in: $0.body, done: $0.status == .done).map(\.text) } ?? []
                let known = j.questions
                // The list may be older than the last turn: only a reason to look at the file itself.
                guard open != known?.open.map(\.text) ?? [] || known?.written.isEmpty == false || known?.lost == true else { continue }
                refreshQuestions(j)
                guard j.questions != known else { continue }
                changed = true
                if !awaitsAnswers(j) { unpark(j, [Autopilot.awaitsAnswersReason]) }
                noteQuestions(j)
            }
        }
        if changed { save(); pump() }
    }

    /// The autopilot waited only for this. Its counters stay.
    func unpark(_ job: Job, _ reasons: [String]) {
        guard let why = job.auto.parked, reasons.contains(why) else { return }
        job.auto.parked = nil
        job.autoHold = nil
        if job.worktreeNote == Self.parkedNote(why) { job.worktreeNote = "" }
    }

    // MARK: Answers

    func submitAnswers(taskPath: String, _ answers: Answers) async -> AnswerOutcome {
        if let j = latestJob(forTask: taskPath) { return await submitAnswers(j, answers) }
        if case .failure(let e) = await Self.writeAnswers(taskPath, answers) { return .writeFailed(Self.text(e)) }
        let open = Codec.task(at: URL(fileURLWithPath: taskPath)).map { AgentQuestions.open(in: $0.body, done: $0.status == .done) } ?? []
        return .saved(left: open.count)
    }

    /// Writes the answers; when all questions are closed, the agent goes on.
    func submitAnswers(_ job: Job, _ answers: Answers) async -> AnswerOutcome {
        guard !job.answering, job.state != .running, !hasRunningTurn(job) else { return .busy }
        guard let path = job.taskPath else { return .writeFailed("У задачи нет файла") }
        let wasCancelled = job.state == .cancelled
        job.answering = true
        let r = await Self.writeAnswers(path, answers)
        job.answering = false
        switch r {
        case .failure(let e):
            return .writeFailed(Self.text(e))
        case .success(let t):
            // Cancelled, repeated, approved meanwhile: the queue decides by what it is now.
            guard jobs.contains(where: { $0 === job }) else { return .saved(left: 0) }
            var q = job.questions ?? JobQuestions()
            // Also what the snapshot didn't know yet.
            q.written += AgentQuestions.parse(t.body).filter { p in
                !p.isOpen && answers.contains { AgentQuestions.sameQuestion($0.question, p.text) }
            }.map(\.text)
            job.questions = q
            guard refreshQuestions(job) else { return .refused("Файл задачи не прочитан") }
            saveNow()
            if job.state == .cancelled, !wasCancelled { return .refused("Задача отменена, пока записывались ответы") }
            let left = job.questions?.open.count ?? 0
            return left > 0 ? .saved(left: left) : continueWithAnswers(job)
        }
    }

    private func hasRunningTurn(_ job: Job) -> Bool { jobs.contains { $0.parentID == job.id && $0.isFollowUp && $0.isActive } }

    private static func text(_ e: Error) -> String { (e as? AgentQuestions.WriteError)?.description ?? e.localizedDescription }

    private static func writeAnswers(_ path: String, _ answers: Answers) async -> Result<TaskItem, Error> {
        let url = URL(fileURLWithPath: path)
        return await TaskWrites.run {
            try TaskFile.change(url) { t in t.body = try AgentQuestions.apply(answers, to: t.body) }
        }
    }

    /// The answers are in the file: give them to the agent. Can be repeated after a refusal.
    func continueWithAnswers(_ job: Job) -> AnswerOutcome {
        guard !job.answering, !hasRunningTurn(job), job.state != .running else { return .busy }
        guard let path = job.taskPath, let t = Codec.task(at: URL(fileURLWithPath: path)) else { return .refused("Файл задачи не прочитан") }
        readQuestions(job, t, .idle)
        let q = job.questions ?? JobQuestions()
        guard q.open.isEmpty, !q.written.isEmpty else { return .saved(left: q.open.count) }
        // Waits for a slot: it will read the file.
        if job.state == .pending, !job.awaitingPlan { return .saved(left: 0) }
        let given: Answers = AgentQuestions.parse(t.body).compactMap { p in
            p.answer.flatMap { q.written.contains(p.text) ? (p.text, $0) : nil }
        }
        if job.awaitingPlan, job.state == .pending {
            reworkPlan(job, comment: AgentQuestions.replyText(given, ending: "Учти ответы в плане."))
            return job.planPhase == .planning ? .continued : .refused("План уже не ждёт ответов")
        }
        // These pass by themselves: no new run instead.
        if job.remoteUnclaimed { return .refused("Запуск на сервере ещё не забран («Повторить»)") }
        if job.worktreeBusy || job.members.contains(where: { $0.mergePhase != nil }) { return .refused("Идёт слияние или удаление worktree") }
        if hasActiveChild(job) { return .refused(replyBlocked(job) ?? "Дождись текущего ответа, ревью или исправления") }
        // A reply to a plan that ended or was cancelled would write code without approval.
        let unapproved = job.planPhase == .planning || job.planPhase == .awaiting
        if !unapproved, replyBlocked(job) == nil {
            guard sendReply(job, text: AgentQuestions.replyText(given)), let id = job.replies.last?.id else { return .refused("Ответ не отправлен") }
            job.questions?.sending = id
            unpark(job, [Autopilot.awaitsAnswersReason, Autopilot.notClosedReason])
            saveNow()
            return .continued
        }
        if job.hasWorktree {
            return .refused((replyBlocked(job) ?? "План не одобрен") + ". В worktree есть работа — новый запуск её бы потерял")
        }
        return runAnew(job)
    }

    /// The session can't be continued and there is no work to lose.
    private func runAnew(_ old: Job) -> AnswerOutcome {
        if let s = old.pipeline, old.state == .done {
            guard s.gate?.kind == .trouble else { return .refused("Пайплайн ждёт твоего решения или завершён — повтори задачу («Повторить»)") }
            if let why = pipelineBlocked(old) { return .refused(why) }
            pipelineRepeat(old)
            return old.state == .pending ? .continued : .refused(old.pipeline?.gate?.reason ?? "Шаг не повторён")
        }
        let wasState = old.state
        restarting = true
        // The old session is gone (or belongs to an unapproved plan).
        old.interrupted = false
        old.rewind = nil
        old.sessionID = nil
        old.resumeSession = nil
        retry(old)
        guard let j = jobs.last, !jobs.contains(where: { $0 === old }) else {
            restarting = false
            return .refused("Задачу сейчас не запустить (\(wasState.rawValue))")
        }
        j.dependsOn = old.dependsOn
        j.wave = old.wave
        j.waveCount = old.waveCount
        j.wavePriority = old.wavePriority
        j.auto = old.auto
        j.auto.parked = nil
        if j.planPhase == .awaiting {
            j.planPhase = .planning
            pipelineEvent(j, .userRework)
        }
        j.planFeedback = ""
        for other in jobs { other.dependsOn = other.dependsOn.map { $0 == old.id ? j.id : $0 } }
        restarting = false
        saveNow()
        pump()
        return .continued
    }
}
