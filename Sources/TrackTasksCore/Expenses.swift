import Foundation

/// Money spent on projects by hand (hosting, domains, API keys…). Claude spend comes from Spend separately.
/// One expense can belong to one project, be shared by several (split equally) or be general (no project).
/// Stored by the app in Application Support, so amounts never end up in a git repo.
///
/// Pure model + money math (no UI): recurring payments, per-month overrides, shares, totals per currency.
/// `now` / `calendar` parameters exist for tests; the app uses the defaults.
public struct Expense: Codable, Identifiable, Hashable, Sendable {
    public enum Period: String, Codable, CaseIterable, Identifiable, Sendable {
        case once, monthly, yearly
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .once: "Разово"
            case .monthly: "Каждый месяц"
            case .yearly: "Каждый год"
            }
        }
        public var short: String {
            switch self {
            case .once: ""
            case .monthly: "/мес"
            case .yearly: "/год"
            }
        }
    }

    /// `icon` / `color` live in the app (extension), they need SF Symbols / SwiftUI.
    public enum Category: String, Codable, CaseIterable, Identifiable, Sendable {
        case hosting, domain, api, service, ads, people, hardware, other
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .hosting: "Хостинг и серверы"
            case .domain: "Домены"
            case .api: "API и ключи"
            case .service: "Сервисы и подписки"
            case .ads: "Реклама"
            case .people: "Подрядчики"
            case .hardware: "Железо"
            case .other: "Другое"
            }
        }
    }

    public struct Payment: Hashable, Sendable {
        public let date: Date
        public let amount: Double
        public let overridden: Bool
        /// "yyyy-MM" of the payment (Calendar.current).
        public var key: String { Expense.monthKey(date) }

        public init(date: Date, amount: Double, overridden: Bool) {
            self.date = date
            self.amount = amount
            self.overridden = overridden
        }
    }

    public var id = UUID()
    /// Project folder paths. 1 = own expense, 2+ = shared (split equally), empty = general.
    public var projects: [String]
    public var title: String
    public var amount: Double
    public var currency: String
    public var category: Category
    /// First (or only) payment.
    public var date: Date
    public var period: Period
    /// Subscription cancelled after this date.
    public var until: Date?
    /// Amount for one specific charge, keyed "yyyy-MM". 0 = skipped that month.
    public var overrides: [String: Double] = [:]
    public var excludeFromExport = false
    public var note = ""

    public static let currencies = ["₽", "$", "€"]

    public init(projects: [String], title: String, amount: Double, currency: String, category: Category,
                date: Date, period: Period, until: Date? = nil) {
        self.projects = projects
        self.title = title
        self.amount = amount
        self.currency = currency
        self.category = category
        self.date = date
        self.period = period
        self.until = until
    }

    private enum CodingKeys: String, CodingKey {
        case id, projects, project, title, amount, currency, category, date, period, until, overrides, excludeFromExport, note
    }

    /// Lenient: old files had a single `project` and no currency/category/period.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let ps = try c.decodeIfPresent([String].self, forKey: .projects) {
            projects = ps
        } else {
            projects = (try c.decodeIfPresent(String.self, forKey: .project)).map { [$0] } ?? []
        }
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        amount = try c.decode(Double.self, forKey: .amount)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "₽"
        category = try c.decodeIfPresent(Category.self, forKey: .category) ?? .other
        date = try c.decode(Date.self, forKey: .date)
        period = try c.decodeIfPresent(Period.self, forKey: .period) ?? .once
        until = try c.decodeIfPresent(Date.self, forKey: .until)
        overrides = try c.decodeIfPresent([String: Double].self, forKey: .overrides) ?? [:]
        excludeFromExport = try c.decodeIfPresent(Bool.self, forKey: .excludeFromExport) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projects, forKey: .projects)
        try c.encode(title, forKey: .title)
        try c.encode(amount, forKey: .amount)
        try c.encode(currency, forKey: .currency)
        try c.encode(category, forKey: .category)
        try c.encode(date, forKey: .date)
        try c.encode(period, forKey: .period)
        try c.encodeIfPresent(until, forKey: .until)
        if !overrides.isEmpty { try c.encode(overrides, forKey: .overrides) }
        if excludeFromExport { try c.encode(true, forKey: .excludeFromExport) }
        if !note.isEmpty { try c.encode(note, forKey: .note) }
    }

    /// "yyyy-MM" — key of `overrides`.
    public static func monthKey(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    public var isActive: Bool { isActive(at: Date()) }
    public func isActive(at now: Date) -> Bool { period != .once && (until.map { $0 >= now } ?? true) }
    public var isShared: Bool { projects.count > 1 }
    public var isGeneral: Bool { projects.isEmpty }

    /// Part of each payment that belongs to `project` (equal split).
    public func share(_ project: String) -> Double {
        projects.contains(project) ? 1 / Double(projects.count) : 0
    }

    /// Payments that happened within [from, to] (never after `now`), with per-month overrides applied.
    /// Recurring payments step from `date` (k months/years from the first one), so the 31st becomes
    /// Feb 28/29 and goes back to the 31st in March.
    public func payments(from: Date, to: Date = Date(), includeSkipped: Bool = false,
                         now: Date = Date(), calendar: Calendar = .current) -> [Payment] {
        let end = min(to, until ?? to, now)
        guard date <= end else { return [] }
        var out: [Payment] = []
        func add(_ d: Date) {
            let o = overrides[Expense.monthKey(d, calendar: calendar)]
            let a = o ?? amount
            if a > 0 || includeSkipped { out.append(Payment(date: d, amount: a, overridden: o != nil)) }
        }
        switch period {
        case .once:
            if date >= from { add(date) }
        case .monthly, .yearly:
            let step: Calendar.Component = period == .monthly ? .month : .year
            var k = 0
            while let d = calendar.date(byAdding: step, value: k, to: date), d <= end, k < 1200 {
                if d >= from { add(d) }
                k += 1
            }
        }
        return out
    }

    public func total(from: Date, to: Date = Date(), now: Date = Date(), calendar: Calendar = .current) -> Double {
        payments(from: from, to: to, now: now, calendar: calendar).reduce(0) { $0 + $1.amount }
    }

    /// Monthly equivalent of an active subscription (base amount).
    public var perMonth: Double { perMonth(at: Date()) }
    public func perMonth(at now: Date) -> Double {
        guard isActive(at: now) else { return 0 }
        return period == .monthly ? amount : amount / 12
    }

    /// Set (or reset with nil) one month's amount; an amount equal to the usual one removes the override.
    public func settingOverride(month: String, amount new: Double?) -> Expense {
        var x = self
        if let new, abs(new - amount) > 0.0001 { x.overrides[month] = new } else { x.overrides[month] = nil }
        return x
    }

    /// Overrides from the editor's per-month text fields: unparsable or equal to `base` are dropped.
    public static func overrides(fromTexts texts: [String: String], base: Double) -> [String: Double] {
        var o: [String: Double] = [:]
        for (k, t) in texts {
            if let v = parseAmount(t), abs(v - base) > 0.0001 { o[k] = v }
        }
        return o
    }
}

/// Sums per currency, e.g. ["₽": 1200, "$": 12].
public typealias Money = [String: Double]

/// Totals over a list of expenses, per currency. `project` = that project's share, nil = everything.
public enum ExpenseMath {
    public static func spent(_ items: [Expense], project: String? = nil, from: Date, to: Date = Date(),
                             now: Date = Date(), calendar: Calendar = .current) -> Money {
        var m: Money = [:]
        for x in items {
            let k = project.map { x.share($0) } ?? 1
            guard k > 0 else { continue }
            let t = x.total(from: from, to: to, now: now, calendar: calendar) * k
            if t > 0 { m[x.currency, default: 0] += t }
        }
        return m
    }

    /// Active subscriptions per month (yearly / 12).
    public static func monthly(_ items: [Expense], project: String? = nil, now: Date = Date()) -> Money {
        var m: Money = [:]
        for x in items where x.isActive(at: now) {
            let k = project.map { x.share($0) } ?? 1
            if k > 0 { m[x.currency, default: 0] += x.perMonth(at: now) * k }
        }
        return m
    }

    /// Adds Claude spend (always in $) when it's noticeable.
    public static func adding(claude: Double, to m: Money) -> Money {
        var r = m
        if claude > 0.004 { r["$", default: 0] += claude }
        return r
    }
}

public enum MoneyFormat {
    private static let nf: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        return f
    }()

    public static func amount(_ v: Double, _ cur: String) -> String {
        let n = nf.string(from: NSNumber(value: v)) ?? String(v)
        return cur == "₽" ? "\(n) ₽" : "\(cur)\(n)"
    }

    /// Known currencies first (₽, $, €), then the rest alphabetically; near-zero known ones are hidden.
    public static func money(_ m: Money, empty: String = "—") -> String {
        let parts = Expense.currencies.compactMap { c in m[c].flatMap { $0 > 0.004 ? amount($0, c) : nil } }
            + m.keys.filter { !Expense.currencies.contains($0) }.sorted().compactMap { c in m[c].map { amount($0, c) } }
        return parts.isEmpty ? empty : parts.joined(separator: " + ")
    }

    public static func month(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let d = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) else { return key }
        return d.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "ru_RU")))
    }
}

/// "1 234,50" / "1234.5" / with no-break spaces → 1234.5; nil when not a number.
public func parseAmount(_ s: String) -> Double? {
    Double(s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "\u{00A0}", with: "")
        .replacingOccurrences(of: "\u{202F}", with: ""))
}
