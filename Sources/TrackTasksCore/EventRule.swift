import Foundation

/// A rule of a project: `automations/*.md` with `on:`. Creates a task when something happens outside. Like a schedule,
/// the file only describes; the right to queue is given by the person (`EventState`).
public struct EventRule: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case webhook, github, git }
    public static let defaultLimit = 10
    public static let maxLimit = 60
    static let maxFields = 20

    public let url: URL
    public var id: String { Automation.key(url) }
    public var fileName: String { url.lastPathComponent }
    public var title: String
    public var enabled: Bool
    public var kind: Kind?
    /// github: `push` or `issues.opened`.
    public var events: [String]
    /// git and github push; empty = any.
    public var branches: [String]
    /// Paths in the JSON (`pull_request.title`): nothing else of an event gets into the task.
    public var fields: [String]
    /// Accepted events an hour.
    public var limit: Int
    /// `queue: true` — a request only.
    public var queue: Bool
    public var priority: Priority
    public var size: String
    public var agent: String
    /// Body of the created tasks; nothing is substituted in it.
    public var body: String
    public var errors: [String]
    /// Same as `Automation.fingerprint`.
    public var fingerprint: String

    public var isActive: Bool { enabled && errors.isEmpty && kind != nil }
    /// Has an address and a secret.
    public var isRemote: Bool { kind == .webhook || kind == .github }

    public static func isRule(_ text: String) -> Bool { Frontmatter.raw("on", in: text) != nil }

    public static func read(_ url: URL) -> EventRule? {
        Automation.text(of: url).flatMap { isRule($0) ? parse($0, url: url) : nil }
    }

    public static func parse(_ text: String, url: URL) -> EventRule {
        var errors: [String] = []
        func raw(_ key: String) -> String { Frontmatter.unquote(Frontmatter.raw(key, in: text) ?? "") }
        func word(_ key: String) -> String { raw(key).lowercased() }
        func flag(_ key: String) -> Bool {
            let v = word(key)
            if !["", "true", "false"].contains(v) { errors.append("\(key): \(v) — допустимо true | false") }
            return v == "true"
        }
        let title = raw("title").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { errors.append("Нет поля title") }
        let enabled = flag("enabled"), queue = flag("queue")
        let priority = word("priority"), size = word("size"), agent = word("agent")
        if !priority.isEmpty, Priority(rawValue: priority) == nil { errors.append("priority: \(priority) — допустимо low | medium | high") }
        if !size.isEmpty, !TaskLint.sizes.contains(size) { errors.append("size: \(size) — допустимо s | m | l") }
        if !agent.isEmpty, !AgentProfile.isValidID(agent) { errors.append("agent: \(agent) — нужно имя профиля, например claude") }
        // One file is one automation: never a schedule and a rule at once.
        if Frontmatter.raw("schedule", in: text) != nil { errors.append("on и schedule в одном файле: оставь что-то одно") }

        let kind = Kind(rawValue: word("on"))
        if kind == nil { errors.append("on: допустимо webhook | github | git") }
        let events = Frontmatter.list(Frontmatter.raw("events", in: text)).map { $0.lowercased() }
        let branches = Frontmatter.list(Frontmatter.raw("branches", in: text))
        let fields = Frontmatter.list(Frontmatter.raw("fields", in: text))
        if kind == .github {
            if events.isEmpty { errors.append("events: нужен список, например [push, issues.opened]") }
            for e in events where !isEvent(e) { errors.append("events: \(e) — допустимо \(EventPayload.githubEvents.joined(separator: " | ")), можно с действием: issues.opened") }
        } else if !events.isEmpty { errors.append("events: только для on: github") }
        if kind == .webhook, !branches.isEmpty { errors.append("branches: только для git и github push") }
        if kind == .git, !fields.isEmpty { errors.append("fields: только для webhook и github") }
        for f in fields where !isPath(f) { errors.append("fields: \(f) — нужен путь из латинских букв, цифр, _ и -, например issue.title") }
        if fields.count > maxFields { errors.append("fields: не больше \(maxFields)") }
        var limit = defaultLimit
        let rawLimit = word("limit")
        if !rawLimit.isEmpty {
            if let n = Int(rawLimit), (1...maxLimit).contains(n) { limit = n } else { errors.append("limit: нужно число запусков в час 1–\(maxLimit)") }
        }
        return EventRule(url: url, title: title, enabled: enabled, kind: kind, events: events, branches: branches, fields: fields,
                         limit: limit, queue: queue, priority: Priority(rawValue: priority) ?? .medium, size: size, agent: agent,
                         body: Frontmatter.parse(text).body.trimmingCharacters(in: .whitespacesAndNewlines),
                         errors: errors, fingerprint: Automation.fingerprint(text))
    }

    private static func isEvent(_ e: String) -> Bool {
        let parts = e.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard EventPayload.githubEvents.contains(parts[0]) else { return false }
        return parts.count == 1 || (!parts[1].isEmpty && parts[1].utf8.allSatisfy { (97...122).contains($0) || $0 == 95 })
    }

    private static func isPath(_ f: String) -> Bool {
        f.utf8.count <= 100 && f.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { p in
            !p.isEmpty && p.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }
        }
    }

    /// Text of a new file: switched off until the person turns it on.
    public static func template(title: String, kind: Kind) -> String {
        let own = switch kind {
        case .webhook: "fields: []              # поля JSON для задачи, например [message, build.url]"
        case .github: "events: [issues.opened] # push, pull_request.opened, workflow_run.completed…\nfields: [issue.title, issue.html_url]"
        case .git: "branches: [main]"
        }
        return """
        ---
        title: \(Frontmatter.quote(title))
        enabled: false
        on: \(kind.rawValue)
        \(own)
        limit: \(defaultLimit)               # событий в час, не больше \(maxLimit)
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
