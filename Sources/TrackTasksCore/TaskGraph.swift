import Foundation

/// Layout for the «Граф» view of a project: columns are the waves `WavePlan` would queue
/// («Волнами по приоритету» for all unfinished tasks), arrows are `depends:`.
/// Never fails: cycles and broken links become per-node errors, the rest is still laid out.
public enum TaskGraph {
    public struct Task: Sendable, Equatable {
        public var name: String
        public var status: TaskStatus
        public var priority: Priority
        public var depends: [String]
        public init(name: String, status: TaskStatus, priority: Priority, depends: [String]) {
            self.name = name
            self.status = status
            self.priority = priority
            self.depends = depends
        }
    }

    public enum State: Sendable, Equatable {
        /// Not done, every dependency is done — can be taken right now.
        case ready
        /// Waits for an unfinished dependency.
        case blocked
        case done
        /// In a cycle or depends on a missing file.
        case error
    }

    public struct Node: Sendable, Equatable {
        public var name: String
        public var state: State
        public var errors: [String]
    }

    public enum ColumnKind: Sendable, Equatable {
        case done
        /// 1-based wave number and its priority.
        case wave(Int, Priority)
        /// Tasks that can't be planned (cycles).
        case errors
    }

    public struct Column: Sendable, Equatable {
        public var kind: ColumnKind
        public var tasks: [String]
    }

    public struct Edge: Sendable, Hashable {
        /// Dependency.
        public var from: String
        /// Dependent.
        public var to: String
    }

    public struct Layout: Sendable, Equatable {
        public var columns: [Column]
        public var nodes: [String: Node]
        /// Only between tasks that are shown.
        public var edges: [Edge]
        /// All error messages, in the order found.
        public var errors: [String]
        /// Wave columns only, as `WavePlan.Wave` (what «Запустить волнами» would queue).
        public var waves: [WavePlan.Wave] {
            columns.compactMap {
                if case .wave(_, let p) = $0.kind { WavePlan.Wave(priority: p, tasks: $0.tasks) } else { nil }
            }
        }
    }

    /// `tasks` in board order (the order targets are passed to `WavePlan`).
    /// `only`: plan just these tasks, as queuing them would — with unfinished dependencies from outside.
    /// `parked`: archive and drafts — not shown, but `depends:` may point there.
    public static func build(_ tasks: [Task], showDone: Bool = true, only: Set<String>? = nil,
                             parked: [String: DependencyPlan.Node] = [:]) -> Layout {
        var byName: [String: Task] = [:]
        for t in tasks where byName[t.name] == nil { byName[t.name] = t }
        var errors: [String: [String]] = [:]
        var messages: [String] = []
        func fail(_ name: String, _ message: String) {
            errors[name, default: []].append(message)
            if !messages.contains(message) { messages.append(message) }
        }

        // Broken links first: same check as TaskLint, for done tasks too.
        var nodes: [String: DependencyPlan.Node] = [:]
        for (name, t) in byName {
            var deps: [String] = []
            for d in t.depends {
                if byName[d] == nil, let o = parked[d], let folder = o.parked {
                    if !o.done { fail(name, DependencyPlan.Failure.parked(task: name, dependency: d, folder: folder).message) }
                } else if byName[d] == nil {
                    fail(name, DependencyPlan.Failure.missing(task: name, dependency: d).message)
                } else if !deps.contains(d) {
                    deps.append(d)
                }
            }
            nodes[name] = DependencyPlan.Node(done: t.status == .done, depends: deps)
        }

        // Each cycle found is cut out of the plan and planning retried; every round removes nodes,
        // so it ends after at most `tasks.count` rounds.
        let prio = byName.mapValues(\.priority)
        var excluded: [String] = []
        var waves: [WavePlan.Wave] = []
        for _ in 0...byName.count {
            let targets = tasks.map(\.name).filter {
                byName[$0]?.status != .done && nodes[$0] != nil && only?.contains($0) != false
            }
            switch WavePlan.waves(targets: targets, nodes: nodes, priority: prio) {
            case .success(let w):
                waves = w
            case .failure(let f):
                let members: [String]
                switch f {
                case .cycle(let path): members = Array(Set(path))
                case .missing(let t, _), .parked(let t, _, _): members = [t] // already stripped above; kept for safety
                }
                for m in members.sorted() {
                    fail(m, f.message)
                    nodes[m] = nil
                    excluded.append(m)
                }
                for k in nodes.keys { nodes[k]?.depends.removeAll { members.contains($0) } }
                continue
            }
            break
        }

        var result: [String: Node] = [:]
        for (name, t) in byName {
            let state: State
            if errors[name] != nil {
                state = .error
            } else if t.status == .done {
                state = .done
            } else if t.depends.allSatisfy({ byName[$0].map { $0.status == .done } ?? parked[$0]?.done ?? false }) {
                state = .ready
            } else {
                state = .blocked
            }
            result[name] = Node(name: name, state: state, errors: errors[name] ?? [])
        }

        var columns: [Column] = []
        let done = tasks.map(\.name).filter { byName[$0]?.status == .done && !excluded.contains($0) && only?.contains($0) != false }
        if showDone, !done.isEmpty { columns.append(Column(kind: .done, tasks: unique(done))) }
        for (i, w) in waves.enumerated() {
            columns.append(Column(kind: .wave(i + 1, w.priority), tasks: w.tasks))
        }
        let cut = tasks.map(\.name).filter { excluded.contains($0) }
        if !cut.isEmpty { columns.append(Column(kind: .errors, tasks: unique(cut))) }

        let shown = Set(columns.flatMap(\.tasks))
        var edges: [Edge] = []
        var seen: Set<Edge> = []
        for name in columns.flatMap(\.tasks) {
            for d in byName[name]?.depends ?? [] where shown.contains(d) {
                let e = Edge(from: d, to: name)
                if seen.insert(e).inserted { edges.append(e) }
            }
        }
        if only != nil {
            let visible = Set(shown.flatMap { errors[$0] ?? [] })
            messages.removeAll { !visible.contains($0) }
        }
        return Layout(columns: columns, nodes: result, edges: edges, errors: messages)
    }

    static func unique(_ a: [String]) -> [String] {
        var seen: Set<String> = []
        return a.filter { seen.insert($0).inserted }
    }
}

extension TaskGraph.Task {
    public init(_ t: TaskItem) {
        self.init(name: t.fileName, status: t.status, priority: t.priority, depends: t.depends)
    }
}
