import CryptoKit
import Foundation

/// What the app remembers about event rules: addresses, the person's permission, seen requests, counters, journal.
/// Lives in Application Support; never holds a body, a secret or a signature.
public struct EventState: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Identifiable, Sendable {
        public enum Outcome: String, Codable, Sendable { case started, draft, created, queued, failed }
        public var id = UUID()
        public var at: Date
        /// `started` left in the file: the app stopped before the task was made.
        public var outcome = Outcome.started
        public var note = ""
        public var task: String?
        public init(at: Date) { self.at = at }
    }

    public struct Entry: Codable, Equatable, Sendable {
        /// Random part of the address; also the name of the secret.
        public var id: String
        public var allowed: String?
        /// webhook: nonce → signed time.
        public var nonces: [String: Int] = [:]
        /// Forgotten nonces are not newer than this: such a time is refused whatever the clock says.
        public var floor = 0
        /// github: hashes of signed bodies. Their time is not signed, so they are never forgotten.
        public var hashes: Set<String> = []
        /// Accepted during the last hour.
        public var hits: [Date] = []
        /// git: branch → commit as last seen; nil = not observed while switched on.
        public var refs: [String: String]?
        public var branches: [String] = []
        /// Newest last.
        public var history: [Record] = []
    }

    public enum Replay: Equatable, Sendable {
        case nonce(EventSignature.Stamp)
        case body(String)
        /// git: the refs to remember.
        case refs([String: String])
    }

    public enum Verdict: Equatable, Sendable { case ok(UUID), replay, limit, full }

    public static let version = 1
    public static let historyLimit = 50
    public static let globalLimit = 60
    public static let maxHashes = 10_000
    static let hour: TimeInterval = 3600

    public var version = EventState.version
    /// By path of the rule file.
    public var entries: [String: Entry] = [:]
    public init() {}

    /// Gives every rule an address; a rule that is off or watches other branches forgets its refs.
    public mutating func observe(_ rules: [EventRule], project: URL) {
        for r in rules {
            var e = entries[r.id] ?? Entry(id: EventSignature.random(bytes: 16))
            if !r.isActive || r.kind != .git || e.branches != r.branches { e.refs = nil }
            e.branches = r.branches
            entries[r.id] = e
        }
        let here = Set(rules.map(\.id)), prefix = Automation.key(Automation.dir(in: project)) + "/"
        for k in entries.keys where k.hasPrefix(prefix) && !here.contains(k) { entries[k]?.refs = nil }
    }

    /// Replay, then rate; an accepted event is remembered at once, before its task exists.
    public mutating func accept(_ r: EventRule, _ replay: Replay, now: Date) -> Verdict {
        guard var e = entries[r.id] else { return .full }
        switch replay {
        case .nonce(let s):
            if e.nonces[s.nonce] != nil || s.time <= e.floor { return .replay }
        case .body(let h):
            if e.hashes.contains(h) { return .replay }
            if e.hashes.count >= Self.maxHashes { return .full }
        case .refs: break
        }
        // A hit «from the future» (the clock went back) still counts, but not longer than an hour from now.
        for k in entries.keys {
            let hits = (entries[k]?.hits ?? []).map { min($0, now) }.filter { now.timeIntervalSince($0) < Self.hour }
            entries[k]?.hits = hits
        }
        e.hits = entries[r.id]?.hits ?? []
        guard e.hits.count < r.limit, entries.values.reduce(0, { $0 + $1.hits.count }) < Self.globalLimit else { return .limit }
        switch replay {
        case .nonce(let s):
            e.nonces[s.nonce] = s.time
            let old = Int(now.timeIntervalSince1970) - 4 * EventSignature.window
            for (n, t) in e.nonces where t < old {
                e.nonces[n] = nil
                e.floor = max(e.floor, t)
            }
        case .body(let h): e.hashes.insert(h)
        case .refs(let refs): e.refs = refs
        }
        e.hits.append(now)
        let rec = Record(at: now)
        e.history = Array((e.history + [rec]).suffix(Self.historyLimit))
        entries[r.id] = e
        return .ok(rec.id)
    }

    public mutating func finish(_ id: String, _ rec: UUID, _ outcome: Record.Outcome, note: String, task: String?) {
        guard let i = entries[id]?.history.firstIndex(where: { $0.id == rec }) else { return }
        entries[id]?.history[i].outcome = outcome
        entries[id]?.history[i].note = note
        entries[id]?.history[i].task = task
    }

    /// Nothing signed with the old secret is accepted any more.
    public mutating func secretChanged(_ id: String) {
        entries[id]?.nonces = [:]
        entries[id]?.floor = 0
        entries[id]?.hashes = []
    }

    public func mayQueue(_ r: EventRule) -> Bool {
        r.queue && r.errors.isEmpty && entries[r.id]?.allowed == r.fingerprint
    }

    public mutating func allow(_ r: EventRule, _ on: Bool) { entries[r.id]?.allowed = on ? r.fingerprint : nil }

    /// For `source:` of the task: names the rule without giving its address away.
    public func source(_ r: EventRule) -> String {
        "event:" + EventSignature.hex(SHA256.hash(data: Data((entries[r.id]?.id ?? r.id).utf8)).prefix(6))
    }

    // MARK: File

    private struct Versioned: Decodable { var version: Int }

    /// `problem`: nothing is accepted, what was seen is unknown.
    public static func load(_ url: URL) -> (state: EventState, problem: String?) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: url), let v = try? dec.decode(Versioned.self, from: data), v.version != version {
            return (EventState(), "Файл \(url.lastPathComponent) создан другой версией приложения: события не принимаются.")
        }
        switch SafeJSON.load(EventState.self, from: url, decoder: dec) {
        case .missing: return (EventState(), nil)
        case .value(let v): return (v, nil)
        case .corrupt, .unreadable:
            return (EventState(), "Файл \(url.lastPathComponent) не прочитан: события не принимаются до перезапуска приложения.")
        }
    }

    public func save(_ url: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.sortedKeys]
        try SafeJSON.save(try enc.encode(self), to: url)
    }
}
