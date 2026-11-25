import Foundation

public enum SearchText {
    /// Lowercase words and numbers; «ё» = «е». One-letter and very long tokens (hashes, base64) are dropped.
    public static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var word = String.UnicodeScalarView()
        var n = 0
        func flush() {
            if n >= 2, n <= 40 { out.append(String(word)) }
            word = String.UnicodeScalarView()
            n = 0
        }
        for u in s.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars {
            let v = u.value
            let isWord = v < 128 ? (v >= 97 && v <= 122) || (v >= 48 && v <= 57) : u.properties.isAlphabetic || u.properties.numericType != nil
            if isWord {
                n += 1
                if n <= 41 { word.append(v == 0x451 ? "\u{435}" : u) }
            } else if n > 0 {
                flush()
            }
        }
        flush()
        return out
    }
}

/// In-memory BM25 index over sessions. Every query word must be found, exactly or as a word's beginning
/// (so «сесси» finds «сессии»); newer sessions get a bonus.
public struct SessionIndex: Sendable {
    static let k1 = 1.2, b = 0.75
    static let prefixWeight = 0.5, minPrefix = 3
    /// A session from right now scores up to +50 %; the bonus fades e-fold per 30 days.
    static let freshness = 0.5, freshnessDays = 30.0

    private struct Posting { var slot: Int32; var count: Int32 }
    private struct Slot { var info: ClaudeSessionInfo; var length: Int }

    /// nil = replaced or removed; its postings are skipped until `compact`.
    private var slots: [Slot?] = []
    private var slotByPath: [String: Int] = [:]
    private var postings: [String: [Posting]] = [:]
    private var totalLength = 0
    private var dead = 0

    public init() {}

    public var count: Int { slotByPath.count }

    /// Newest first.
    public var sessions: [ClaudeSessionInfo] {
        slots.compactMap { $0?.info }.sorted { ($0.updated, $0.id) > ($1.updated, $1.id) }
    }

    public mutating func put(_ p: SessionLog.Parsed) {
        remove(path: p.info.path)
        let slot = slots.count
        let length = p.terms.values.reduce(0, +)
        slots.append(Slot(info: p.info, length: length))
        slotByPath[p.info.path] = slot
        totalLength += length
        for (t, c) in p.terms { postings[t, default: []].append(Posting(slot: Int32(slot), count: Int32(clamping: c))) }
    }

    public mutating func remove(path: String) {
        guard let i = slotByPath.removeValue(forKey: path) else { return }
        totalLength -= slots[i]?.length ?? 0
        slots[i] = nil
        dead += 1
        if dead > 64, dead > slotByPath.count { compact() }
    }

    private mutating func compact() {
        var map = [Int32](repeating: -1, count: slots.count)
        var live: [Slot?] = []
        for (i, s) in slots.enumerated() where s != nil {
            map[i] = Int32(live.count)
            live.append(s)
        }
        slots = live
        slotByPath = slotByPath.mapValues { Int(map[$0]) }
        postings = postings.compactMapValues { list in
            let kept = list.compactMap { p in
                map[Int(p.slot)] < 0 ? nil : Posting(slot: map[Int(p.slot)], count: p.count)
            }
            return kept.isEmpty ? nil : kept
        }
        dead = 0
    }

    /// Best first. A query without words returns all sessions, newest first.
    public func search(_ query: String, now: Date = Date()) -> [ClaudeSessionInfo] {
        let words = Array(Set(SearchText.tokens(query)))
        if words.isEmpty {
            return query.contains { !$0.isWhitespace } ? [] : sessions
        }
        guard count > 0 else { return [] }
        let n = Double(count)
        let avg = max(1, Double(totalLength) / n)
        var scores: [Int: Double]?
        for w in words {
            // The word and its continuations count as one term.
            var freq: [Int: Double] = [:]
            func add(_ list: [Posting], _ weight: Double) {
                for p in list where slots[Int(p.slot)] != nil { freq[Int(p.slot), default: 0] += weight * Double(p.count) }
            }
            if let exact = postings[w] { add(exact, 1) }
            if w.count >= Self.minPrefix {
                for (t, list) in postings where t.utf8.count > w.utf8.count && t.utf8.starts(with: w.utf8) {
                    add(list, Self.prefixWeight)
                }
            }
            let df = Double(freq.count)
            let idf = log(1 + (n - df + 0.5) / (df + 0.5))
            var next: [Int: Double] = [:]
            for (i, f) in freq {
                guard let s = slots[i] else { continue }
                if let scores, scores[i] == nil { continue }
                let norm = Self.k1 * (1 - Self.b + Self.b * Double(s.length) / avg)
                next[i] = (scores?[i] ?? 0) + idf * f * (Self.k1 + 1) / (f + norm)
            }
            scores = next
            if next.isEmpty { return [] }
        }
        return (scores ?? [:]).compactMap { i, score -> (ClaudeSessionInfo, Double)? in
            guard let info = slots[i]?.info else { return nil }
            let days = max(0, now.timeIntervalSince(info.updated) / 86400)
            return (info, score * (1 + Self.freshness * exp(-days / Self.freshnessDays)))
        }
        .sorted { ($0.1, $0.0.updated, $0.0.id) > ($1.1, $1.0.updated, $1.0.id) }
        .map(\.0)
    }
}

/// Keeps the index in step with the files: only new and changed files are parsed. Never runs on the main thread
/// and never writes anything: the index lives in memory.
public actor SessionLibrary {
    private struct Signature: Equatable { var size: Int; var modified: Date }

    private let root: URL
    private var index = SessionIndex()
    private var seen: [String: Signature] = [:]
    private var running = false
    private var again = false

    public init(root: URL) { self.root = root }

    public func sessions() -> [ClaudeSessionInfo] { index.sessions }
    public func search(_ query: String) -> [ClaudeSessionInfo] { index.search(query) }

    /// Returns the number of files parsed. A call during another refresh makes that one look at the files again.
    @discardableResult
    public func refresh(progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) async -> Int {
        if running { again = true; return 0 }
        running = true
        defer { running = false }
        var parsed = 0
        repeat {
            again = false
            parsed += await pass(progress)
        } while again && !Task.isCancelled
        return parsed
    }

    private func pass(_ progress: (@Sendable (Int, Int) -> Void)?) async -> Int {
        let root = root
        // nil: the folder can't be read — keep what we have.
        guard let files = await Task.detached(priority: .utility, operation: { Self.scan(root) }).value else { return 0 }
        for path in seen.keys where files[path] == nil {
            seen[path] = nil
            index.remove(path: path)
        }
        // Newest first: what is most likely searched for appears at once.
        let todo = files.filter { seen[$0.key] != $0.value }.sorted { $0.value.modified > $1.value.modified }
        guard !todo.isEmpty else { return 0 }
        let span = Log.store.begin("indexSessions", "\(todo.count) files")
        defer { Log.store.end("indexSessions", span) }
        var done = 0
        await withTaskGroup(of: (String, Signature, Result<SessionLog.Parsed?, Error>).self) { group in
            var rest = todo.makeIterator()
            func startNext() {
                guard !Task.isCancelled, let (path, sig) = rest.next() else { return }
                group.addTask(priority: .utility) {
                    (path, sig, Result { try SessionLog.parse(path: path, modified: sig.modified) })
                }
            }
            for _ in 0..<4 { startNext() }
            while let (path, sig, result) = await group.next() {
                // An unreadable file is not remembered: the next refresh tries again.
                if case .success(let p) = result {
                    seen[path] = sig
                    if let p { index.put(p) } else { index.remove(path: path) }
                }
                done += 1
                progress?(done, todo.count)
                startNext()
            }
        }
        return done
    }

    /// `<root>/<folder>/<id>.jsonl`. Subagent logs lie deeper and can't be resumed, so they are not sessions.
    private static func scan(_ root: URL) -> [String: Signature]? {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var out: [String: Signature] = [:]
        for d in folders {
            guard let files = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: Array(keys)) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                guard let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
                out[f.path] = Signature(size: v.fileSize ?? 0, modified: v.contentModificationDate ?? .distantPast)
            }
        }
        return out
    }
}
