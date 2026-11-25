import Foundation

/// Puts a person's edit of a task on top of what is in the file now.
public enum TaskMerge {
    /// Both sides changed the same thing in different ways; the file is left as it is.
    public struct Conflict: Error, Equatable, Sendable {
        /// What clashed, for the person: «название», «текст»…
        public let fields: [String]
        /// The task in the file now.
        public let current: TaskItem
        /// Both edits together, the person's one where they clash.
        public let merged: TaskItem
    }

    /// `base` — the task as the person saw it, `mine` — with their edit, `current` — as it is in the file now.
    /// `completed` is not merged: it follows the status.
    public static func merge(base: TaskItem, mine: TaskItem, current: TaskItem) -> (item: TaskItem, conflicts: [String]) {
        var out = current, conflicts: [String] = []
        func clash(_ name: String) { if !conflicts.contains(name) { conflicts.append(name) } }
        func field<T: Equatable>(_ name: String, _ key: WritableKeyPath<TaskItem, T>, _ norm: (T) -> T = { $0 }) {
            let b = norm(base[keyPath: key]), m = norm(mine[keyPath: key]), c = norm(current[keyPath: key])
            guard m != b, m != c else { return }
            if c != b { clash(name) }
            out[keyPath: key] = m
        }
        func list(_ key: WritableKeyPath<TaskItem, [String]>) {
            let b = base[keyPath: key], m = mine[keyPath: key], c = current[keyPath: key]
            guard m != b, m != c else { return }
            if c == b { out[keyPath: key] = m; return }
            var l = c.filter { m.contains($0) || !b.contains($0) }
            for x in m where !b.contains(x) && !l.contains(x) { l.append(x) }
            out[keyPath: key] = l
        }
        field("название", \.title)
        field("статус", \.status)
        field("приоритет", \.priority)
        field("дата создания", \.created)
        field("оценка", \.size)
        field("план", \.plan)
        field("план", \.planOff)
        field("worktree", \.mainFolderOnly)
        field("агент", \.agent)
        field("пайплайн", \.workflow)
        field("источник", \.source)
        field("расписание", \.automation)
        field("веха", \.milestone, Milestone.clean)
        field("родитель", \.parent)
        field("проверка", \.verify)
        list(\.depends)
        list(\.files)
        list(\.repos)
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let text = lines(base: trim(base.body), mine: trim(mine.body), current: trim(current.body)) {
            out.body = text
        } else {
            clash("текст")
            out.body = mine.body
        }
        return (out, conflicts)
    }

    // MARK: Text

    struct Hunk: Equatable {
        var range: Range<Int>
        var new: [String]
    }

    /// Three-way merge by lines; nil — both sides changed the same lines. Lines added at one place by both sides
    /// are kept when those of one side are all list items (notes, checklist).
    static func lines(base: String, mine: String, current: String) -> String? {
        if mine == base || mine == current { return current }
        if current == base { return mine }
        let b = base.components(separatedBy: "\n")
        let theirs = hunks(b, current.components(separatedBy: "\n"))
        let ours = hunks(b, mine.components(separatedBy: "\n")).filter { !theirs.contains($0) }
        var all = theirs
        for o in ours {
            let hits = all.indices.filter { clash(o, all[$0]) }
            if hits.isEmpty { all.append(o); continue }
            guard hits.count == 1, o.range.isEmpty, all[hits[0]].range.isEmpty,
                  let both = union(o.new, all[hits[0]].new) else { return nil }
            all[hits[0]].new = both
        }
        // At one place an insertion goes before a replacement.
        all.sort { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }
        var out: [String] = [], at = 0
        for h in all {
            out += b[at..<h.range.lowerBound]
            out += h.new
            at = h.range.upperBound
        }
        out += b[at...]
        return out.joined(separator: "\n")
    }

    private static func clash(_ a: Hunk, _ b: Hunk) -> Bool {
        switch (a.range.isEmpty, b.range.isEmpty) {
        case (true, true):
            return a.range.lowerBound == b.range.lowerBound
        case (true, false):
            let p = a.range.lowerBound
            if b.range.lowerBound < p, p < b.range.upperBound { return true }
            // Next to a replaced line is fine, next to a deleted or grown block it is not clear where the text belongs.
            return (p == b.range.lowerBound || p == b.range.upperBound) && b.new.count != b.range.count
        case (false, true): return clash(b, a)
        case (false, false): return a.range.overlaps(b.range)
        }
    }

    /// Both insertions at one place, list items before a new section; nil when neither is a plain list.
    private static func union(_ mine: [String], _ theirs: [String]) -> [String]? {
        let common = zip(mine, theirs).prefix { $0.0 == $0.1 }.map(\.0)
        let m = Array(mine.dropFirst(common.count)), t = Array(theirs.dropFirst(common.count))
        if m.allSatisfy(isListItem) { return common + t.prefix(while: isListItem) + m + t.drop(while: isListItem) }
        if t.allSatisfy(isListItem) { return common + m.prefix(while: isListItem) + t + m.drop(while: isListItem) }
        return nil
    }

    private static func isListItem(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("- ") || t.hasPrefix("* ")
    }

    private static func hunks(_ old: [String], _ new: [String]) -> [Hunk] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in new.difference(from: old) {
            switch c {
            case .remove(let i, _, _): removed.insert(i)
            case .insert(let i, _, _): inserted.insert(i)
            }
        }
        var out: [Hunk] = [], i = 0, j = 0
        while i < old.count || j < new.count {
            let i0 = i, j0 = j
            while removed.contains(i) || inserted.contains(j) {
                if removed.contains(i) { i += 1 }
                if inserted.contains(j) { j += 1 }
            }
            if i > i0 || j > j0 { out += split(old, i0..<i, Array(new[j0..<j])) }
            i += 1
            j += 1
        }
        return out
    }

    /// A ticked item is a change of its own line only: neighbours ticked by the other side don't clash with it.
    private static func split(_ old: [String], _ range: Range<Int>, _ new: [String]) -> [Hunk] {
        func same(_ a: String, _ b: String) -> Bool {
            func bare(_ s: String) -> String? {
                for m in ["[ ]", "[x]", "[X]"] { if let r = s.range(of: m) { return s.replacingCharacters(in: r, with: "[]") } }
                return nil
            }
            guard let x = bare(a), let y = bare(b) else { return false }
            return x == y
        }
        var r = range, n = new[...], head: [Hunk] = [], tail: [Hunk] = []
        while let f = n.first, !r.isEmpty, same(old[r.lowerBound], f) {
            head.append(Hunk(range: r.lowerBound..<r.lowerBound + 1, new: [f]))
            r = r.lowerBound + 1..<r.upperBound
            n = n.dropFirst()
        }
        while let l = n.last, !r.isEmpty, same(old[r.upperBound - 1], l) {
            tail.insert(Hunk(range: r.upperBound - 1..<r.upperBound, new: [l]), at: 0)
            r = r.lowerBound..<r.upperBound - 1
            n = n.dropLast()
        }
        // Ticked items inside the block, with lines added between them (evidence).
        for a in r {
            guard let b = n.firstIndex(where: { same(old[a], $0) }) else { continue }
            let gap = Hunk(range: r.lowerBound..<a, new: Array(n[..<b]))
            if !gap.range.isEmpty || !gap.new.isEmpty { head.append(gap) }
            head.append(Hunk(range: a..<a + 1, new: [n[b]]))
            r = a + 1..<r.upperBound
            n = n[(b + 1)...]
        }
        return head + (r.isEmpty && n.isEmpty ? [] : [Hunk(range: r, new: Array(n))]) + tail
    }
}

extension TaskItem {
    /// `completed` as the status demands: a done task has a date, any other has none.
    public mutating func settleCompleted() {
        if status != .done { completed = "" } else if completed.isEmpty { completed = Codec.today() }
    }
}

extension TaskFile {
    /// Saves a person's edit of `base`, the task as they saw it, over whatever the file holds now.
    /// Throws `TaskMerge.Conflict` when the edits clash; nothing is written then.
    @discardableResult
    public static func save(_ mine: TaskItem, base: TaskItem) throws -> TaskItem {
        try edit(mine.url) { f in
            var r = TaskMerge.merge(base: base, mine: mine, current: f.item)
            r.item.settleCompleted()
            if !r.conflicts.isEmpty { throw TaskMerge.Conflict(fields: r.conflicts, current: f.item, merged: r.item) }
            return Codec.serialize(r.item, updating: f.text)
        }
    }

    /// Applies a change that fits any text (a status, a note) to the file as it is now.
    @discardableResult
    public static func change(_ url: URL, _ body: (inout TaskItem) throws -> Void) throws -> TaskItem {
        try edit(url) { f in
            var t = f.item
            try body(&t)
            return Codec.serialize(t, updating: f.text)
        }
    }
}
