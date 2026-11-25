import Foundation

/// What the agent says confirms a criterion: a nested line "  - Доказательство: …" under it in «Критерии готовности»,
/// possibly continued by deeper lines. Always the agent's words: only `Check` is what the tracker ran itself.
public enum Evidence {
    public static let label = "Доказательство"

    struct Block: Equatable {
        /// Line of the criterion.
        let item: Int
        let lines: Range<Int>
        let value: String
    }

    // MARK: Parsing

    static func blocks(_ lines: [String]) -> [Block] { scan(lines).blocks }

    /// Lines with evidence blanked (same count): a checkbox, heading or unclosed code fence inside is not structure.
    static func masked(_ lines: [String]) -> [String] {
        let s = scan(lines)
        guard !s.hidden.isEmpty else { return lines }
        var out = lines
        for i in s.hidden { out[i] = "" }
        return out
    }

    public static func masked(_ text: String) -> String {
        masked(text.components(separatedBy: "\n")).joined(separator: "\n")
    }

    private static func indent(_ l: String) -> Int {
        var n = 0
        for c in l { if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break } }
        return n
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func opening(_ t: String) -> String? {
        t.hasPrefix("```") || t.hasPrefix("~~~") ? String(t.prefix(3)) : nil
    }

    private static func value(of t: String) -> String? {
        for p in ["- \(label):", "* \(label):", "- \(label.lowercased()):", "* \(label.lowercased()):"] where t.hasPrefix(p) {
            return trim(String(t.dropFirst(p.count)))
        }
        return nil
    }

    private static func scan(_ lines: [String]) -> (blocks: [Block], hidden: [Int]) {
        // Most texts have none.
        guard lines.contains(where: { $0.contains("оказательство:") }) else { return ([], []) }
        var blocks: [Block] = [], hidden: [Int] = []
        var fence: String?
        /// Left open inside a block: its closing line is not the start of another one.
        var pending: String?
        var level = 0  // of the criteria heading; 0 = not there yet
        var items: [(line: Int, indent: Int)] = []
        var i = 0
        while i < lines.count {
            defer { i += 1 }
            let t = trim(lines[i])
            if let f = fence { if t.hasPrefix(f) { fence = nil }; continue }
            if let p = pending, t.hasPrefix(p), t.allSatisfy({ $0 == p.first }) {
                pending = nil
                hidden.append(i)
                continue
            }
            if let f = opening(t) { fence = f; continue }
            let hashes = t.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), t.dropFirst(hashes).first == " " {
                if level > 0, hashes <= level { break }
                if level == 0, MD.Section.criteria.matches(trim(String(t.dropFirst(hashes)))) { level = hashes }
                items = []
                pending = nil
                continue
            }
            guard level > 0, !t.isEmpty else { continue }
            let own = indent(lines[i])
            while let l = items.last, l.indent >= own { items.removeLast() }
            if MD.isCheckbox(t) { items.append((i, own)); continue }
            guard let item = items.last, let first = value(of: t) else { continue }

            var end = i + 1
            while end < lines.count {
                var k = end
                while k < lines.count, trim(lines[k]).isEmpty { k += 1 }
                guard k < lines.count, indent(lines[k]) > own else { break }
                end = k + 1
            }
            var open: String?
            if let f = opening(first), !first.dropFirst(3).contains(f) { open = f }
            for k in i + 1..<max(end, i + 1) {
                let l = trim(lines[k])
                if let f = open { if l.hasPrefix(f) { open = nil } } else { open = opening(l) }
            }
            pending = open
            let text = ([first] + lines[(i + 1)..<end].map(trim)).filter { !$0.isEmpty }.joined(separator: "\n")
            // "…" copied from the example says nothing.
            blocks.append(Block(item: item.line, lines: i..<end, value: text.contains { $0.isLetter || $0.isNumber } ? text : ""))
            hidden += i..<end
            i = end - 1
        }
        return (blocks, hidden)
    }

    // MARK: Writing

    /// Evidence of the n-th checkbox (a criterion); an empty value removes it. Everything else stays as it was.
    public static func set(_ text: String, _ n: Int, _ value: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let idx = MD.taskLines(lines)
        guard idx.indices.contains(n), MD.sectionRange(lines, .criteria)?.contains(idx[n]) == true else { return text }
        let item = idx[n]
        let old = blocks(lines).filter { $0.item == item }
        for b in old.reversed() { lines.removeSubrange(b.lines) }
        let one = value.components(separatedBy: .newlines).map(trim).filter { !$0.isEmpty }.joined(separator: " ")
        guard !one.isEmpty else { return lines.joined(separator: "\n") }
        var at = old.first?.lines.lowerBound ?? item + 1
        if old.isEmpty {
            // After the rest of a wrapped criterion.
            while at < lines.count, indent(lines[at]) > indent(lines[item]), let c = trim(lines[at]).first, !"-*+".contains(c),
                  opening(trim(lines[at])) == nil { at += 1 }
        }
        lines.insert(String(lines[item].prefix { $0 == " " || $0 == "\t" }) + "  - \(label): \(one)", at: at)
        return lines.joined(separator: "\n")
    }

    // MARK: Summary

    /// Ticked criteria without evidence worth pointing out. Tasks made before it was asked for have none.
    public static func missing(_ criteria: [MD.CheckItem], asked: Bool) -> [MD.CheckItem] {
        guard asked || criteria.contains(where: { !$0.evidence.isEmpty }) else { return [] }
        return criteria.filter { $0.done && $0.evidence.isEmpty }
    }

    /// What the tracker's own check (`verify`) says, apart from the agent's words.
    public enum Check: Equatable, Sendable {
        case working
        case notRun(String)
        case passed(String)
        /// Passed in part, or before something newer went red.
        case partial(String)
        case failed(String)

        public static let title = "Проверка трекера"

        public var text: String {
            switch self {
            case .working: "работа ещё идёт"
            case .notRun(let s): s.isEmpty ? "не запускалась" : s
            case .passed(let s), .partial(let s), .failed(let s): s
            }
        }

        /// `note`, `failed` — of the last run; `notRun` — the note says that the task's own check didn't run.
        public static func of(note: String, failed: Bool, active: Bool, notRun: Bool, mergeRed: Bool) -> Check {
            if active { return .working }
            if note.isEmpty { return mergeRed ? .failed("вместе со свежим main не прошла") : .notRun("") }
            if notRun { return .notRun(note) }
            if failed { return .failed(note) }
            guard note.contains(passedMark) else { return .notRun(note) }
            if mergeRed { return .partial("Без свежего main · " + note) }
            return note.hasPrefix(passedMark) ? .passed(note) : .partial(note)
        }
    }

    public static let passedMark = "Проверка прошла: "
}
