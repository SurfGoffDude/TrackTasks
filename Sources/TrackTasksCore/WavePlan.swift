import Foundation

/// «Волнами по приоритету»: tasks run in waves — all high in parallel, then all medium, then low.
/// `depends:` beats priority: a dependency is pulled into the wave of its earliest dependent
/// (never later), and inside one wave the dependent still waits for its dependency.
public enum WavePlan {
    public struct Wave: Equatable, Sendable {
        public var priority: Priority
        /// File names, dependencies before dependents.
        public var tasks: [String]
        public init(priority: Priority, tasks: [String]) {
            self.priority = priority
            self.tasks = tasks
        }
    }

    static func rank(_ p: Priority) -> Int {
        switch p {
        case .high: 0
        case .medium: 1
        case .low: 2
        }
    }

    static let byRank: [Priority] = [.high, .medium, .low]

    /// Non-empty waves in run order. Same inputs as `DependencyPlan.order`; tasks missing in
    /// `priority` count as medium. Cycles and missing dependencies fail like there.
    public static func waves(targets: [String], nodes: [String: DependencyPlan.Node],
                             priority: [String: Priority],
                             queued: Set<String> = []) -> Result<[Wave], DependencyPlan.Failure> {
        let order: [String]
        switch DependencyPlan.order(targets: targets, nodes: nodes, queued: queued) {
        case .failure(let f): return .failure(f)
        case .success(let o): order = o
        }
        var wave: [String: Int] = [:]
        for name in order { wave[name] = rank(priority[name] ?? .medium) }
        // Reverse topological order: every dependent is final before its dependencies are visited.
        for name in order.reversed() {
            guard let w = wave[name] else { continue }
            for d in nodes[name]?.depends ?? [] {
                if let dw = wave[d], dw > w { wave[d] = w }
            }
        }
        return .success(byRank.indices.compactMap { r in
            let tasks = order.filter { wave[$0] == r }
            return tasks.isEmpty ? nil : Wave(priority: byRank[r], tasks: tasks)
        })
    }
}
