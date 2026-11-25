import Foundation

/// Everything that can be done from a card of the queue.
public enum JobAction: String, CaseIterable, Sendable, Identifiable {
    case stop, approveScripts, approveTaskCheck, recheckMain, retry, startDespiteFiles, startDespiteDirty, runInMain
    case merge, mergeAll, stopMerge, resolveConflict, fixCheck, resolveMain, fixReview, pullBase, pullRequest, returnAutopilot
    case diff, review, fork, handoff, resumeTerminal, resumeExternal, terminal, terminalExternal, server, checkpoints
    case diffTerminal, commit, snapshot, openProject, discard
    public var id: String { rawValue }

    public enum Place: Equatable, Sendable { case visible, work, changes, task, danger }

    /// Where the action is when it isn't the main one: a button of its own or a section of «Ещё».
    public var place: Place {
        switch self {
        case .stop, .approveScripts, .approveTaskCheck, .recheckMain, .retry, .startDespiteFiles, .startDespiteDirty, .runInMain, .merge, .mergeAll, .stopMerge,
             .resolveConflict, .fixCheck, .resolveMain, .fixReview, .pullBase, .pullRequest, .returnAutopilot, .diff: .visible
        case .review, .fork, .handoff, .resumeTerminal, .resumeExternal, .terminal, .terminalExternal, .server, .checkpoints: .work
        case .diffTerminal, .commit: .changes
        case .snapshot, .openProject: .task
        case .discard: .danger
        }
    }
}

/// An action the card has now. `blocked`: why it can't be pressed.
public struct JobOffer: Equatable, Sendable {
    public var title: String
    public var icon: String
    public var help: String
    public var blocked: String?
    public init(_ title: String, icon: String, help: String = "", blocked: String? = nil) {
        self.title = title; self.icon = icon; self.help = help; self.blocked = blocked
    }
}

/// Snapshot of a job and of its repositories.
public struct JobFacts: Sendable {
    public enum State: String, Codable, CaseIterable, Sendable { case pending, running, done, failed, cancelled }

    public var state = State.pending
    /// The main run of a task; other kinds have no branch to decide about.
    public var isTask = true
    public var isChild = false
    public var interrupted = false
    /// Why it failed.
    public var lastLine = ""
    /// Requests of the job and of its follow-ups.
    public var permissions = 0
    public var questions = QuestionStatus.none
    public var plan: PlanFlow.Phase?
    /// The pipeline stands: why.
    public var gate: String?
    public var pipelineOpen = false
    /// Title of the merge phase.
    public var merging: String?
    /// Title of the follow-up (review, fix, reply) that goes on.
    public var child: String?
    public var branchBusy = false
    public var waitReason = ""
    public var setup = false
    public var remoteUnclaimed = false

    public var isGroup = false
    public var awaitsMerge = false
    public var merged = false
    public var mainConflict = false
    public var conflict = false
    public var rolledBack = false
    /// `verify` failed on the branch alone / together with main.
    public var verifyFailed = false
    public var mergeRed = false
    /// Why the task's own check can't be run.
    public var taskCheck: String?
    /// It was not run in the main folder, now it can be.
    public var taskCheckToRun = false
    public var remarks = false
    public var prOpen = false
    public var prMerged = false
    /// The autopilot goes on with the branch by itself.
    public var autopilot = false
    /// Why it gave up.
    public var parked: String?

    /// The very actions the card draws; in a brief summary they may be left empty.
    public var offers: [JobAction: JobOffer] = [:]
    /// Actions in the rows of the task's repositories.
    public var repoActions: Set<JobAction> = []
    public init() {}
}

/// What is going on with a job, whether the person is needed and what to do next.
public struct JobGuide: Equatable, Sendable {
    /// Groups of «Ждёт тебя», most urgent first.
    public enum Need: String, CaseIterable, Sendable, Identifiable {
        case permission, questions, plan, pipeline, conflict, red, taskCheck, remarks, failure, rollback, pullRequest, merge
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .permission: "Разрешения"
            case .questions: "Вопросы агента"
            case .plan: "Планы"
            case .pipeline: "Остановки пайплайна"
            case .conflict: "Конфликты"
            case .red: "Красные проверки"
            case .taskCheck: "Проверка задачи не подтверждена"
            case .remarks: "Замечания ревью"
            case .failure: "Ошибки"
            case .rollback: "Незакоммиченный откат"
            case .pullRequest: "Pull request"
            case .merge: "Готово к слиянию"
            }
        }
    }

    /// A block of the card that has the decision's buttons itself.
    public enum Card: Equatable, Sendable { case permission, questions, plan, pipeline, rollback }

    public enum Tone: Equatable, Sendable { case idle, working, attention, bad, good }

    public var status: String
    public var reason = ""
    public var next: String
    public var need: Need?
    public var tone: Tone
    /// The one main action: a button of the row or a block, never both.
    public var main: Main?

    public enum Main: Equatable, Sendable {
        case action(JobAction)
        case card(Card)
    }
    public var primary: JobAction? { if case .action(let a)? = main { a } else { nil } }
    public var card: Card? { if case .card(let c)? = main { c } else { nil } }

    public static func of(_ f: JobFacts) -> JobGuide {
        /// Only what the card shows can be the main action.
        func press(_ a: JobAction, _ why: String, else other: String) -> (String, Main?) {
            guard let o = f.offers[a] else {
                return (f.repoActions.contains(a) ? "Выбери действие в строке репозитория: " + why : other, nil)
            }
            if let b = o.blocked { return ("«\(o.title)» пока недоступно: \(b)", .action(a)) }
            return ("«\(o.title)» — \(why)", .action(a))
        }
        func make(_ status: String, _ reason: String = "", next: (String, Main?), need: Need? = nil, _ tone: Tone) -> JobGuide {
            JobGuide(status: status, reason: reason, next: next.0, need: need, tone: tone, main: next.1)
        }
        func plain(_ s: String) -> (String, Main?) { (s, nil) }

        if f.permissions > 0 {
            return make("Ждёт разрешения" + (f.permissions > 1 ? ": \(f.permissions)" : ""), "Агент остановился и ждёт ответа",
                        next: ("прочитай запрос ниже, разреши или отклони", .card(.permission)), need: .permission, .attention)
        }
        if f.questions.needsPerson {
            return make(f.questions.line, next: (f.questions == .send ? "передай ответы агенту в карточке ниже" : "ответь на вопросы в карточке ниже", .card(.questions)),
                        need: .questions, .attention)
        }
        if f.state == .pending, f.plan == .awaiting {
            return make("План ждёт одобрения", next: ("прочитай план ниже, одобри или верни на доработку", .card(.plan)), need: .plan, .attention)
        }
        // While a follow-up goes on the stop can't be decided.
        if let g = f.gate, f.state == .pending || f.state == .done, f.child == nil, !f.rolledBack {
            return make("Пайплайн остановлен", g, next: ("реши ниже, что делать с шагом", .card(.pipeline)), need: .pipeline, .attention)
        }
        if let m = f.merging { return make("Идёт слияние", m, next: plain("подожди окончания; ошибка появится здесь"), .working) }
        if f.state == .running {
            return make(f.plan == .planning ? "Агент пишет план" : "Выполняется", next: plain("ничего не нужно: если понадобишься, карточка скажет"), .working)
        }
        if let c = f.child { return make("Идёт: \(c)", next: plain("подожди, пока закончится"), .working) }
        if f.branchBusy { return make("С веткой идёт операция", next: plain("подожди, пока закончится"), .working) }

        switch f.state {
        case .running: break
        case .pending:
            let next = f.offers[.startDespiteDirty] != nil ? "закоммить правки — задача стартует сама, или выбери запуск ниже"
                : f.offers[.startDespiteFiles] != nil ? "подожди — задача стартует сама, или запусти, не дожидаясь"
                : f.offers[.runInMain] != nil ? "запусти в основной папке или исправь причину"
                : "ничего не нужно: стартует сама, когда причина пройдёт"
            return make("В очереди", f.waitReason, next: plain(next), .idle)
        case .failed, .cancelled:
            let need: Need? = f.state == .failed && !f.isChild ? .failure : nil
            let tone: Tone = f.state == .cancelled ? .idle : .bad
            if f.setup, f.state == .failed {
                return make("Нужно подтвердить команды", f.lastLine, next: press(.approveScripts, "проверь команды из about.md и запусти", else: "проверь команды из about.md"), need: need, .attention)
            }
            let status = f.state == .cancelled ? "Отменено" : f.interrupted ? "Прервано" : "Ошибка"
            let why = f.remoteUnclaimed ? "подключится к запуску на сервере" : f.interrupted ? "с того места, где прервалось" : "запустить заново"
            return make(status, f.lastLine, next: press(.retry, why, else: "посмотри причину и запусти нужное действие заново"),
                        need: need, f.interrupted && f.state == .failed ? .attention : tone)
        case .done:
            break
        }

        guard f.isTask else { return make("Готово", next: plain("ничего не нужно"), .good) }
        if f.merged { return make("Слито", next: plain("ничего не нужно"), .good) }
        if f.rolledBack {
            return make("Откат не закоммичен", next: ("закоммить откат ниже — без этого ветку не слить", .card(.rollback)), need: .rollback, .attention)
        }
        if f.pipelineOpen { return make("Пайплайн идёт", next: plain("подожди следующего шага"), .working) }
        if f.mainConflict {
            return make("Конфликты в основной папке", "Слить нельзя, пока они не разрешены",
                        next: press(.resolveMain, "агент разрешит их", else: "разреши конфликты в основной папке вручную"), need: .conflict, .bad)
        }
        // The steps below are its own until it gives up.
        if f.autopilot, f.awaitsMerge, !f.prOpen, !f.prMerged {
            return make("Ветку ведёт автопилот", next: plain("ничего не нужно: он проверит и сольёт сам"), .working)
        }
        if f.conflict {
            return make("Конфликт с основной веткой", f.parked ?? "",
                        next: press(.resolveConflict, "агент вольёт основную ветку и разрешит конфликт", else: "разреши конфликт в ветке вручную"), need: .conflict, .bad)
        }
        if f.mergeRed {
            return make("Проверка вместе с main красная", f.parked ?? "",
                        next: press(.fixCheck, "агент исправит ошибки проверки", else: "посмотри ошибки ниже и исправь их"), need: .red, .bad)
        }
        if let why = f.taskCheck {
            return make("Проверка задачи не запущена", why,
                        next: press(.approveTaskCheck, "посмотри команду verify задачи и подтверди её", else: "исправь или убери поле verify в задаче"),
                        need: .taskCheck, .attention)
        }
        if f.taskCheckToRun {
            return make("Проверка задачи не запущена", next: press(.recheckMain, "запустит проверки проекта и задачи", else: "запусти проверку вручную"),
                        need: .taskCheck, .attention)
        }
        if f.verifyFailed {
            return make("Проверка не прошла", f.parked ?? "",
                        next: press(.diff, "посмотри, что сделано, и ответь агенту, что исправить", else: "ответь агенту, что исправить"), need: .red, .bad)
        }
        if f.remarks {
            return make("Есть замечания ревью", f.parked ?? "",
                        next: press(.fixReview, "агент исправит их в той же ветке", else: "посмотри замечания ниже"), need: .remarks, .attention)
        }
        if f.awaitsMerge, f.prMerged {
            return make("PR слит", next: press(.pullBase, "обновит основную папку и уберёт worktree", else: "подтяни основную ветку"), need: .pullRequest, .attention)
        }
        if f.awaitsMerge, f.prOpen {
            return make("Открыт pull request", next: plain("проверь CI и рецензии; после слияния на GitHub подтяни основную ветку"), need: .pullRequest, .attention)
        }
        if f.awaitsMerge {
            return make("Готово к слиянию", f.parked.map { "Автопилот отложил: \($0)" } ?? "",
                        next: press(f.isGroup ? .mergeAll : .merge, "проверит вместе с основной веткой и сольёт", else: "посмотри изменения и слей ветку"),
                        need: .merge, .good)
        }
        return make("Готово", next: press(.commit, "посмотри изменения и закоммить их", else: "ничего не нужно, можно ответить агенту"), .good)
    }
}
