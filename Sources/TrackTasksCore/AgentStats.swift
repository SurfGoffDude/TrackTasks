import Foundation

/// One agent run in spend.jsonl.
public struct SpendEntry: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var project: String
    public var model: String
    public var kind: String
    /// nil = the agent doesn't report it.
    public var cost: Double?
    /// Uncached input. Entries written before the cache split hold the total here and nil below.
    public var input: Int
    public var output: Int
    public var cacheWrite: Int?
    public var cacheRead: Int?
    /// Milliseconds and turns; nil = not reported (or written before they were kept).
    public var duration: Int?
    public var turns: Int?
    /// Title and file name of the task; nil = not a task run.
    public var task: String?
    public var taskFile: String?

    public init(date: Date, project: String, model: String, kind: String, cost: Double?, input: Int, output: Int,
                cacheWrite: Int? = nil, cacheRead: Int? = nil, duration: Int? = nil, turns: Int? = nil,
                task: String? = nil, taskFile: String? = nil) {
        self.date = date; self.project = project; self.model = model; self.kind = kind
        self.cost = cost; self.input = input; self.output = output
        self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
        self.duration = duration; self.turns = turns
        self.task = task; self.taskFile = taskFile
    }

    public var totalInput: Int { input + (cacheWrite ?? 0) + (cacheRead ?? 0) }
    public var hasCacheSplit: Bool { cacheWrite != nil || cacheRead != nil }

    /// Same task in runs of different kinds (task, review, fix); survives the move to the archive.
    public var taskKey: String? { (taskFile ?? task).map { project + "/" + $0 } }
}

/// The task a run belongs to.
public struct SpendTask: Equatable, Sendable {
    public var title: String
    public var file: String?
    public init(title: String, file: String?) { self.title = title; self.file = file }
}

public enum AgentStats {
    public enum Metric: String, CaseIterable, Sendable {
        case cost, time, turns

        /// nil = the run has no such data.
        public func value(_ e: SpendEntry) -> Double? {
            switch self {
            case .cost: e.cost
            case .time: e.duration.map { Double($0) / 60_000 }
            case .turns: e.turns.map(Double.init)
            }
        }
    }

    /// Runs of one model, task, project… Sums cover only the runs that have the data.
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var detail = ""
        public var cost = AgentCost()
        public var runs = 0
        public var durationMs = 0
        public var timedRuns = 0
        public var turns = 0
        public var turnRuns = 0

        public func value(_ m: Metric) -> Double {
            switch m {
            case .cost: cost.usd
            case .time: Double(durationMs) / 60_000
            case .turns: Double(turns)
            }
        }

        /// A partly known sum is marked like a partly known cost.
        public func text(_ m: Metric) -> String {
            switch m {
            case .cost: cost.text() ?? "$0.00"
            case .time: timedRuns == 0 ? AgentCost.noData : (timedRuns < runs ? "≥ " : "") + AgentRunResult.duration(durationMs)
            case .turns: turnRuns == 0 ? AgentCost.noData : (turnRuns < runs ? "≥ " : "") + "\(turns)"
            }
        }

        mutating func add(_ e: SpendEntry) {
            runs += 1
            cost.add(e.cost)
            if let d = e.duration { durationMs += d; timedRuns += 1 }
            if let t = e.turns { turns += t; turnRuns += 1 }
        }
    }

    public static func rows(_ entries: [SpendEntry], by key: (SpendEntry) -> String, sort: Metric = .cost) -> [Row] {
        collect(entries, sort) { let k = key($0); return (k, k.isEmpty ? "—" : k, "") }
    }

    /// Runs outside tasks are left out. The newest title wins.
    public static func tasks(_ entries: [SpendEntry], sort: Metric = .cost) -> [Row] {
        collect(entries.sorted { $0.date > $1.date }, sort) { e in
            e.taskKey.map { ($0, e.task ?? e.taskFile ?? "—", e.project) }
        }
    }

    private static func collect(_ entries: [SpendEntry], _ sort: Metric,
                                _ key: (SpendEntry) -> (id: String, name: String, detail: String)?) -> [Row] {
        var out: [String: Row] = [:]
        for e in entries {
            guard let k = key(e) else { continue }
            out[k.id, default: Row(id: k.id, name: k.name, detail: k.detail)].add(e)
        }
        return out.values.sorted { ($1.value(sort), $0.name, $0.id) < ($0.value(sort), $1.name, $1.id) }
    }
}
