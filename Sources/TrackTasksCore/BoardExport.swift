import Foundation

/// Markdown export of a project board and its summary (for README or a report).
/// Pure and deterministic: same tasks → same text, whatever order they come in.
public enum BoardExport {
    /// Characters that Markdown treats specially in inline text.
    private static let special: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "|", "#", "~", "&"]

    /// Text of one line with Markdown characters escaped; line breaks become spaces.
    public static func escape(_ s: String) -> String {
        var out = ""
        let flat = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        for ch in flat {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        // Block markers at the start of the line: "1. x", "- x", "+ x", "> x" (> is already escaped).
        if let first = out.first, first == "-" || first == "+" || first == "!" { out = "\\" + out }
        else if let dot = out.firstIndex(where: { $0 == "." || $0 == ")" }), dot != out.startIndex, out[..<dot].allSatisfy(\.isNumber) {
            out.insert("\\", at: dot)
        }
        return out
    }

    private static func rank(_ p: Priority) -> Int {
        switch p { case .high: 0; case .medium: 1; case .low: 2 }
    }

    /// Stable order: priority (high first), then creation date, then file name.
    /// `newestCompletedFirst`: by completion date, newest first (empty dates last), then as above.
    public static func sorted(_ tasks: [TaskItem], newestCompletedFirst: Bool = false) -> [TaskItem] {
        tasks.sorted {
            if newestCompletedFirst, $0.completed != $1.completed { return $0.completed > $1.completed }
            if rank($0.priority) != rank($1.priority) { return rank($0.priority) < rank($1.priority) }
            if $0.created != $1.created { return $0.created < $1.created }
            return $0.fileName < $1.fileName
        }
    }

    public static func markdown(name: String, tasks: [TaskItem], archive: [TaskItem] = []) -> String {
        let done = tasks.filter { $0.status == .done }.count
        let percent = tasks.isEmpty ? 0 : done * 100 / tasks.count
        var lines = ["# \(escape(name)) — доска", ""]
        lines.append("**Сводка:** всего \(tasks.count), в работе \(tasks.filter { $0.status == .doing }.count), "
                     + "к выполнению \(tasks.filter { $0.status == .todo }.count), готово \(done) (\(percent)%)")
        if !archive.isEmpty { lines += ["", "В архиве: \(archive.count)"] }
        let high = tasks.filter { $0.status != .done && $0.priority == .high }.count
        if high > 0 { lines += ["", "Высокий приоритет в открытых: \(high)"] }

        for status in [TaskStatus.doing, .todo, .done] {
            let group = sorted(tasks.filter { $0.status == status }, newestCompletedFirst: status == .done)
            guard !group.isEmpty else { continue }
            lines += ["", "## \(status.title) (\(group.count))", ""]
            for t in group { lines.append(line(t)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func line(_ t: TaskItem) -> String {
        var meta = [t.priority.title.lowercased()]
        if !t.size.isEmpty { meta.append("размер \(escape(t.size))") }
        if !t.milestone.isEmpty { meta.append("веха \(escape(t.milestone))") }
        if t.status == .done, !t.completed.isEmpty { meta.append("завершена \(escape(t.completed))") }
        let box = t.status == .done ? "[x]" : "[ ]"
        return "- \(box) \(escape(t.title)) — \(meta.joined(separator: ", "))"
    }
}
