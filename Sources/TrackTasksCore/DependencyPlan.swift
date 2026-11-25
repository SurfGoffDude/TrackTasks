import Foundation

/// Resolves `depends:` of tasks into a queue order: dependencies first (topological sort),
/// detecting cycles and references to task files that don't exist.
public enum DependencyPlan {
    public struct Node: Sendable, Equatable {
        public var done: Bool
        public var depends: [String]
        /// Lies in the archive or drafts: may be depended on, but is never queued.
        public var parked: TaskFolder?
        public init(done: Bool, depends: [String], parked: TaskFolder? = nil) {
            self.parked = parked
            self.done = done
            self.depends = depends
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// File names forming the cycle, first one repeated at the end: A → B → A.
        case cycle([String])
        /// `task` depends on `dependency`, which is not among the project's tasks.
        case missing(task: String, dependency: String)
        /// `dependency` is an unfinished task of the archive or a draft.
        case parked(task: String, dependency: String, folder: TaskFolder)

        public var message: String {
            switch self {
            case .cycle(let path): "Цикл в depends: " + path.joined(separator: " → ")
            case .missing(let t, let d): "\(t) зависит от несуществующей задачи \(d)"
            case .parked(let t, let d, let f):
                f == .drafts ? "\(t) зависит от черновика \(d)" : "\(t) зависит от невыполненной задачи из архива \(d)"
            }
        }
    }

    /// Names of tasks that count as done for their dependents; on a name clash the active task is meant.
    static func satisfied(_ active: [TaskItem], _ parked: [TaskItem]) -> Set<String> {
        let all = Dictionary((active + parked).map { ($0.fileName, $0.satisfiesDepends) }, uniquingKeysWith: { a, _ in a })
        return Set(all.filter(\.value).keys)
    }

    /// File names to enqueue, each after all of its unfinished dependencies.
    /// - `targets`: tasks the user asked to run, in the wished order (kept where depends allow).
    /// - `nodes`: all tasks of the project by file name.
    /// - `queued`: tasks already in the queue — neither added nor traversed (their depends were resolved then).
    /// Done tasks are skipped and not traversed. Unfinished dependencies not in `targets` are added.
    public static func order(targets: [String], nodes: [String: Node],
                             queued: Set<String> = []) -> Result<[String], Failure> {
        var result: [String] = []
        var finished: Set<String> = []
        var stack: [String] = []

        func visit(_ name: String) -> Failure? {
            if finished.contains(name) { return nil }
            if let i = stack.firstIndex(of: name) { return .cycle(Array(stack[i...]) + [name]) }
            guard let node = nodes[name], !node.done, node.parked == nil, !queued.contains(name) else {
                finished.insert(name)
                return nil
            }
            stack.append(name)
            for d in node.depends {
                guard let dep = nodes[d] else { return .missing(task: name, dependency: d) }
                if let f = dep.parked, !dep.done { return .parked(task: name, dependency: d, folder: f) }
                if let f = visit(d) { return f }
            }
            stack.removeLast()
            finished.insert(name)
            result.append(name)
            return nil
        }

        for t in targets {
            if let f = visit(t) { return .failure(f) }
        }
        return .success(result)
    }
}
