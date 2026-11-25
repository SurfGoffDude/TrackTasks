import Foundation

/// What the app remembers about schedules: the last run, the person's permission, history.
/// Lives in Application Support; nothing in a project's files can change it.
public struct AutomationState: Codable, Equatable, Sendable {
    public struct Run: Codable, Equatable, Identifiable, Sendable {
        public enum Outcome: String, Codable, Sendable { case started, created, queued, skipped, failed }
        public var id = UUID()
        public var at: Date
        /// Scheduled moment, nil = run by hand.
        public var slot: Date?
        /// `started` left in the file: the app was closed or crashed before the task was made.
        public var outcome = Outcome.started
        public var note = ""
        /// File name of the created task.
        public var task: String?
        public init(at: Date, slot: Date?) { self.at = at; self.slot = slot }
    }

    public struct Entry: Codable, Equatable, Sendable {
        /// Slots up to this moment are done with.
        public var since: Date
        /// Local day of the last scheduled run.
        public var lastDay: String?
        /// Schedule and switch as last seen: a changed or re-enabled one starts from «now».
        public var rule: String
        public var on: Bool
        /// The person allowed queueing for exactly this content.
        public var allowed: String?
        /// Newest last.
        public var history: [Run] = []
    }

    public static let version = 1
    public static let historyLimit = 50
    /// Further in the future than any clock change or time zone can move: the clock was wrong.
    static let clockSlack: TimeInterval = 48 * 3600

    public var version = AutomationState.version
    /// By path of the schedule file.
    public var entries: [String: Entry] = [:]
    public init() {}

    /// Notes what the files of a project look like now.
    public mutating func observe(_ list: [Automation], project: URL, now: Date) {
        for a in list {
            let rule = a.rule?.key ?? ""
            guard var e = entries[a.id] else {
                entries[a.id] = Entry(since: now, rule: rule, on: a.isActive)
                continue
            }
            if e.rule != rule || (a.isActive && !e.on) || e.since > now.addingTimeInterval(Self.clockSlack) {
                e.since = now
                e.lastDay = nil
            }
            e.rule = rule
            e.on = a.isActive
            entries[a.id] = e
        }
        // A file that went away and comes back starts anew.
        let here = Set(list.map(\.id)), prefix = Automation.key(Automation.dir(in: project)) + "/"
        for k in entries.keys where k.hasPrefix(prefix) && !here.contains(k) && entries[k]?.on == true { entries[k]?.on = false }
    }

    /// Moment to run now; nil for a switched off, broken or not yet observed schedule.
    public func due(_ a: Automation, now: Date, calendar: Calendar) -> Date? {
        guard a.isActive, let r = a.rule, let e = entries[a.id], e.on, e.rule == r.key else { return nil }
        return r.due(since: e.since, lastDay: e.lastDay, now: now, calendar: calendar)
    }

    public func next(_ a: Automation, now: Date, calendar: Calendar) -> Date? {
        guard a.isActive, let r = a.rule, let e = entries[a.id], e.on, e.rule == r.key else { return nil }
        return r.next(after: max(now, e.since), lastDay: e.lastDay, calendar: calendar)
    }

    /// Takes a slot (nil = by hand) and opens its history record.
    public mutating func begin(_ a: Automation, slot: Date?, now: Date, calendar: Calendar) -> UUID {
        var e = entries[a.id] ?? Entry(since: now, rule: a.rule?.key ?? "", on: a.isActive)
        if let slot {
            e.since = slot
            e.lastDay = Automation.Rule.dayKey(slot, calendar)
        }
        let run = Run(at: now, slot: slot)
        e.history = Array((e.history + [run]).suffix(Self.historyLimit))
        entries[a.id] = e
        return run.id
    }

    public mutating func finish(_ id: String, _ run: UUID, _ outcome: Run.Outcome, note: String = "", task: String? = nil) {
        guard let i = entries[id]?.history.firstIndex(where: { $0.id == run }) else { return }
        entries[id]?.history[i].outcome = outcome
        entries[id]?.history[i].note = note
        entries[id]?.history[i].task = task
    }

    public func mayQueue(_ a: Automation) -> Bool {
        a.queue && a.errors.isEmpty && entries[a.id]?.allowed == a.fingerprint
    }

    public mutating func allow(_ a: Automation, _ on: Bool, now: Date) {
        if entries[a.id] == nil { entries[a.id] = Entry(since: now, rule: a.rule?.key ?? "", on: a.isActive) }
        entries[a.id]?.allowed = on ? a.fingerprint : nil
    }

    // MARK: File

    private struct Versioned: Decodable { var version: Int }

    /// `problem`: scheduled runs must stand still, the remembered slots are unknown.
    public static func load(_ url: URL) -> (state: AutomationState, problem: String?) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        // A newer file is not a broken one: it is left in place.
        if let data = try? Data(contentsOf: url), let v = try? dec.decode(Versioned.self, from: data), v.version != version {
            return (AutomationState(), "Файл \(url.lastPathComponent) создан другой версией приложения: расписания остановлены.")
        }
        switch SafeJSON.load(AutomationState.self, from: url, decoder: dec) {
        case .missing: return (AutomationState(), nil)
        case .value(let v): return (v, nil)
        case .corrupt, .unreadable:
            return (AutomationState(), "Файл \(url.lastPathComponent) не прочитан: расписания остановлены до перезапуска приложения.")
        }
    }

    public func save(_ url: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.sortedKeys]
        try SafeJSON.save(try enc.encode(self), to: url)
    }
}
