import Foundation

/// One searchable thing: a task, about.md, spectrack.md or a file from docs/.
public struct SearchEntry: Hashable, Sendable {
    public enum Kind: String, Sendable { case task, about, spec, doc }

    public var id: String              // task: file path; others: file path too
    public var kind: Kind
    public var projectID: String
    public var projectName: String
    public var title: String
    public var text: String
    public var status: TaskStatus?
    public var priorityRank = 1

    public init(id: String, kind: Kind, projectID: String, projectName: String, title: String, text: String,
                status: TaskStatus? = nil, priorityRank: Int = 1) {
        self.id = id; self.kind = kind; self.projectID = projectID; self.projectName = projectName
        self.title = title; self.text = text; self.status = status; self.priorityRank = priorityRank
    }
}

public enum SearchEntries {
    /// Text beyond this is not indexed: long logs in docs/ would only add noise.
    static let maxText = 20_000
    static let maxFileBytes = 300_000
    static let maxDocs = 200

    /// Entries of one project; `docs` come from `docs(in:)`.
    public static func make(_ p: Project, docs: [(path: String, text: String)]) -> [SearchEntry] {
        var out: [SearchEntry] = []
        for t in p.tasks + p.archive + p.drafts {
            out.append(SearchEntry(id: t.id, kind: .task, projectID: p.id, projectName: p.displayName, title: t.title,
                                   text: t.body, status: t.status, priorityRank: t.priority == .high ? 0 : t.priority == .medium ? 1 : 2))
        }
        if p.hasAbout {
            out.append(SearchEntry(id: p.aboutURL.path, kind: .about, projectID: p.id, projectName: p.displayName,
                                   title: "about.md", text: ([p.summary] + p.stack + [p.aboutBody]).joined(separator: "\n")))
        }
        if p.hasSpec {
            out.append(SearchEntry(id: p.specURL.path, kind: .spec, projectID: p.id, projectName: p.displayName,
                                   title: p.specName, text: p.spec))
        }
        for d in docs {
            out.append(SearchEntry(id: d.path, kind: .doc, projectID: p.id, projectName: p.displayName,
                                   title: (d.path as NSString).lastPathComponent, text: d.text))
        }
        return out
    }

    /// Markdown and text files under `docs/` (not hidden, not `frozen`, small ones only). Does disk I/O.
    public static func docs(in project: URL) -> [(path: String, text: String)] {
        let fm = FileManager.default
        let root = project.appendingPathComponent("docs", isDirectory: true)
        guard let it = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [(String, String)] = []
        for case let u as URL in it {
            if u.lastPathComponent == "frozen" { it.skipDescendants(); continue }
            guard ["md", "txt", "markdown"].contains(u.pathExtension.lowercased()),
                  let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  v.isRegularFile == true, (v.fileSize ?? 0) <= maxFileBytes,
                  let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            out.append((u.path, String(text.prefix(maxText))))
            if out.count >= maxDocs { break }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

/// Fuzzy full-text index over `SearchEntry`. Every query word must match; a word matches a term exactly,
/// as its beginning, or with one typo (substitution, missing / extra letter, swapped neighbours).
/// Title beats project name beats text; open tasks beat done ones.
public struct QuickSearchIndex: Sendable {
    public struct Hit: Sendable {
        public var entry: SearchEntry
        public var score: Double
    }

    private struct Posting { var doc: Int32; var field: UInt8; var count: Int32 }
    private struct Term { var chars: [UInt32]; var postings: [Posting] = [] }

    static let fieldWeight: [Double] = [1, 2.5, 5]   // text, project name, title
    static let minTypoLength = 4

    /// Entries with `text` dropped: only what the result list shows is kept.
    private var docs: [SearchEntry?] = []
    private var byProject: [String: [Int]] = [:]
    private var terms: [String: Term] = [:]
    private var dead = 0

    public init() {}

    public var count: Int { docs.count - dead }

    /// Replaces everything known about one project.
    public mutating func replace(project: String, with entries: [SearchEntry]) {
        for i in byProject.removeValue(forKey: project) ?? [] where docs[i] != nil {
            docs[i] = nil
            dead += 1
        }
        var slots: [Int] = []
        for e in entries {
            let slot = docs.count
            slots.append(slot)
            var stored = e
            stored.text = ""
            docs.append(stored)
            add(slot, field: 2, text: e.title)
            add(slot, field: 1, text: e.projectName)
            add(slot, field: 0, text: String(e.text.prefix(SearchEntries.maxText)))
        }
        byProject[project] = slots
        if dead > 256, dead > docs.count / 2 { compact() }
    }

    public mutating func removeProject(_ project: String) { replace(project: project, with: []) }

    private mutating func add(_ slot: Int, field: UInt8, text: String) {
        var counts: [String: Int32] = [:]
        for t in SearchText.tokens(text) { counts[t, default: 0] += 1 }
        for (t, c) in counts {
            if terms[t] == nil { terms[t] = Term(chars: t.unicodeScalars.map(\.value)) }
            terms[t]!.postings.append(Posting(doc: Int32(slot), field: field, count: c))
        }
    }

    private mutating func compact() {
        var map = [Int32](repeating: -1, count: docs.count)
        var live: [SearchEntry?] = []
        for (i, d) in docs.enumerated() where d != nil {
            map[i] = Int32(live.count)
            live.append(d)
        }
        docs = live
        byProject = byProject.mapValues { $0.compactMap { map[$0] < 0 ? nil : Int(map[$0]) } }
        for (k, var t) in terms {
            t.postings = t.postings.compactMap { p in
                map[Int(p.doc)] < 0 ? nil : Posting(doc: map[Int(p.doc)], field: p.field, count: p.count)
            }
            terms[k] = t.postings.isEmpty ? nil : t
        }
        dead = 0
    }

    /// True when `a` becomes `b` by one substitution, insertion, deletion or swap of neighbours.
    static func withinOne(_ a: [UInt32], _ b: ArraySlice<UInt32>) -> Bool {
        let n = a.count, m = b.count, bs = b.startIndex
        if abs(n - m) > 1 { return false }
        var i = 0
        while i < n, i < m, a[i] == b[bs + i] { i += 1 }
        if i == n && i == m { return true }
        if n == m {
            if a[(i + 1)...].elementsEqual(b[(bs + i + 1)...]) { return true }
            return i + 1 < n && a[i] == b[bs + i + 1] && a[i + 1] == b[bs + i] && a[(i + 2)...].elementsEqual(b[(bs + i + 2)...])
        }
        if n > m { return a[(i + 1)...].elementsEqual(b[(bs + i)...]) }
        return a[i...].elementsEqual(b[(bs + i + 1)...])
    }

    /// Best score of a query word per document (field weight × match quality × a bit for repeats).
    private func matches(_ word: String) -> [Int32: Double] {
        let q = word.unicodeScalars.map(\.value)
        let L = q.count
        var best: [Int32: Double] = [:]
        func take(_ t: Term, _ quality: Double) {
            for p in t.postings where docs[Int(p.doc)] != nil {
                let s = quality * Self.fieldWeight[Int(p.field)] * (1 + 0.1 * log(Double(p.count)) )
                if s > best[p.doc, default: 0] { best[p.doc] = s }
            }
        }
        if let exact = terms[word] { take(exact, 1) }
        for (key, t) in terms where key != word {
            let n = t.chars.count
            if n > L, t.chars.starts(with: q) {
                take(t, L >= 3 ? 0.7 : 0.4)
            } else if L >= Self.minTypoLength, n >= L - 1 {
                if n <= L + 1, Self.withinOne(q, t.chars[...]) { take(t, 0.55) }
                else if n > L + 1, Self.withinOne(q, t.chars[..<L]) { take(t, 0.35) }
            }
        }
        return best
    }

    /// Best first. No words in the query → nothing.
    public func search(_ query: String, limit: Int = 50) -> [Hit] {
        let words = Array(Set(SearchText.tokens(query)))
        guard !words.isEmpty, count > 0 else { return [] }
        var scores: [Int32: Double]?
        for w in words {
            let m = matches(w)
            if let s = scores {
                var next: [Int32: Double] = [:]
                for (d, v) in m { if let old = s[d] { next[d] = old + v } }
                scores = next
            } else {
                scores = m
            }
            if scores!.isEmpty { return [] }
        }
        let lead = query.lowercased().trimmingCharacters(in: .whitespaces)
        var hits: [Hit] = []
        for (d, s) in scores ?? [:] {
            guard let e = docs[Int(d)] else { continue }
            var score = s
            if e.status == .done { score *= 0.6 }
            if e.kind == .task { score *= 1 + 0.05 * Double(2 - e.priorityRank) }
            if e.title.lowercased().contains(lead) { score *= 1.5 }
            hits.append(Hit(entry: e, score: score))
        }
        hits.sort { ($0.score, $1.entry.id) > ($1.score, $0.entry.id) }
        return Array(hits.prefix(limit))
    }
}

/// Keeps the index off the main thread; the app feeds it per project.
public actor QuickSearchLibrary {
    private var index = QuickSearchIndex()
    public init() {}

    public func replace(project: String, with entries: [SearchEntry]) { index.replace(project: project, with: entries) }
    /// Drops projects that are gone and rebuilds the rest.
    public func reset(_ all: [String: [SearchEntry]]) {
        var fresh = QuickSearchIndex()
        for (p, e) in all { fresh.replace(project: p, with: e) }
        index = fresh
    }
    public func search(_ query: String, limit: Int = 50) -> [QuickSearchIndex.Hit] { index.search(query, limit: limit) }
    public func count() -> Int { index.count }
}
