import Foundation

/// A run refused by the subscription limit: which window is used up and when it resets (nil = not reported).
public struct RunLimit: Equatable, Sendable {
    /// `rateLimitType` of Claude; empty = the agent didn't name it.
    public var window: String
    public var resetsAt: Date?

    public init(window: String = "", resetsAt: Date? = nil) {
        self.window = window
        self.resetsAt = resetsAt
    }

    public static let fiveHour = "five_hour"

    public var title: String {
        if window == Self.fiveHour { return "Пятичасовой лимит" }
        return window.hasPrefix("seven_day") ? "Недельный лимит" : "Лимит"
    }

    /// Refusal in Claude's `rate_limit_info`. Extra usage goes on over the window, so that isn't one.
    public init?(claude info: [String: Any]) {
        guard info["status"] as? String == "rejected", info["isUsingOverage"] as? Bool != true else { return nil }
        self.init(window: info["rateLimitType"] as? String ?? "",
                  resetsAt: (info["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)))
    }
}

/// A job stopped by the limit: after the reset it continues its session, once per window.
public struct LimitWait: Codable, Equatable, Sendable {
    public var window: String
    public var resetsAt: Date
    /// The job's own session.
    public var session: String
    /// Code state before a plan or a review: kept so that a restart of the app doesn't hide edits.
    public var planBaseline: String?
    public var planShared: Bool?

    public init(window: String, resetsAt: Date, session: String, planBaseline: String? = nil, planShared: Bool? = nil) {
        self.window = window
        self.resetsAt = resetsAt
        self.session = session
        self.planBaseline = planBaseline
        self.planShared = planShared
    }

    /// The clocks of this Mac and the server differ a little.
    public static let grace: TimeInterval = 60
    public func isDue(_ now: Date) -> Bool { now >= resetsAt.addingTimeInterval(Self.grace) }

    /// The same reset may be reported with a small difference.
    public static func sameWindow(_ a: Date?, _ b: Date) -> Bool { a.map { abs($0.timeIntervalSince(b)) < 10 * 60 } ?? false }

    /// Why a refused run is not continued automatically; nil = it waits for the reset.
    /// `retried`: reset time of the window that already had its retry.
    public static func refusal(_ l: RunLimit, session: String?, canResume: Bool, retried: Date?, now: Date) -> String? {
        guard let reset = l.resetsAt else { return "\(l.title) исчерпан, время сброса неизвестно: автоматического повтора не будет" }
        if l.window != RunLimit.fiveHour { return "\(l.title) исчерпан до \(clock(reset, now: now)): автоматического повтора не будет" }
        if reset <= now { return "\(l.title) исчерпан, но названный сброс уже прошёл: автоматического повтора не будет" }
        if session == nil || !canResume { return "\(l.title) исчерпан, а сессию продолжить нельзя: автоматического повтора не будет" }
        if sameWindow(retried, reset) { return "\(l.title) исчерпан, повтор для этого окна уже был" }
        return nil
    }

    /// "14:30", on another day "25.11 14:30".
    public static func clock(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "dd.MM HH:mm"
        return f.string(from: d)
    }
}

/// Stored in queue.json: a record that can't be read must not lose the whole queue.
public struct LenientLimitWait: Codable, Sendable {
    public var value: LimitWait?
    public init(_ value: LimitWait) { self.value = value }
    public init(from decoder: Decoder) throws { value = try? LimitWait(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value?.encode(to: encoder) }
}
