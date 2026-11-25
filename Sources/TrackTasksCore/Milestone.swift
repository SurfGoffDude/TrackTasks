import Foundation

/// Progress of one milestone: tasks of a project with the same `milestone:`.
public struct Milestone: Identifiable, Equatable, Sendable {
    public var name: String
    public var done: Int
    public var total: Int
    public var id: String { name }

    /// Share of done tasks, 0…1.
    public var progress: Double { total > 0 ? Double(done) / Double(total) : 0 }
    /// Rounded down: 100 only when everything is done.
    public var percent: Int { total > 0 ? done * 100 / total : 0 }

    /// Milestones used by `tasks`, in natural order (v1.2 before v1.10).
    /// Done tasks of `archive` still count for a milestone that has active tasks.
    public static func all(in tasks: [TaskItem], archive: [TaskItem] = []) -> [Milestone] {
        let names = Set(tasks.map(\.milestone))
        let old = archive.filter { $0.status == .done && names.contains($0.milestone) }
        return Dictionary(grouping: (tasks + old).filter { !$0.milestone.isEmpty }, by: \.milestone)
            .map { Milestone(name: $0.key, done: $0.value.filter { $0.status == .done }.count, total: $0.value.count) }
            .sorted { before($0.name, $1.name) }
    }

    /// Names in natural order, "" (no milestone) last.
    static func before(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return !a.isEmpty && b.isEmpty }
        let r = a.localizedStandardCompare(b)
        return r == .orderedSame ? a < b : r == .orderedAscending
    }

    /// Tasks (file names) split by milestone; order inside a group is kept.
    public static func groups(_ names: [String], milestone: [String: String]) -> [(milestone: String, tasks: [String])] {
        Dictionary(grouping: names) { milestone[$0] ?? "" }
            .sorted { before($0.key, $1.key) }
            .map { (milestone: $0.key, tasks: $0.value) }
    }

    /// One line without outer spaces: what can be stored in the file.
    public static func clean(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Name from the raw frontmatter value; "" for a malformed one, so that saving leaves it as is.
    static func parse(_ raw: String?) -> String {
        guard let raw, !isMalformed(raw) else { return "" }
        return clean(Frontmatter.unquote(raw))
    }

    /// A list or an unclosed quote.
    static func isMalformed(_ raw: String) -> Bool {
        raw.hasPrefix("[") || (raw.hasPrefix("\"") && (raw.count < 2 || !raw.hasSuffix("\"")))
    }
}

public enum MilestoneFilter: Hashable, Sendable {
    case all
    /// Tasks without a milestone.
    case none
    case named(String)

    public func matches(_ t: TaskItem) -> Bool {
        switch self {
        case .all: true
        case .none: t.milestone.isEmpty
        case .named(let n): t.milestone == n
        }
    }

    /// The filter that makes sense for `tasks`: everything when the picked milestone is not there (any more).
    public func valid(in tasks: [TaskItem]) -> MilestoneFilter {
        switch self {
        case .all: .all
        case .none: tasks.contains { !$0.milestone.isEmpty } ? self : .all
        case .named: tasks.contains(where: matches) ? self : .all
        }
    }

    /// Milestone a task created under this filter gets.
    public var newTaskMilestone: String {
        if case .named(let n) = self { n } else { "" }
    }
}
