import Foundation

/// «Автопилот»: what to do next with a finished branch. Pure; the queue carries it out and calls again after every event.
public enum Autopilot {
    public enum Verdict: Sendable { case ok, issues }

    public struct Facts: Sendable {
        /// Nothing runs on the branch, the worktree is not busy, the branch has unmerged commits.
        public var ready = true
        public var taskDone = true
        /// The agent asked and the answers aren't given to it yet.
        public var awaitsAnswers = false
        public var livePR = false
        public var rolledBack = false
        /// `verify:` now and when the mode was turned on.
        public var verify = ""
        public var approvedVerify: String?
        /// The check can't run where the code may: see `ContainerVerify`.
        public var needsMac = false
        /// Why the task's own check can't be run, nil = it can or there is none.
        public var taskCheck: String?
        public var verdict: Verdict?
        public var reviewFixed = false
        public var mergeConflict = false
        public var checkRed = false
        /// How many automatic steps of each kind were made.
        public var reviews = 0, fixes = 0, repairs = 0, merges = 0
        public init() {}
    }

    public enum Step: Equatable, Sendable {
        case wait, review, fixReview, resolveConflict, fixCheck, merge
        case park(String)
    }

    public static let maxReviews = 5, maxFixes = 2, maxRepairs = 2, maxMerges = 3

    public static let awaitsAnswersReason = "ждёт ответов"
    public static let notClosedReason = "агент не закрыл задачу (status не done)"

    /// Reasons of `taskCheck` start with it.
    public static let taskCheckReason = "проверка задачи не готова: "

    public static func step(_ f: Facts) -> Step {
        guard f.ready else { return .wait }
        if f.livePR { return .park("открыт PR") }
        if f.rolledBack { return .park("откат не закоммичен") }
        if f.verify.isEmpty { return .park("в about.md нет verify") }
        if f.verify != f.approvedVerify { return .park("verify в about.md изменилась после включения автопилота") }
        if f.needsMac { return .park("проверку нельзя выполнить в контейнере — слей вручную") }
        if let why = f.taskCheck { return .park(taskCheckReason + why) }
        if f.awaitsAnswers { return .park(awaitsAnswersReason) }
        if !f.taskDone { return .park(notClosedReason) }
        if f.mergeConflict { return f.repairs < maxRepairs ? .resolveConflict : .park("конфликт не разрешён за \(maxRepairs) попытки") }
        if f.checkRed { return f.repairs < maxRepairs ? .fixCheck : .park("проверка вместе с main не прошла после \(maxRepairs) исправлений") }
        switch f.verdict {
        case .issues where !f.reviewFixed:
            return f.fixes < maxFixes ? .fixReview : .park("замечания ревью остались после \(maxFixes) исправлений")
        case .ok:
            return f.merges < maxMerges ? .merge : .park("слияние не удалось \(maxMerges) раза")
        case .issues, nil:
            // Also after a fix: the new code has no verdict yet.
            return f.reviews < maxReviews ? .review : .park("ревью не дало вердикта «ОК»")
        }
    }
}
