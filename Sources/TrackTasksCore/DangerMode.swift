import Foundation

/// «Опасный режим»: the queue of one project runs without questions until merge, for a limited time.
/// The state lives in Application Support; nothing in a project's files (about.md, tasks) can turn it on.
public struct DangerMode: Codable, Equatable, Sendable {
    public struct Grant: Codable, Equatable, Sendable {
        public var startedAt: Date
        /// nil = until turned off.
        public var until: Date?
        /// «Автопилот»: finished work is merged into main without asking.
        public var autopilot: Bool?
        /// `verify:` at the moment of turning on: a check changed later needs the person again.
        public var verify: String?
        public init(startedAt: Date, until: Date?, autopilot: Bool? = nil, verify: String? = nil) {
            self.startedAt = startedAt; self.until = until; self.autopilot = autopilot; self.verify = verify
        }
    }

    public enum Duration: String, CaseIterable, Identifiable, Sendable {
        case hour, eightHours, untilOff
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .hour: "1 час"
            case .eightHours: "8 часов"
            case .untilOff: "До выключения"
            }
        }
        var seconds: TimeInterval? {
            switch self {
            case .hour: 3600
            case .eightHours: DangerMode.longest
            case .untilOff: nil
            }
        }
    }

    public enum Action: CaseIterable, Sendable {
        /// `--dangerously-skip-permissions`.
        case fullAccess
        /// «Разрешить один раз» for a request of any step of a task, also planning and review.
        case answerRequest
        case approvePlan, autoFix, setup, teardown, addDependency, worktreeOnDirtyMain
        /// Local merge into main: only with «Автопилот».
        case merge
        /// Always the person's.
        case push, createPullRequest, mergePullRequest
    }

    /// What the decision needs to know about a job. The task's `source:` can only forbid.
    public struct JobFacts: Equatable, Sendable {
        /// Runs in the code lane: a task or a fix/reply that edits code (not planning, review, chat, light jobs).
        public var editsCode: Bool
        public var resolvesConflicts: Bool
        /// Text from outside (GitHub issue), or the task file can't be read.
        public var foreign: Bool
        /// Started by a schedule: merging stays with the person.
        public var scheduled: Bool
        public init(editsCode: Bool = true, resolvesConflicts: Bool = false, foreign: Bool = false, scheduled: Bool = false) {
            self.editsCode = editsCode
            self.resolvesConflicts = resolvesConflicts
            self.foreign = foreign
            self.scheduled = scheduled
        }
    }

    static let currentVersion = 1
    static let longest: TimeInterval = 8 * 3600

    public var version = DangerMode.currentVersion
    /// By normalized project path.
    public var grants: [String: Grant] = [:]
    public init() {}

    public static func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    /// A clock moved back, a term longer than allowed or an unknown file version mean «off».
    public func grant(_ project: String, now: Date) -> Grant? {
        guard version == Self.currentVersion, let g = grants[Self.key(project)], g.startedAt <= now else { return nil }
        guard let until = g.until else { return g }
        return until > now && until.timeIntervalSince(g.startedAt) <= Self.longest ? g : nil
    }

    public func isOn(_ project: String, now: Date) -> Bool { grant(project, now: now) != nil }

    /// Paths of the projects where the mode is on.
    public func active(now: Date) -> [String] { grants.keys.filter { isOn($0, now: now) }.sorted() }

    /// The nearest end of a term.
    public func nextExpiry(now: Date) -> Date? { active(now: now).compactMap { grants[$0]?.until }.min() }

    public func allows(_ action: Action, _ job: JobFacts, project: String, now: Date) -> Bool {
        switch action {
        case .merge: guard !job.scheduled, grant(project, now: now)?.autopilot == true else { return false }
        case .push, .createPullRequest, .mergePullRequest: return false
        case .fullAccess: guard job.editsCode, !job.resolvesConflicts else { return false }
        case .answerRequest, .approvePlan, .autoFix, .setup, .teardown, .addDependency, .worktreeOnDirtyMain: break
        }
        return !job.foreign && isOn(project, now: now)
    }

    /// Turns the mode on. `typed` must be the project's name: the person confirms which project it is.
    public mutating func enable(_ project: String, name: String, typed: String, _ duration: Duration, autopilot: Bool = false,
                                verify: String = "", now: Date) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, typed.trimmingCharacters(in: .whitespacesAndNewlines) == wanted else { return false }
        version = Self.currentVersion
        grants[Self.key(project)] = Grant(startedAt: now, until: duration.seconds.map { now.addingTimeInterval($0) },
                                               autopilot: autopilot ? true : nil, verify: autopilot ? verify : nil)
        return true
    }

    public mutating func disable(_ project: String) { grants[Self.key(project)] = nil }

    /// Missing, corrupt or unreadable file = off.
    public static func load(_ url: URL) -> (mode: DangerMode, problem: String?) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        switch SafeJSON.load(DangerMode.self, from: url, decoder: dec) {
        case .missing: return (DangerMode(), nil)
        case .value(let v): return (v, nil)
        case .corrupt, .unreadable: return (DangerMode(), "Файл \(url.lastPathComponent) не прочитан: опасный режим выключен.")
        }
    }

    public func save(_ url: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        try SafeJSON.save(try enc.encode(self), to: url)
    }

    // MARK: Old setting

    /// The old global «разрешить любые команды» grants nothing by itself: it only asks the person once.
    public static func asksAboutOldSetting(_ stored: Any?) -> Bool { stored as? Bool == true }
}
