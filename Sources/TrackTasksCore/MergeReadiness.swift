import Foundation

/// «Слить все»: which branch is next and what came out of it.
public struct MergeBatch: Equatable, Sendable {
    public struct Skip: Equatable, Sendable {
        public var title: String
        public var reason: String
    }
    public private(set) var queue: [UUID]
    public let total: Int
    public private(set) var merged = 0
    public private(set) var skipped: [Skip] = []
    public private(set) var stopped = false

    public init(_ ids: [UUID]) { queue = ids; total = ids.count }

    public var done: Int { merged + skipped.count }
    public mutating func next() -> UUID? { stopped || queue.isEmpty ? nil : queue.removeFirst() }
    /// `reason` nil — merged.
    public mutating func record(_ title: String, skipped reason: String?) {
        if let reason { skipped.append(.init(title: title, reason: reason)) } else { merged += 1 }
    }
    public mutating func stop() { stopped = true }

    public var summary: String {
        let lines = skipped.map { "\($0.title): \($0.reason)" }
        let head = stopped ? ["Остановлено, не начато: \(queue.count)"] : []
        return lines.isEmpty && head.isEmpty ? "Готово" : (head + lines).joined(separator: "\n")
    }
}

/// «Готово к слиянию»: state of a branch's check and files shared with other branches.
public enum MergeReadiness {
    public enum CheckState: Equatable, Sendable { case none, fresh, stale, red, timedOut, unverified
        /// The task's own check can't be run: it isn't approved, or is wrong.
        case blocked
    }

    /// `tip`, `main`, `command`, `taskCommand` — how things are now.
    public static func state(_ c: SafeMerge.Check?, tip: String, main: String, mainBranch: String, command: String, taskCommand: String = "") -> CheckState {
        guard let c else { return command.isEmpty ? .unverified : .none }
        guard c.branchCommit == tip, c.mainCommit == main, c.mainBranch == mainBranch, c.runs(command, taskCommand) else { return .stale }
        switch c.state {
        case .passed: return .fresh
        case .red: return .red
        case .timedOut: return .timedOut
        case .unverified: return .unverified
        }
    }

    public struct Branch: Sendable {
        public var id: UUID
        /// Main folder; branches of different projects never overlap.
        public var project: String
        public var files: Set<String>
        public init(id: UUID, project: String, files: Set<String>) { self.id = id; self.project = project; self.files = files }
    }

    public struct Overlap: Equatable, Sendable {
        public var other: UUID
        public var files: [String]
    }

    /// For each branch: other branches of the same project that change the same files.
    public static func overlaps(_ list: [Branch]) -> [UUID: [Overlap]] {
        var out: [UUID: [Overlap]] = [:]
        for a in list {
            out[a.id] = list.compactMap { b in
                guard b.id != a.id, b.project == a.project else { return nil }
                let common = a.files.intersection(b.files).sorted()
                return common.isEmpty ? nil : Overlap(other: b.id, files: common)
            }
        }
        return out
    }
}
