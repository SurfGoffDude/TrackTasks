import Foundation

/// Block-level Markdown: headings, paragraphs, lists, task lists, tables, code fences, quotes, rules.
/// Inline formatting (bold, italics, `code`, links) goes through AttributedString.
public enum MDBlock: Hashable, Sendable {
    case heading(Int, String)
    case paragraph(String)
    case bullet(indent: Int, String)
    case ordered(indent: Int, String, String)
    case task(indent: Int, Bool, String)
    case code(String)
    case quote(String)
    case table([String], [[String]])
    case rule
}

public enum MD {
    private final class Blocks {
        let value: [MDBlock]
        init(_ value: [MDBlock]) { self.value = value }
    }

    private static let parseCache: NSCache<NSString, Blocks> = {
        let c = NSCache<NSString, Blocks>()
        c.countLimit = 300
        return c
    }()

    /// `parse` memoized by text — views rebuild MarkdownView on every parent render.
    public static func cachedParse(_ text: String, hideH1: Bool = false) -> [MDBlock] {
        let key = ((hideH1 ? "1" : "0") + text) as NSString
        if let hit = parseCache.object(forKey: key) { return hit.value }
        let blocks = parse(text, hideH1: hideH1)
        parseCache.setObject(Blocks(blocks), forKey: key)
        return blocks
    }

    public static func parse(_ text: String, hideH1: Bool = false) -> [MDBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [MDBlock] = []
        var para: [String] = []
        var i = 0

        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count / 2

            // Code fence
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                let fence = String(line.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                out.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }

            // Table: header row + separator row
            if line.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix("|") else { break }
                    rows.append(cells(l)); i += 1
                }
                out.append(.table(header, rows))
                continue
            }

            if line.isEmpty { flush(); i += 1; continue }

            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let rest = line.dropFirst(level)
                if level <= 6, rest.first == " " {
                    flush()
                    if !(hideH1 && level == 1) {
                        out.append(.heading(level, rest.trimmingCharacters(in: .whitespaces)))
                    }
                    i += 1; continue
                }
            }

            if line == "---" || line == "***" || line == "___" {
                flush(); out.append(.rule); i += 1; continue
            }

            if line.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    q.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                out.append(.quote(q.joined(separator: "\n")))
                continue
            }

            let lower = line.lowercased()
            if lower.hasPrefix("- [ ] ") || lower.hasPrefix("- [x] ") || lower.hasPrefix("* [ ] ") || lower.hasPrefix("* [x] ") {
                flush()
                out.append(.task(indent: indent, lower.dropFirst(3).hasPrefix("x"), String(line.dropFirst(6))))
                i += 1; continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                out.append(.bullet(indent: indent, String(line.dropFirst(2))))
                i += 1; continue
            }
            if let dot = orderedMarker(line) {
                flush()
                out.append(.ordered(indent: indent, String(line[..<dot]),
                                    line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }

            para.append(line)
            i += 1
        }
        flush()
        return out
    }

    /// "12. text" / "3) text" → index of the marker char.
    private static func orderedMarker(_ line: String) -> String.Index? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let idx = line.index(line.startIndex, offsetBy: digits.count)
        guard idx < line.endIndex, line[idx] == "." || line[idx] == ")" else { return nil }
        let after = line.index(after: idx)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return idx
    }

    private static func isTableSeparator(_ raw: String) -> Bool {
        let l = raw.trimmingCharacters(in: .whitespaces)
        guard l.contains("-"), l.contains("|") || l.hasPrefix(":") || l.hasPrefix("-") else { return false }
        return l.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var l = line.replacingOccurrences(of: "\\|", with: "\u{1}")
        if l.hasPrefix("|") { l.removeFirst() }
        if l.hasSuffix("|") { l.removeLast() }
        return l.components(separatedBy: "|").map {
            $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces)
        }
    }

    /// `t` — trimmed line.
    static func isCheckbox(_ t: String) -> Bool {
        let low = t.prefix(6).lowercased()
        return low == "- [ ] " || low == "- [x] " || low == "* [ ] " || low == "* [x] "
    }

    /// Line numbers of checkbox items ("- [ ] …"), skipping code fences and evidence.
    public static func taskLines(_ lines: [String]) -> [Int] {
        let lines = Evidence.masked(lines)
        var fence: String?
        var out: [Int] = []
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if let f = fence { if t.hasPrefix(f) { fence = nil }; continue }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = String(t.prefix(3)); continue }
            if isCheckbox(t) { out.append(i) }
        }
        return out
    }

    /// Flip the n-th task checkbox ("- [ ]" ↔ "- [x]").
    public static func toggleTask(_ text: String, _ n: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        let idx = taskLines(lines)
        guard idx.indices.contains(n) else { return text }
        let i = idx[n]
        guard let r = lines[i].range(of: "[ ]") ?? lines[i].range(of: "[x]") ?? lines[i].range(of: "[X]") else { return text }
        lines[i].replaceSubrange(r, with: lines[i][r] == "[ ]" ? "[x]" : "[ ]")
        return lines.joined(separator: "\n")
    }

    public static func removeTask(_ text: String, _ n: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        let idx = taskLines(lines)
        guard idx.indices.contains(n) else { return text }
        // With its evidence.
        let own = Evidence.blocks(lines).filter { $0.item == idx[n] }.flatMap { Array($0.lines) }
        for i in (own + [idx[n]]).sorted(by: >) { lines.remove(at: i) }
        return lines.joined(separator: "\n")
    }

    // MARK: Task sections

    /// Named sections of a task body (by heading). Everything else is description / plain checklist.
    public enum Section: String, CaseIterable, Sendable {
        case criteria = "Критерии готовности"
        case notes = "Заметки"
        /// The agent's plan before coding (`plan: true`). Its numbered items are text, not task steps.
        case plan = "План"
        /// People's comments ("- 24.11.2026 14:30 — Автор: текст"). Checkboxes inside are text, not steps.
        case comments = "Комментарии"

        public func matches(_ heading: String) -> Bool {
            let h = heading.lowercased()
            switch self {
            case .criteria: return h.hasPrefix("критерии") || h.hasPrefix("definition of done") || h == "dod"
            case .notes: return h.hasPrefix("заметки") || h.hasPrefix("журнал")
            case .plan: return h == "план"
            case .comments: return h == "комментарии"
            }
        }
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        let level = t.prefix(while: { $0 == "#" }).count
        guard level > 0, level <= 6, t.dropFirst(level).first == " " else { return nil }
        return (level, t.dropFirst(level).trimmingCharacters(in: .whitespaces))
    }

    /// Lines [heading, end) of a named section, or nil.
    public static func sectionRange(_ lines: [String], _ s: Section) -> Range<Int>? {
        let lines = Evidence.masked(lines)
        var fence: String?
        var start: Int?, level = 0
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if let f = fence { if t.hasPrefix(f) { fence = nil }; continue }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = String(t.prefix(3)); continue }
            guard let h = heading(t) else { continue }
            if let st = start, h.level <= level { return st..<i }
            if start == nil, s.matches(h.text) { start = i; level = h.level }
        }
        return start.map { $0..<lines.count }
    }

    /// Section a line index belongs to.
    private static func section(of line: Int, _ lines: [String]) -> Section? {
        Section.allCases.first { sectionRange(lines, $0)?.contains(line) == true }
    }

    public struct CheckItem: Equatable, Sendable {
        public let n: Int
        public let done: Bool
        public let text: String
        /// The agent's words (criteria only), "" when there are none.
        public var evidence = ""
    }

    /// Checkboxes, global ordinal `n`, filtered by section (nil = outside named sections).
    public static func checklist(_ text: String, in s: Section? = nil) -> [CheckItem] {
        let lines = text.components(separatedBy: "\n")
        let ranges = Section.allCases.map { ($0, sectionRange(lines, $0)) }
        let evidence = s == .criteria ? Dictionary(grouping: Evidence.blocks(lines), by: \.item) : [:]
        return taskLines(lines).enumerated().compactMap { n, i in
            guard ranges.first(where: { $0.1?.contains(i) == true })?.0 == s else { return nil }
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            return CheckItem(n: n, done: t.lowercased().hasPrefix("- [x]") || t.lowercased().hasPrefix("* [x]"),
                             text: String(t.dropFirst(6)),
                             evidence: (evidence[i] ?? []).map(\.value).filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }

    /// Adds "- [ ] item" after the last checkbox of that part (plain list or a named section).
    public static func appendTask(_ text: String, _ item: String, in s: Section? = nil) -> String {
        let clean = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return text }
        let lines = text.components(separatedBy: "\n")
        // Not between a criterion and its evidence.
        let items = Set(taskLines(lines) + Evidence.blocks(lines).flatMap { Array($0.lines) })
        return insertLine(text, "- [ ] \(clean)", in: s, after: { line, _ in items.contains(line) })
    }

    /// Adds "- 16.11 14:30 — note" to the «Заметки» section (created at the end if missing).
    public static func appendNote(_ text: String, _ note: String, date: Date = Date()) -> String {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !clean.isEmpty else { return text }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM HH:mm"
        return insertLine(text, "- \(f.string(from: date)) — \(clean)", in: .notes,
                          after: { line, lines in lines[line].trimmingCharacters(in: .whitespaces).hasPrefix("- ") })
    }

    private static func insertLine(_ text: String, _ new: String, in s: Section?,
                                   after isItem: (Int, [String]) -> Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        if let s {
            if let r = sectionRange(lines, s) {
                let last = r.dropFirst().last { isItem($0, lines) } ?? r.lowerBound
                lines.insert(new, at: last + 1)
                return lines.joined(separator: "\n")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? "" : trimmed + "\n\n") + "## \(s.rawValue)\n\n" + new
        }
        if let last = lines.indices.last(where: { isItem($0, lines) && section(of: $0, lines) == nil }) {
            let indent = String(lines[last].prefix(while: { $0 == " " || $0 == "\t" }))
            lines.insert(indent + new, at: last + 1)
            return lines.joined(separator: "\n")
        }
        // Before the first named section, so it stays part of the plain checklist.
        let firstSection = Section.allCases.compactMap { sectionRange(lines, $0)?.lowerBound }.min()
        if let at = firstSection {
            lines.insert(contentsOf: [new, ""], at: at)
            return lines.joined(separator: "\n")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? new : trimmed + "\n\n" + new
    }

    /// Text of «## План» without the heading, or "" when there is none.
    public static func plan(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let r = sectionRange(lines, .plan) else { return "" }
        return lines[r].dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Comments

    public struct Comment: Equatable, Sendable {
        /// "24.11.2026 14:30", or "" when the line has no date.
        public let date: String
        public let author: String
        public let text: String
    }

    private static let commentDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    /// "24.11.2026 14:30 — Автор: текст" → parts. Lines in other shapes keep the whole text.
    static func parseComment(_ line: String) -> Comment {
        var rest = line
        var date = ""
        let parts = rest.components(separatedBy: " — ")
        if parts.count > 1, commentDate.date(from: parts[0]) != nil {
            date = parts[0]
            rest = parts.dropFirst().joined(separator: " — ")
        }
        var author = ""
        // Without a date the line isn't ours (hand-written): keep it whole, "Note: x" has no author.
        if !date.isEmpty, let r = rest.range(of: ": "), !rest[..<r.lowerBound].contains(where: \.isNewline),
           rest[..<r.lowerBound].count <= 40, !rest[..<r.lowerBound].isEmpty {
            author = String(rest[..<r.lowerBound])
            rest = String(rest[r.upperBound...])
        }
        return Comment(date: date, author: author, text: rest)
    }

    /// Comment lines of «Комментарии», in file order. Lines that aren't list items are ignored.
    public static func comments(_ text: String) -> [Comment] {
        let lines = text.components(separatedBy: "\n")
        guard let r = sectionRange(lines, .comments) else { return [] }
        return commentLines(lines, r).map { parseComment(String(lines[$0].trimmingCharacters(in: .whitespaces).dropFirst(2))) }
    }

    /// Indices of `range` outside code fences.
    public static func unfenced(_ lines: [String], _ range: Range<Int>) -> [Int] {
        var fence: String?
        var out: [Int] = []
        for i in range {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if let f = fence { if t.hasPrefix(f) { fence = nil }; continue }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = String(t.prefix(3)); continue }
            out.append(i)
        }
        return out
    }

    private static func commentLines(_ lines: [String], _ r: Range<Int>) -> [Int] {
        // Only top-level items are comments; indented ones are part of the previous comment.
        unfenced(lines, r.lowerBound + 1..<r.upperBound).filter { lines[$0].hasPrefix("- ") || lines[$0].hasPrefix("* ") }
    }

    /// Adds "- 24.11.2026 14:30 — Автор: текст" to «Комментарии» (created at the end if missing).
    public static func appendComment(_ text: String, author: String, _ comment: String, date: Date = Date()) -> String {
        let clean = comment.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !clean.isEmpty else { return text }
        var who = author.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        if who.isEmpty { who = "Пользователь" }  // keeps "Note: x" in the text from reading as an author
        let line = "- \(commentDate.string(from: date)) — \(who): \(clean)"
        return insertLine(text, line, in: .comments, after: { i, lines in
            lines[i].hasPrefix("- ") || lines[i].hasPrefix("* ") || lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t")
        })
    }

    public static func removeComment(_ text: String, _ k: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let r = sectionRange(lines, .comments) else { return text }
        let idx = commentLines(lines, r)
        guard idx.indices.contains(k) else { return text }
        // The comment's continuation lines (indented, or blank inside it) go with it.
        var end = idx[k] + 1
        let limit = idx.indices.contains(k + 1) ? idx[k + 1] : r.upperBound
        while end < limit, lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t") { end += 1 }
        lines.removeSubrange(idx[k]..<end)
        return lines.joined(separator: "\n")
    }

    /// Note lines of «Заметки»: "date — text".
    public static func notes(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let r = sectionRange(lines, .notes) else { return [] }
        return lines[r].dropFirst().compactMap { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") || t.hasPrefix("* ") ? String(t.dropFirst(2)) : (t.isEmpty || heading(t) != nil ? nil : t)
        }
    }

    public static func removeNote(_ text: String, _ k: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let r = sectionRange(lines, .notes) else { return text }
        let idx = r.dropFirst().filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty && heading(lines[$0]) == nil }
        guard idx.indices.contains(k) else { return text }
        lines.remove(at: idx[k])
        return lines.joined(separator: "\n")
    }

    /// Description: body without checkboxes, named sections and the agent's questions (they have a card).
    public static func withoutTasks(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var drop = Set(taskLines(lines))
        for s in Section.allCases { if let r = sectionRange(lines, s) { drop.formUnion(r) } }
        if let r = AgentQuestions.shownSection(lines) { drop.formUnion(r) }
        for i in drop.sorted(by: >) { lines.remove(at: i) }
        // Headings left without content (e.g. "## Чеклист" whose items moved to the checklist) go too.
        var i = lines.count - 1
        while i >= 0 {
            if heading(lines[i]) != nil {
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j == lines.count || heading(lines[j]).map({ $0.level <= heading(lines[i])!.level }) == true {
                    lines.remove(at: i)
                }
            }
            i -= 1
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// URLs and repo-relative file paths mentioned in text (e.g. docs/reports/x.md).
    public static func references(_ text: String) -> [String] {
        var out: [String] = []
        let seps = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`()[]<>,;\"'«»"))
        // Data of an event (`EventTask`) is not a list of files to open.
        let own = text.contains(EventTask.mark)
            ? text.components(separatedBy: "\n").filter { !$0.hasPrefix(EventTask.mark) }.joined(separator: "\n") : text
        for raw in own.components(separatedBy: seps) {
            let w = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
            guard w.count > 3, !out.contains(w) else { continue }
            if w.hasPrefix("http://") || w.hasPrefix("https://") { out.append(w); continue }
            let ext = (w as NSString).pathExtension
            if w.contains("/"), !ext.isEmpty, ext.count <= 5, ext.allSatisfy(\.isLetter), !w.contains("://") { out.append(w) }
        }
        return out
    }

    /// (done, total) checkboxes.
    public static func progress(_ text: String) -> (Int, Int) {
        var done = 0, total = 0
        for b in cachedParse(Evidence.masked(text)) { if case .task(_, let d, _) = b { total += 1; if d { done += 1 } } }
        return (done, total)
    }
}
