import Foundation

/// Строки экрана diff: единый вид (одна колонка) или раздельный (было / стало).
public enum DiffRow: Equatable, Sendable {
    case hunk(String)
    case line(DiffLine)
    case pair(left: DiffLine?, right: DiffLine?)
}

public struct DiffTable: Sendable {
    public var rows: [DiffRow] = []
    /// Ширина самой длинной строки в знакоместах моноширинного шрифта.
    public var columns = 0
    public var maxLineNumber = 0
    public init() {}
}

public enum DiffRows {
    /// Более длинные строки (минифицированный код) при показе обрезаются.
    public static let maxText = 2_000
    public static let tab = 4

    public static func unified(_ f: DiffFile) -> DiffTable {
        build(f) { h in h.lines.map { .line(shown($0)) } }
    }

    public static func split(_ f: DiffFile) -> DiffTable {
        build(f) { h in
            var rows: [DiffRow] = []
            var left: [DiffLine] = [], right: [DiffLine] = []
            func flush() {
                for i in 0..<max(left.count, right.count) {
                    rows.append(.pair(left: i < left.count ? left[i] : nil, right: i < right.count ? right[i] : nil))
                }
                left = []; right = []
            }
            var last = DiffLine.Kind.context
            for raw in h.lines {
                let l = shown(raw)
                switch l.kind {
                case .context:
                    flush()
                    rows.append(.pair(left: l, right: l))
                case .removed:
                    // Удаление после добавления — уже следующая правка.
                    if last == .added { flush() }
                    left.append(l)
                case .added:
                    right.append(l)
                case .noNewline: // относится к стороне предыдущей строки
                    switch last {
                    case .removed: left.append(l)
                    case .added: right.append(l)
                    default: rows.append(.pair(left: l, right: l))
                    }
                    continue
                }
                last = l.kind
            }
            flush()
            return rows
        }
    }

    private static func build(_ f: DiffFile, _ body: (DiffHunk) -> [DiffRow]) -> DiffTable {
        var t = DiffTable()
        for h in f.hunks {
            let title = "@@ -\(h.oldStart),\(h.oldCount) +\(h.newStart),\(h.newCount) @@"
            t.rows.append(.hunk(h.section.isEmpty ? title : title + " " + h.section))
            for r in body(h) {
                t.rows.append(r)
                switch r {
                case .line(let l): measure(l, &t)
                case .pair(let a, let b):
                    if let a { measure(a, &t) }
                    if let b { measure(b, &t) }
                case .hunk: break
                }
            }
        }
        return t
    }

    private static func measure(_ l: DiffLine, _ t: inout DiffTable) {
        t.columns = max(t.columns, width(l.text))
        t.maxLineNumber = max(t.maxLineNumber, l.oldNumber ?? 0, l.newNumber ?? 0)
    }

    private static func shown(_ l: DiffLine) -> DiffLine {
        var l = l
        if l.text.utf8.last == 0x0D { l.text = String(Substring(l.text.utf8.dropLast())) }
        if l.text.utf8.count > maxText, l.text.count > maxText { l.text = l.text.prefix(maxText) + "…" }
        return l
    }

    static func width(_ s: String) -> Int {
        var w = 0
        for u in s.unicodeScalars {
            if u == "\t" { w += tab - w % tab } else { w += u.value >= 0x1100 ? 2 : 1 }
        }
        return w
    }
}

extension DiffTable {
    /// Number of the hunk all these rows are in; nil = several hunks or none.
    public func hunk(of picked: IndexSet) -> Int? {
        guard let a = picked.first, let b = picked.last, rows.indices.contains(b) else { return nil }
        func number(_ r: Int) -> Int { rows[...r].count { if case .hunk = $0 { true } else { false } } - 1 }
        let n = number(a)
        return n >= 0 && n == number(b) ? n : nil
    }
}
