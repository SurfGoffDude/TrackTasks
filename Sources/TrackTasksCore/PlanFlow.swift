import Foundation

/// Phases of «Согласование плана до кода» and the transitions between them (pure logic; the queue carries them out).
/// planning: read-only run that writes «## План»; awaiting: plan written, waits for the user; approved: the code run.
public enum PlanFlow {
    public enum Phase: String, Codable, Sendable { case planning, awaiting, approved }

    /// Fingerprint stored when the project folder isn't a git repo: code changes can't be detected there.
    public static let noGit = "nogit"

    /// «Одобрить»: only a waiting plan can be approved.
    public static func approve(_ p: Phase?) -> Phase? { p == .awaiting ? .approved : nil }

    /// The approved code run continues the planning session, which ran in the main folder; a worktree run starts fresh.
    public static func resumesPlanSession(_ p: Phase?, inMainFolder: Bool) -> Bool { p == .approved && inMainFolder }

    /// «Доработать»: needs a waiting plan and a non-empty comment; returns the new phase and the trimmed comment.
    public static func rework(_ p: Phase?, comment: String) -> (phase: Phase, feedback: String)? {
        let t = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return p == .awaiting && !t.isEmpty ? (.planning, t) : nil
    }

    public enum Outcome: Equatable, Sendable {
        case awaitApproval
        case failed(String)
    }

    /// What follows a planning run that ended without errors.
    /// `before`/`after`: code fingerprints; `unreliable`: another job worked in the same folder meanwhile.
    public static func afterRun(hasPlan: Bool, before: String?, after: String?, unreliable: Bool) -> Outcome {
        guard let before else { return .failed("Не удалось снять состояние кода до плана — повтори запуск («Повторить»)") }
        if before != noGit, !unreliable, after != before {
            return .failed("Агент изменил код до одобрения плана — проверь git status")
        }
        return hasPlan ? .awaitApproval : .failed("Агент не записал «## План» в файл задачи")
    }
}
