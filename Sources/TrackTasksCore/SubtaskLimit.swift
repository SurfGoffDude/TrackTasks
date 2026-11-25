import Foundation

/// How many subtasks an agent may create through MCP. Closed, archived and draft tasks count too:
/// otherwise closing a subtask would free its place.
enum SubtaskLimit {
    /// Levels below the root task.
    static let depth = 2
    static let children = 10
    /// The whole tree without its root.
    static let tree = 30

    /// On a name clash the first one (an active task) is meant.
    static func parents(_ tasks: [(file: String, parent: String)]) -> [String: String] {
        Dictionary(tasks.map { ($0.file, $0.parent) }, uniquingKeysWith: { a, _ in a })
    }

    /// Text for the linter, nil when the chain of parents ends at a root.
    static func parentProblem(_ file: String, _ parents: [String: String]) -> String? {
        guard let parent = parents[file], !parent.isEmpty else { return nil }
        if parent == file { return "parent ссылается на саму задачу: \(file)" }
        guard parents[parent] != nil else { return "parent: нет файла \(parent)" }
        return isCycle(file, parents) ? "parent: цикл через \(parent)" : nil
    }

    /// Throws when one more subtask of `parent` does not fit.
    static func check(parent: String, _ tasks: [(file: String, parent: String)]) throws {
        let map = parents(tasks)
        guard let up = chain(parent, map) else {
            throw CLIError.invalid("у \(parent) битая цепочка parent или цикл: подзадачу создать нельзя")
        }
        guard up.count <= depth else {
            throw CLIError.invalid("лимит подзадач: глубина больше \(depth) уровней под корневой задачей")
        }
        guard tasks.filter({ $0.parent == parent }).count < children else {
            throw CLIError.invalid("лимит подзадач: у \(parent) уже \(children)")
        }
        let root = up[up.count - 1]
        guard tasks.filter({ $0.file != root && chain($0.file, map)?.last == root }).count < tree else {
            throw CLIError.invalid("лимит подзадач: в дереве \(root) уже \(tree)")
        }
    }

    /// From the task to its root, both included; nil for a missing link or a cycle.
    private static func chain(_ file: String, _ parents: [String: String]) -> [String]? {
        var out: [String] = []
        var seen = Set<String>()
        var cur = file
        while true {
            guard let next = parents[cur], seen.insert(cur).inserted else { return nil }
            out.append(cur)
            if next.isEmpty { return out }
            cur = next
        }
    }

    private static func isCycle(_ file: String, _ parents: [String: String]) -> Bool {
        var seen = Set<String>()
        var cur = file
        while let next = parents[cur], !next.isEmpty {
            if !seen.insert(cur).inserted { return true }
            cur = next
        }
        return false
    }
}
