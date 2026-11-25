import Foundation

/// Questions an agent leaves for the user in the «## Вопросы» section of a task file.
///
/// Strict format: a question is a top-level list item (`1.` or `- `), options are nested items
/// (the recommended one ends with «(рекомендую)»), the answer is an indented `Ответ: …` line inside the question.
/// Free form is read too: no nested items — a question without options; a section without items — one question.
/// Fenced code blocks are skipped. Writing finds a question by its text, not by number.
public enum AgentQuestions {
    public static let heading = "Вопросы"
    /// Answer written by «Решай сам».
    public static let decideYourself = "реши сам"
    static let recommendedMark = "(рекомендую)"

    public struct Option: Hashable, Sendable {
        public var text: String
        public var recommended: Bool

        public init(text: String, recommended: Bool) {
            self.text = text
            self.recommended = recommended
        }
    }

    public struct Question: Hashable, Sendable {
        public var text: String
        public var options: [Option]
        /// Non-empty text after `Ответ:`; nil while the question is open.
        public var answer: String?
        /// The rest of the question's lines: not its first line, options or answer. Markdown.
        public var details = ""
        public var isOpen: Bool { answer == nil }

        // Positions in the file (line indexes), used by `apply`.
        var line: Int
        var answerLine: Int?
        var lastLine: Int
        var insertIndent: String
    }

    public enum WriteError: Error, Equatable, CustomStringConvertible {
        case questionGone(String)
        case emptyAnswer(String)

        public var description: String {
            switch self {
            case .questionGone(let q): return "Вопроса «\(q)» уже нет в файле задачи — агент мог его изменить"
            case .emptyAnswer(let q): return "Пустой ответ на вопрос «\(q)»"
            }
        }
    }

    // MARK: - Parsing

    /// All questions of the section, answered or not. No section — empty.
    public static func parse(_ text: String) -> [Question] {
        let lines = text.components(separatedBy: "\n")
        guard let range = sectionRange(lines) else { return [] }
        return questions(in: lines, range: range)
    }

    /// Text of the section before its first question.
    public static func preamble(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let range = sectionRange(lines), let first = questions(in: lines, range: range).first else { return "" }
        return joined(lines, range.lowerBound..<first.line)
    }

    /// The section with its heading, when there are questions in it.
    static func shownSection(_ lines: [String]) -> Range<Int>? {
        guard let range = sectionRange(lines), !questions(in: lines, range: range).isEmpty else { return nil }
        return range.lowerBound - 1..<range.upperBound
    }

    /// Lines without their common indent.
    private static func joined(_ lines: [String], _ idx: some Sequence<Int>) -> String {
        let l = idx.map { lines[$0] }
        let indent = l.filter { !trimmed($0).isEmpty }.map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
        return trimmed(l.map { String($0.dropFirst(indent)) }.joined(separator: "\n"))
    }

    /// Questions without an answer. A finished task has none.
    public static func open(in text: String, done: Bool = false) -> [Question] {
        done ? [] : parse(text).filter(\.isOpen)
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func isFence(_ line: String) -> Bool {
        let t = trimmed(line)
        return t.hasPrefix("```") || t.hasPrefix("~~~")
    }

    /// Lines after the heading up to the next heading of level 1–2 (outside code blocks).
    private static func sectionRange(_ lines: [String]) -> Range<Int>? {
        let lines = Evidence.masked(lines)
        var inCode = false
        var start: Int?
        for (i, raw) in lines.enumerated() {
            if isFence(raw) { inCode.toggle(); continue }
            if inCode { continue }
            let t = trimmed(raw)
            guard t.hasPrefix("#") else { continue }
            let level = t.prefix(while: { $0 == "#" }).count
            guard level <= 6, t.dropFirst(level).first == " " || t.count == level else { continue }
            let title = trimmed(String(t.dropFirst(level)))
            if let s = start {
                if level <= 2 { return s..<i }
            } else if level == 2, title.lowercased() == heading.lowercased() {
                start = i + 1
            }
        }
        return start.map { $0..<lines.count }
    }

    private struct Item {
        var line: Int
        var indent: Int
        var indentStr: String
        var markerWidth: Int
        var text: String
    }

    private static func item(_ raw: String, at index: Int) -> Item? {
        let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
        let rest = raw.dropFirst(indent)
        var i = rest.startIndex
        if let c = rest.first, "-*+".contains(c) {
            i = rest.index(after: i)
        } else {
            let digits = rest.prefix(while: \.isNumber)
            guard !digits.isEmpty else { return nil }
            i = rest.index(i, offsetBy: digits.count)
            guard i < rest.endIndex, rest[i] == "." || rest[i] == ")" else { return nil }
            i = rest.index(after: i)
        }
        guard i < rest.endIndex, rest[i] == " " || rest[i] == "\t" else { return nil }
        let body = rest[i...]
        let spaces = body.prefix(while: { $0 == " " || $0 == "\t" }).count
        let width = rest.distance(from: rest.startIndex, to: i) + spaces
        return Item(line: index, indent: indent, indentStr: String(raw.prefix(indent)), markerWidth: width, text: trimmed(String(body)))
    }

    /// Text after «Ответ:» (case-insensitive) if the line is an answer line, else nil.
    private static func answerText(_ s: String) -> String? {
        let t = trimmed(s)
        guard t.count >= 6, t.prefix(6).lowercased() == "ответ:" else { return nil }
        return trimmed(String(t.dropFirst(6)))
    }

    private static func questions(in lines: [String], range: Range<Int>) -> [Question] {
        // Collect lines outside code blocks.
        var live: [Int] = []
        var inCode = false
        for i in range {
            if isFence(lines[i]) { inCode.toggle(); continue }
            if !inCode { live.append(i) }
        }

        let items = live.compactMap { item(lines[$0], at: $0) }
        let itemLines = Set(items.map(\.line))
        // An answer written as «- Ответ: …» is not a question.
        let structural = items.filter { answerText($0.text) == nil }
        guard let topIndent = structural.map(\.indent).min() else {
            return freeForm(lines, range: range, live: live)
        }

        var result: [Question] = []
        var current: Question?
        var own = Set<Int>()

        func flush() { if let q = current { result.append(q); current = nil } }

        for i in live {
            let raw = lines[i]
            if trimmed(raw).isEmpty { continue }
            if itemLines.contains(i), let it = item(raw, at: i) {
                if let ans = answerText(it.text) {
                    guard current != nil else { continue }
                    own.insert(i)
                    record(ans, line: i, in: &current)
                } else if it.indent <= topIndent {
                    flush()
                    current = Question(text: it.text, options: [], answer: nil, line: i, answerLine: nil, lastLine: i,
                                       insertIndent: it.indentStr + String(repeating: " ", count: it.markerWidth))
                } else if current != nil {
                    own.insert(i)
                    var o = it.text
                    var rec = false
                    if let r = o.range(of: recommendedMark, options: .caseInsensitive) {
                        rec = true
                        o.removeSubrange(r)
                        o = normalized(o)
                    }
                    current!.options.append(Option(text: o, recommended: rec))
                    current!.lastLine = i
                    current!.insertIndent = it.indentStr
                }
            } else if current != nil {
                if let ans = answerText(raw) {
                    own.insert(i)
                    record(ans, line: i, in: &current)
                } else {
                    current!.lastLine = i
                }
            }
        }
        flush()
        for k in result.indices {
            let end = k + 1 < result.count ? result[k + 1].line : range.upperBound
            result[k].details = joined(lines, (result[k].line + 1..<end).filter { !own.contains($0) })
        }
        return result
    }

    private static func record(_ ans: String, line: Int, in q: inout Question?) {
        q!.answerLine = line
        q!.answer = ans.isEmpty ? nil : ans
        q!.lastLine = max(q!.lastLine, line)
    }

    /// Section without list items: the whole text is one question.
    private static func freeForm(_ lines: [String], range: Range<Int>, live: [Int]) -> [Question] {
        var parts: [String] = []
        var answer: String?
        var answerLine: Int?
        var last = -1
        for i in live {
            let t = trimmed(lines[i])
            if t.isEmpty { continue }
            last = i
            if let a = answerText(t) {
                answerLine = i
                answer = a.isEmpty ? nil : a
            } else {
                parts.append(t)
            }
        }
        guard let first = live.first(where: { !trimmed(lines[$0]).isEmpty }), !parts.isEmpty else { return [] }
        var q = Question(text: parts.joined(separator: " "), options: [], answer: answer, line: first,
                         answerLine: answerLine, lastLine: last, insertIndent: "")
        // Only the code is not in the text.
        let code = Set(range).subtracting(live)
        q.details = joined(lines, code.filter { $0 > first }.sorted())
        return [q]
    }

    // MARK: - Writing

    private static func normalized(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func sameQuestion(_ a: String, _ b: String) -> Bool { normalized(a) == normalized(b) }

    /// One line: newlines and runs of whitespace become single spaces.
    static func oneLine(_ s: String) -> String { normalized(s) }

    /// Writes answers (question text → answer) into the task text. Only answer lines change:
    /// an existing `Ответ:` is replaced, otherwise a new line goes after the question.
    /// Nothing is written if any question is missing.
    public static func apply(_ answers: [(question: String, answer: String)], to text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard let range = sectionRange(lines) else {
            if let first = answers.first { throw WriteError.questionGone(first.question) }
            return text
        }
        let parsed = questions(in: lines, range: range)
        var used = Set<Int>()
        var edits: [(q: Question, answer: String)] = []
        for a in answers {
            let want = normalized(a.question)
            guard let idx = parsed.indices.first(where: { !used.contains($0) && normalized(parsed[$0].text) == want }) else {
                throw WriteError.questionGone(a.question)
            }
            let one = oneLine(a.answer)
            guard !one.isEmpty else { throw WriteError.emptyAnswer(a.question) }
            used.insert(idx)
            edits.append((parsed[idx], one))
        }

        // Bottom to top so earlier line numbers stay valid.
        for e in edits.sorted(by: { ($0.q.answerLine ?? $0.q.lastLine) > ($1.q.answerLine ?? $1.q.lastLine) }) {
            if let al = e.q.answerLine {
                let raw = lines[al]
                let cr = raw.hasSuffix("\r") ? "\r" : ""
                let head = raw.range(of: "ответ:", options: .caseInsensitive).map { String(raw[..<$0.upperBound]) } ?? ""

                lines[al] = head + " " + e.answer + cr
            } else {
                let cr = lines[e.q.lastLine].hasSuffix("\r") ? "\r" : ""
                lines.insert(e.q.insertIndent + "Ответ: " + e.answer + cr, at: e.q.lastLine + 1)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Text sent to the agent after the user answers.
    public static func replyText(_ answers: [(question: String, answer: String)], ending: String = "Продолжай задачу с учётом ответов.") -> String {
        var s = "Ответы пользователя на твои вопросы (они же записаны в «## \(heading)» файла задачи):\n"
        for (i, a) in answers.enumerated() {
            let ans = oneLine(a.answer)
            let shown = ans.lowercased() == decideYourself
                ? "реши сам — выбери разумный вариант и запиши решение в «## Заметки»"
                : ans
            s += "\(i + 1). \(oneLine(a.question)) — \(shown)\n"
        }
        s += ending
        return s
    }
}
