import Foundation

/// How far a task's pipeline has got. Holds its own copy of the workflow: later edits of the file change nothing.
public struct PipelineState: Codable, Equatable, Sendable {
    public enum Status: Codable, Equatable, Sendable {
        /// Not begun.
        case ready
        case running
        /// Waits for the person.
        case stopped(Gate)
        case finished
    }

    public struct Gate: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case before, after, limit, trouble }
        public var kind: Kind
        public var reason: String
        /// Where «Продолжить» leads; nil = it can't.
        public var next: Workflow.Target?
    }

    public let name: String
    public let workflow: Workflow
    /// Profile of the task: steps without their own.
    public var taskProfile: String
    public var status = Status.ready
    public var current = 0
    public var visits: [Int]
    /// All runs of the task: its job, the follow-ups and earlier attempts.
    public var cost = AgentCost()
    /// The follow-up job of the current step.
    public var child: UUID?

    public init(name: String, workflow: Workflow, taskProfile: String = "") {
        self.name = name
        self.workflow = workflow
        self.taskProfile = taskProfile
        visits = Array(repeating: 0, count: workflow.steps.count)
    }

    /// From the beginning, with the money already spent.
    public func restarted() -> PipelineState {
        var s = PipelineState(name: name, workflow: workflow, taskProfile: taskProfile)
        s.cost = cost
        return s
    }

    public var step: Workflow.Step? { workflow.steps.indices.contains(current) ? workflow.steps[current] : nil }
    public var isOpen: Bool { status != .finished }
    public var gate: Gate? { if case .stopped(let g) = status { g } else { nil } }
    public var total: Int { visits.reduce(0, +) }

    /// Known cost reached the budget. Unknown cost isn't counted: `repeats` holds those.
    public var overBudget: Bool { workflow.budget.map { cost.usd >= $0 } ?? false }

    /// "≥ $1.20 из $5.00 · нет данных"
    public var costText: String? {
        var t = cost.text()
        if let b = workflow.budget { t = (t ?? "$0.00") + String(format: " из $%.2f", b) }
        if cost.unknown, cost.usd > 0 { t = (t ?? "") + " · часть: \(AgentCost.noData)" }
        return t
    }
}

/// Chooses the next step. Pure; the queue carries it out. There is no merge among the actions.
public enum Pipeline {
    public static let maxSteps = 30
    public static let awaitsAnswersReason = "ждёт ответов"

    public enum Event: Equatable, Sendable {
        case begin
        /// plan, code or fix ended well.
        case succeeded
        /// nil = the review has no strict verdict.
        case verdict(ok: Bool?)
        case failed(String)
        case verifyRed
        case nothingChanged
        /// A review changed code.
        case tampered
        /// Code changed outside the steps (a reply to the agent).
        case changedOutside
        case userContinue, userRepeat, userFinish
        /// The step ended with questions; `changed`: there is code to go on with.
        case questions(changed: Bool)
        /// The agent got the answers and changed nothing.
        case answered
        /// The failed step goes on: its run is still on a server.
        case reattach
        /// «Доработать» a plan.
        case userRework
    }

    public enum Action: Equatable, Sendable {
        case start(Int)
        case gate(String)
        case finished
        /// The event doesn't apply now.
        case none
    }

    public static func next(_ s: inout PipelineState, _ event: Event) -> Action {
        let i = s.current, w = s.workflow
        let onward = w.next(after: i)
        switch event {
        case .begin:
            guard s.status == .ready else { return .none }
            return enter(&s, 0)
        case .succeeded:
            guard s.status == .running else { return .none }
            return leave(&s, to: onward)
        case .verdict(let ok):
            guard s.status == .running else { return .none }
            switch ok {
            case true?: return leave(&s, to: onward)
            case false?:
                guard let t = w.onIssues(i) else { return stop(&s, .trouble, "Ревью: есть замечания", onward) }
                return leave(&s, to: t)
            case nil: return stop(&s, .trouble, "Ревью без вердикта в первой строке", onward)
            }
        case .failed(let why):
            guard s.status == .running else { return .none }
            return stop(&s, .trouble, "Шаг «\(s.step?.title ?? "")» не выполнен: \(why)", nil)
        case .verifyRed:
            guard s.status == .running else { return .none }
            return stop(&s, .trouble, "Проверка verify не прошла", onward)
        case .nothingChanged:
            guard s.status == .running else { return .none }
            // Without code there is nothing to review.
            return stop(&s, .trouble, "Шаг «\(s.step?.title ?? "")» не изменил код", s.step?.type == .code ? nil : onward)
        case .questions(let changed):
            guard s.status == .running else { return .none }
            return stop(&s, .trouble, awaitsAnswersReason, changed ? onward : nil)
        case .answered:
            guard let g = s.gate, g.reason == awaitsAnswersReason else { return .none }
            return stop(&s, g.kind, "Агент получил ответы", g.next)
        case .tampered:
            guard s.status == .running else { return .none }
            return stop(&s, .trouble, "Ревьюер изменил код — посмотри diff", nil)
        case .changedOutside:
            let to: Workflow.Target? = switch s.status {
            case .finished: .end
            case .stopped(let g): g.next ?? (s.step?.type == .review ? nil : onward)
            case .running: s.step?.type == .review ? nil : onward
            case .ready: nil
            }
            return stop(&s, .trouble, "Код изменён вне шагов пайплайна", to)
        case .userContinue:
            guard let g = s.gate, let t = g.next else { return .none }
            switch t {
            case .end: s.status = .finished; return .finished
            // The limits were checked before the stop, or it is them the person lets through.
            case .step(let n): return enter(&s, n, skipLimits: g.kind == .limit || g.kind == .before, skipBefore: g.kind == .before)
            }
        case .userRepeat:
            guard let g = s.gate, g.kind == .trouble || g.kind == .after else { return .none }
            return enter(&s, i, skipLimits: true, skipBefore: true)
        case .reattach:
            guard s.gate?.kind == .trouble else { return .none }
            s.status = .running
            return .none
        case .userRework:
            guard s.gate?.kind == .after, s.step?.type == .plan else { return .none }
            s.status = .running
            return .none
        case .userFinish:
            guard s.gate != nil else { return .none }
            s.status = .finished
            return .finished
        }
    }

    private static func stop(_ s: inout PipelineState, _ kind: PipelineState.Gate.Kind, _ reason: String, _ next: Workflow.Target?) -> Action {
        s.status = .stopped(.init(kind: kind, reason: reason, next: next))
        s.child = nil
        return .gate(reason)
    }

    private static func leave(_ s: inout PipelineState, to t: Workflow.Target?) -> Action {
        // The linter rejects unknown names; a damaged state must not end a pipeline by itself.
        guard let t else { return stop(&s, .trouble, "Нет следующего шага", nil) }
        if s.step?.stops == .after { return stop(&s, .after, "Остановка после шага «\(s.step?.title ?? "")»", t) }
        switch t {
        case .end:
            s.status = .finished
            s.child = nil
            return .finished
        case .step(let n): return enter(&s, n)
        }
    }

    private static func enter(_ s: inout PipelineState, _ n: Int, skipLimits: Bool = false, skipBefore: Bool = false) -> Action {
        guard s.workflow.steps.indices.contains(n), s.visits.indices.contains(n) else { return stop(&s, .trouble, "Нет следующего шага", nil) }
        let step = s.workflow.steps[n]
        if !skipLimits {
            if s.total >= maxSteps { return stop(&s, .limit, "Потолок: \(maxSteps) шагов", .step(n)) }
            if let r = step.repeats, s.visits[n] >= r { return stop(&s, .limit, "Шаг «\(step.title)»: повторы исчерпаны (\(r))", .step(n)) }
            if s.overBudget { return stop(&s, .limit, "Бюджет исчерпан: \(s.costText ?? "")", .step(n)) }
        }
        if !skipBefore, step.stops == .before { return stop(&s, .before, "Остановка перед шагом «\(step.title)»", .step(n)) }
        s.current = n
        s.visits[n] += 1
        s.child = nil
        s.status = .running
        return .start(n)
    }

    /// Only the first line counts, and it must be nothing but the verdict.
    public static func verdict(_ text: String) -> Bool? {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? ""
        let line = first.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "."))).uppercased()
        switch line {
        case "ВЕРДИКТ: ОК", "ВЕРДИКТ: OK": return true
        case "ВЕРДИКТ: ПРАВКИ": return false
        default: return nil
        }
    }
}
