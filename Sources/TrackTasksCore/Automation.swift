import CryptoKit
import Foundation

/// A schedule of a project: `automations/*.md`. The file describes what to create and when; the right to put
/// the created task into the queue is given by the person (`AutomationState`), never by the file.
public struct Automation: Identifiable, Hashable, Sendable {
    public static let folder = "automations"

    /// When it fires, in local time.
    public struct Rule: Hashable, Sendable {
        public enum Kind: String, CaseIterable, Sendable { case daily, weekly, monthly }
        public var kind: Kind
        public var hour: Int
        public var minute: Int
        /// Weekly: `Calendar` weekdays (1 = Sunday).
        public var weekdays: Set<Int>
        /// Monthly: 1…31; a shorter month fires on its last day.
        public var day: Int

        public init(_ kind: Kind, hour: Int, minute: Int, weekdays: Set<Int> = [], day: Int = 1) {
            self.kind = kind; self.hour = hour; self.minute = minute
            self.weekdays = kind == .weekly ? weekdays : []
            self.day = kind == .monthly ? day : 1
        }

        /// Equal keys = the same schedule. Stored in the state file.
        public var key: String {
            "\(kind.rawValue) \(hour):\(minute) \(weekdays.sorted().map(String.init).joined(separator: ",")) \(day)"
        }
    }

    public let url: URL
    public var id: String { Self.key(url) }
    public var fileName: String { url.lastPathComponent }
    public var title: String
    public var enabled: Bool
    public var rule: Rule?
    /// `queue: true` — a request, see above.
    public var queue: Bool
    public var priority: Priority
    public var size: String
    public var agent: String
    /// Body of the created tasks.
    public var body: String
    /// What is wrong with the file; a file with errors never runs.
    public var errors: [String]
    /// Changes with any byte of the file except its `enabled:` line.
    public var fingerprint: String

    public var isActive: Bool { enabled && errors.isEmpty && rule != nil }

    public static func key(_ url: URL) -> String { url.standardizedFileURL.path }
    public static func dir(in project: URL) -> URL { project.appendingPathComponent(folder, isDirectory: true) }

    /// Schedule files themselves, not the whole folder: a project may keep its code in `automations/`.
    public static func isFile(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == folder && parts[1].hasSuffix(".md") && !parts[1].hasPrefix(".")
    }

    // MARK: Reading

    /// `.md` files of the folder by name.
    public static func files(in project: URL) -> [URL] {
        let all = try? FileManager.default.contentsOfDirectory(at: dir(in: project), includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                                               options: [.skipsHiddenFiles])
        return (all ?? []).filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func all(in project: URL) -> [Automation] { files(in: project).compactMap { read($0) } }

    /// nil: not a regular file, or unreadable.
    static func text(of url: URL) -> String? {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// nil: unreadable, an event rule (`on:`), or an ordinary document (no `schedule:` and no `enabled:`).
    public static func read(_ url: URL) -> Automation? { text(of: url).flatMap { read($0, url: url) } }

    static func read(_ text: String, url: URL) -> Automation? {
        guard !EventRule.isRule(text),
              Frontmatter.raw("schedule", in: text) != nil || Frontmatter.raw("enabled", in: text) != nil else { return nil }
        return parse(text, url: url)
    }

    /// Every field is read with `Frontmatter.raw`: the same line `Frontmatter.setting` rewrites.
    public static func parse(_ text: String, url: URL) -> Automation {
        var errors: [String] = []
        func word(_ key: String) -> String { Frontmatter.unquote(Frontmatter.raw(key, in: text) ?? "").lowercased() }
        func flag(_ key: String) -> Bool {
            let v = word(key)
            if !["", "true", "false"].contains(v) { errors.append("\(key): \(v) — допустимо true | false") }
            return v == "true"
        }
        let title = Frontmatter.unquote(Frontmatter.raw("title", in: text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { errors.append("Нет поля title") }
        let enabled = flag("enabled"), queue = flag("queue")
        let priority = word("priority"), size = word("size"), agent = word("agent")
        if !priority.isEmpty, Priority(rawValue: priority) == nil { errors.append("priority: \(priority) — допустимо low | medium | high") }
        if !size.isEmpty, !TaskLint.sizes.contains(size) { errors.append("size: \(size) — допустимо s | m | l") }
        if !agent.isEmpty, !AgentProfile.isValidID(agent) { errors.append("agent: \(agent) — нужно имя профиля, например claude") }

        var rule: Rule?
        let time = clock(word("time"))
        if time == nil { errors.append("time: нужно время ЧЧ:ММ, например 09:00") }
        let kind = Rule.Kind(rawValue: word("schedule"))
        if kind == nil { errors.append("schedule: допустимо daily | weekly | monthly") }
        var days = Set<Int>(), day = 1, ok = true
        if kind == .weekly {
            let names = Frontmatter.list(Frontmatter.raw("days", in: text)).map { $0.lowercased() }
            for n in names {
                if let d = weekdays[n] { days.insert(d) } else { errors.append("days: \(n) — допустимо mon…sun"); ok = false }
            }
            if names.isEmpty { errors.append("days: нужны дни недели, например [mon, thu]"); ok = false }
        }
        if kind == .monthly {
            if let d = Int(word("day")), (1...31).contains(d) { day = d } else { errors.append("day: нужно число месяца 1–31"); ok = false }
        }
        if ok, let kind, let time { rule = Rule(kind, hour: time.0, minute: time.1, weekdays: days, day: day) }

        return Automation(url: url, title: title, enabled: enabled, rule: rule, queue: queue,
                          priority: Priority(rawValue: priority) ?? .medium, size: size, agent: agent,
                          body: Frontmatter.parse(text).body.trimmingCharacters(in: .whitespacesAndNewlines),
                          errors: errors, fingerprint: fingerprint(text))
    }

    static func fingerprint(_ text: String) -> String {
        let rest = Frontmatter.raw("enabled", in: text) == nil ? text : Frontmatter.setting("enabled", to: "", in: text)
        return SHA256.hash(data: Data(rest.replacingOccurrences(of: "\r\n", with: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func clock(_ v: String) -> (Int, Int)? {
        let parts = v.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let h = Int(parts[0]), let m = Int(parts[1]), h < 24, m < 60 else { return nil }
        return (h, m)
    }

    static let weekdays: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
        "вс": 1, "пн": 2, "вт": 3, "ср": 4, "чт": 5, "пт": 6, "сб": 7,
    ]

    // MARK: Writing

    /// The task it creates. The date in the title keeps runs apart (equal titles are a lint problem).
    public func task(stamp: String, created: String, dod: [String], in tasks: URL) -> TaskItem {
        var t = TaskItem(url: tasks, title: "\(title) — \(stamp)", status: .todo, priority: priority, created: created, completed: "",
                         body: DefinitionOfDone.apply(dod, to: body), size: size)
        t.agent = agent
        t.automation = fileName
        return t
    }

    /// Text of a new file: switched off until the person turns it on.
    public static func template(title: String) -> String {
        """
        ---
        title: \(Frontmatter.quote(title))
        enabled: false
        schedule: weekly        # daily | weekly | monthly
        time: "09:00"
        days: [mon]             # для weekly: mon, tue, wed, thu, fri, sat, sun
        queue: false            # true — просить ставить задачу в очередь (разрешение даётся в окне)
        priority: medium
        ---

        Что сделать.

        - [ ]

        ## Критерии готовности
        - [ ]

        """
    }
}

// MARK: - Calculation

extension Automation.Rule {
    /// Local date of a moment, `YYYY-MM-DD`: one schedule fires at most once a local day.
    public static func dayKey(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The moment of this rule on the local day of `d`, nil when the day doesn't match.
    /// A time skipped by the clock change moves to the next existing one; a repeated time means its first pass.
    func slot(onDayOf d: Date, _ cal: Calendar) -> Date? {
        let start = cal.startOfDay(for: d)
        switch kind {
        case .daily: break
        case .weekly: guard weekdays.contains(cal.component(.weekday, from: start)) else { return nil }
        case .monthly:
            let last = cal.range(of: .day, in: .month, for: start)?.count ?? 31
            guard cal.component(.day, from: start) == min(day, last) else { return nil }
        }
        // From just before midnight, so that 00:00 itself is found.
        guard let found = cal.nextDate(after: start.addingTimeInterval(-1), matching: DateComponents(hour: hour, minute: minute, second: 0),
                                       matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { return nil }
        // Midnight itself skipped by the clock change.
        return cal.isDate(found, inSameDayAs: start) ? found : start
    }

    /// The nearest moment strictly after `date`, on a local day later than `lastDay`.
    public func next(after date: Date, lastDay: String? = nil, calendar cal: Calendar) -> Date? {
        let today = cal.startOfDay(for: date)
        for i in 0..<100 {
            guard let d = cal.date(byAdding: .day, value: i, to: today), let s = slot(onDayOf: d, cal) else { continue }
            if s > date, lastDay.map({ Self.dayKey(s, cal) > $0 }) ?? true { return s }
        }
        return nil
    }

    /// The one moment to run now: the latest missed in (`since`, `now`]. Earlier ones are dropped.
    public func due(since: Date, lastDay: String? = nil, now: Date, calendar cal: Calendar) -> Date? {
        guard since < now else { return nil }
        let today = cal.startOfDay(for: now)
        for i in 0..<100 {
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            guard let s = slot(onDayOf: d, cal), s <= now else { continue }
            return s > since && (lastDay.map { Self.dayKey(s, cal) > $0 } ?? true) ? s : nil
        }
        return nil
    }
}
