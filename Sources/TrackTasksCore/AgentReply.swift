import Foundation

/// One message the user sent to a finished job's claude session, with the agent's answer.
/// Kept on the job itself, so the history outlives the child job that ran it.
public struct AgentReply: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case active, done, failed, cancelled }

    /// Id of the child job that carries the message.
    public var id: UUID
    public var text: String
    public var date: Date
    public var state: State
    public var answer: String
    public var error: String
    /// How far the message got; nil = the agent was not started with it.
    public var delivery: Delivery?
    /// `DiffSource.key` of the diff comments the message carries.
    public var drafts: String?
    /// `PreviewDraft.id` the message was made from.
    public var preview: UUID?
    /// Snapshots in `PreviewFolder` that go with the message. Optional: older queue files don't have it.
    public var shots: [String]?

    public enum Delivery: String, Codable, Sendable {
        /// Given to the agent; no sign that it has it.
        case launched
        case accepted
    }

    public init(id: UUID, text: String, date: Date = Date(), state: State = .active, answer: String = "", error: String = "") {
        self.id = id
        self.text = text
        self.date = date
        self.state = state
        self.answer = answer
        self.error = error
    }

    /// The message wasn't handled to the end: its text can be sent again.
    public var canRepeat: Bool { state == .failed || state == .cancelled }

    /// What the drafts sent in this message are now; nil = they arrived. `active`: its job waits or runs.
    public func draftState(active: Bool) -> DiffDelivery.State? {
        if delivery == .accepted { return nil }
        if active { return .sending }
        return delivery == nil && state != .active ? .failed : .unclear
    }

    /// After a restart: a message whose child job no longer waits or runs was interrupted.
    public static func restored(_ replies: [AgentReply], activeJobs: Set<UUID>) -> [AgentReply] {
        replies.map { r in
            guard r.state == .active, !activeJobs.contains(r.id) else { return r }
            var r = r
            r.state = .failed
            r.error = "Прервано: приложение было закрыто."
            return r
        }
    }

    /// Why a message can't be sent to the job's session now; nil = it can.
    public static func blocked(isActive: Bool, hasSession: Bool, ranInWorktree: Bool, hasWorktree: Bool,
                               merged: Bool, worktreeBusy: Bool, hasActiveChild: Bool) -> String? {
        if isActive { return "Задача ещё выполняется" }
        if !hasSession { return "У задачи нет сессии Claude" }
        // Claude keeps sessions per working directory: without the worktree there is nothing to continue.
        if ranInWorktree, !hasWorktree {
            return merged ? "Ответить нельзя: ветка слита и worktree удалён, а сессия привязана к его папке"
                : "Ответить нельзя: worktree удалён, а сессия привязана к его папке"
        }
        if worktreeBusy { return "Идёт слияние или удаление worktree" }
        if hasActiveChild { return "Дождись текущего ответа, ревью или исправления" }
        return nil
    }
}
