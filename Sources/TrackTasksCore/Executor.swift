import Foundation

/// Where the agent's process runs: `executor:` in about.md and in a task.
public enum Executor: String, Codable, Sendable, CaseIterable {
    case local, docker

    public enum Choice: Equatable, Sendable {
        case use(Executor)
        /// Unknown value: the caller must report it, never run locally instead.
        case invalid(String)
    }

    /// A task may ask for the container, but can't weaken the project's `docker` to `local`.
    public static func resolve(project: String, task: String) -> Choice {
        var result = Executor.local
        for value in [project, task] where !value.isEmpty {
            guard let e = Executor(rawValue: value) else { return .invalid(value) }
            if e == .docker { result = .docker }
        }
        return .use(result)
    }

    public static func resolve(projectAt url: URL, task: URL?) -> Choice {
        func value(_ u: URL) -> String {
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { return "" }
            return Frontmatter.word(Frontmatter.parse(text).fields["executor"])
        }
        return resolve(project: value(url.appendingPathComponent("about.md")), task: task.map(value) ?? "")
    }
}
