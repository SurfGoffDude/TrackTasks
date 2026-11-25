import Foundation

/// A project decision: `docs/decisions/<name>.md`, plain markdown.
///
///     # Название решения
///
///     Статус: принято
///     Задачи: 20261123-142024-resheniya-kommentarii.md, other.md
///
///     Свободный текст…
///
/// Only the first `# ` heading and the `Статус:` / `Задачи:` lines are read; everything else is the user's text.
/// Writes edit those lines in place, so manual edits survive.
public struct Decision: Equatable, Sendable, Identifiable {
    public enum Status: String, CaseIterable, Sendable {
        case proposed = "предложено"
        case accepted = "принято"
        case rejected = "отклонено"
        case superseded = "заменено"

        public init?(text: String) {
            let t = text.trimmingCharacters(in: .whitespaces).lowercased()
            guard let s = Status.allCases.first(where: { $0.rawValue == t }) else { return nil }
            self = s
        }
    }

    public static let folder = "docs/decisions"

    public var id: String { fileName }
    public let fileName: String
    public var title: String
    /// nil when the file has no (or an unknown) status line.
    public var status: Status?
    public var statusText: String
    /// Task file names (`Задачи:` line).
    public var tasks: [String]

    /// Repo-relative path, as it is written in a task («docs/decisions/x.md»).
    public var path: String { Self.folder + "/" + fileName }

    private static let statusKey = "Статус:"
    private static let tasksKey = "Задачи:"

    public static func parse(_ text: String, fileName: String) -> Decision {
        let lines = text.components(separatedBy: "\n")
        var title = ""
        var statusText = ""
        var tasks: [String] = []
        var fence: String?
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if let f = fence { if t.hasPrefix(f) { fence = nil }; continue }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = String(t.prefix(3)); continue }
            if title.isEmpty, t.hasPrefix("# ") { title = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            else if statusText.isEmpty, t.hasPrefix(statusKey) { statusText = value(t, statusKey) }
            else if tasks.isEmpty, t.hasPrefix(tasksKey) { tasks = names(value(t, tasksKey)) }
        }
        if title.isEmpty { title = (fileName as NSString).deletingPathExtension }
        return Decision(fileName: fileName, title: title, status: Status(text: statusText),
                        statusText: statusText, tasks: tasks)
    }

    private static func value(_ line: String, _ key: String) -> String {
        String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
    }

    /// "a.md, tasks/b.md" → ["a.md", "b.md"]
    static func names(_ s: String) -> [String] {
        var out: [String] = []
        for p in s.components(separatedBy: CharacterSet(charactersIn: ", \t")) where !p.isEmpty {
            let n = (p as NSString).lastPathComponent
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// New file text.
    public static func make(title: String, status: Status = .proposed, tasks: [String] = [], body: String = "") -> String {
        var s = "# \(title.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(statusKey) \(status.rawValue)\n"
        if !tasks.isEmpty { s += "\(tasksKey) \(tasks.joined(separator: ", "))\n" }
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty { s += "\n" + b + "\n" }
        return s
    }

    public static func settingStatus(_ text: String, _ status: Status) -> String {
        setLine(text, key: statusKey, value: status.rawValue)
    }

    public static func linkingTask(_ text: String, _ task: String) -> String {
        let cur = parse(text, fileName: "").tasks
        let n = (task as NSString).lastPathComponent
        guard !cur.contains(n) else { return text }
        return setLine(text, key: tasksKey, value: (cur + [n]).joined(separator: ", "))
    }

    public static func unlinkingTask(_ text: String, _ task: String) -> String {
        let cur = parse(text, fileName: "").tasks
        let n = (task as NSString).lastPathComponent
        guard cur.contains(n) else { return text }
        let rest = cur.filter { $0 != n }
        return setLine(text, key: tasksKey, value: rest.joined(separator: ", "))
    }

    /// Replaces the first `key` line outside code fences (an empty value removes it); adds the line after the
    /// title / status when missing. Other lines are untouched.
    private static func setLine(_ text: String, key: String, value: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var fence: String?
        var at: Int?
        var afterTitle: Int?
        var afterStatus: Int?
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if let f = fence { if t.hasPrefix(f) { fence = nil }; continue }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = String(t.prefix(3)); continue }
            if afterTitle == nil, t.hasPrefix("# ") { afterTitle = i }
            if afterStatus == nil, t.hasPrefix(statusKey) { afterStatus = i }
            if t.hasPrefix(key) { at = i; break }
        }
        if let at {
            if value.isEmpty { lines.remove(at: at) } else { lines[at] = "\(key) \(value)" }
        } else if !value.isEmpty {
            if let s = afterStatus, key == tasksKey { lines.insert("\(key) \(value)", at: s + 1) }
            else if let t = afterTitle { lines.insert(contentsOf: ["", "\(key) \(value)"], at: t + 1) }
            else { lines.insert(contentsOf: ["\(key) \(value)", ""], at: 0) }
        }
        return lines.joined(separator: "\n")
    }

    /// Decisions linked to a task: ones naming it in `Задачи:` plus ones the task body mentions by path.
    public static func linked(to taskFileName: String, body: String, in all: [Decision]) -> [Decision] {
        // Mentions inside code fences don't count.
        let lines = body.components(separatedBy: "\n")
        let visible = MD.unfenced(lines, 0..<lines.count).map { lines[$0] }.joined(separator: "\n")
        return all.filter { $0.tasks.contains(taskFileName) || visible.contains(folder + "/" + $0.fileName) }
    }
}

extension Decision {
    /// File-name slug from a title: latin letters (Cyrillic transliterated), digits, dashes.
    public static func slug(_ title: String) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? title
        let s = latin.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        let parts = s.split(separator: "-").prefix(6)
        return parts.isEmpty ? "decision" : parts.joined(separator: "-")
    }
}
