import Foundation

/// Picks Sonnet or Opus for a queue task without asking an LLM when the answer is obvious.
/// Only `.ask` falls back to the Haiku classification run.
public enum ModelPick {
    public enum Choice: Equatable, Sendable {
        case sonnet(String)
        case opus(String)
        /// Unclear — let Haiku decide.
        case ask
    }

    /// Words (lowercased stems) that mark hard work: architecture, migrations, concurrency…
    /// One of these in the title is enough for Opus.
    public static let strongMarkers = [
        "архитектур", "миграц", "конкурентн", "многопоточ", "deadlock", "race condition",
        "уязвим", "с нуля", "переписать", "переписывание",
    ]
    /// Common words that hint at hard work but also show up in routine tasks
    /// («опечатка в тексте про безопасность»): counted only in the body, together with another marker.
    public static let weakMarkers = ["безопасност", "алгоритм", "исследова", "гонк"]
    public static var hardMarkers: [String] { strongMarkers + weakMarkers }

    /// Body shorter than this with few checklist items and no code is a small routine task.
    public static let shortBody = 700
    public static let shortChecklist = 3

    public static func heuristic(title: String, body: String, size: String) -> Choice {
        switch size.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "s": return .sonnet("оценка S")
        case "l": return .opus("оценка L")
        default: break
        }
        let t = title.lowercased(), b = body.lowercased()
        if let m = strongMarkers.first(where: { t.contains($0) }) { return .opus("в названии «\(m)…»") }
        let inBody = hardMarkers.filter { b.contains($0) }
        if inBody.count >= 2 { return .opus("сложная: \(inBody.prefix(2).joined(separator: ", "))…") }

        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let checklist = text.split(separator: "\n").filter {
            let l = $0.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("- [ ]") || l.hasPrefix("- [x]") || l.hasPrefix("- [X]")
        }.count
        if inBody.isEmpty, text.count < shortBody, checklist <= shortChecklist, !text.contains("```") {
            return .sonnet("короткая задача")
        }
        return .ask
    }
}
