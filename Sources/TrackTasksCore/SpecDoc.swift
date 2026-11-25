import Foundation

/// spectrack.md — what the project is and why: idea, goals, decisions. People own the text; agents read it first.
/// Findings of queue agents are written to «## Находки» of their own task file and moved here by the app,
/// so parallel jobs never edit spectrack.md at the same time.
public enum SpecDoc {
    public static let fileName = "spectrack.md"
    public static let findingsTitle = "Находки"

    /// Case-insensitive: the default macOS file system treats SPECTRACK.md as the same file.
    public static func isSpec(_ path: String) -> Bool { path.lowercased() == fileName }

    /// Existing file with its own letter case, or the default name.
    public static func url(in project: URL) -> URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []
        return project.appendingPathComponent(names.first { $0 == fileName } ?? names.first(where: isSpec) ?? fileName)
    }

    public static func template(name: String, idea: String = "") -> String {
        """
        # \(name) — спецификация

        ## Идея

        \(idea.isEmpty ? "Что это и для кого." : idea)

        ## Цели

        ## Вне границ

        ## Решения

        ## \(findingsTitle)

        """
    }

    /// Items of «## Находки»; indented or wrapped lines are joined to their bullet.
    public static func findings(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let r = section(lines) else { return [] }
        var out: [String] = []
        for raw in lines[r].dropFirst() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let bullet = t.hasPrefix("- ") || t.hasPrefix("* ")
            if bullet, raw.first == "-" || raw.first == "*" || out.isEmpty {
                out.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if out.isEmpty {
                out.append(t)
            } else {
                out[out.count - 1] += " " + t
            }
        }
        return out
    }

    /// The text without its «## Находки» section.
    public static func removingFindings(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let r = section(lines) else { return text }
        lines.removeSubrange(r)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Appends findings not recorded yet to the end of «## Находки» (created if missing); the rest stays verbatim.
    public static func adding(_ items: [String], task: String, date: String, to text: String) -> String {
        var known = findings(in: text)
        var new: [String] = []
        for item in items where !item.isEmpty {
            let entry = "\(item) (tasks/\(task))"
            guard !known.contains(where: { $0.hasSuffix(entry) }) else { continue }
            known.append(entry)
            new.append("- \(date) — \(entry)")
        }
        guard !new.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        if let r = section(lines) {
            var end = r.upperBound
            while end > r.lowerBound + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            if end == r.lowerBound + 1 { new.insert("", at: 0) }
            lines.insert(contentsOf: new, at: end)
            return lines.joined(separator: "\n")
        }
        var head = text
        while head.last?.isNewline == true { head.removeLast() }
        return (head.isEmpty ? "" : head + "\n\n") + "## \(findingsTitle)\n\n" + new.joined(separator: "\n") + "\n"
    }

    /// Lines [heading, next heading of the same or higher level), code fences skipped.
    private static func section(_ lines: [String]) -> Range<Int>? {
        let lines = Evidence.masked(lines)
        var fence: String?
        var start: Int?, level = 0
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if let f = fence { if t.hasPrefix(f) { fence = nil }; continue }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = String(t.prefix(3)); continue }
            let l = t.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(l), t.dropFirst(l).first == " " else { continue }
            if let s = start {
                if l <= level { return s..<i }
            } else if l == 2, t.dropFirst(l).trimmingCharacters(in: .whitespaces).lowercased() == findingsTitle.lowercased() {
                start = i
                level = l
            }
        }
        return start.map { $0..<lines.count }
    }
}
