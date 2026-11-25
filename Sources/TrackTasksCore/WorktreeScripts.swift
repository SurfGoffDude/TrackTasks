import Foundation

/// `setup:` / `teardown:` from about.md: shell commands run in a job's worktree after it is created / before it is removed.
/// A project's command is code from the project's folder, so a person approves it first (and again after every change).
public struct WorktreeScripts: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case setup, teardown
        public var title: String { self == .setup ? "setup" : "teardown" }
    }

    public var setup: String
    public var teardown: String
    public init(setup: String = "", teardown: String = "") {
        self.setup = setup
        self.teardown = teardown
    }

    public var isEmpty: Bool { setup.isEmpty && teardown.isEmpty }

    public func command(_ kind: Kind) -> String { kind == .setup ? setup : teardown }

    /// From frontmatter fields of about.md. Surrounding quotes are dropped; a blank value means «none».
    public static func parse(_ fields: [String: String]) -> WorktreeScripts {
        WorktreeScripts(setup: clean(fields["setup"]), teardown: clean(fields["teardown"]))
    }

    static func clean(_ v: String?) -> String {
        var s = (v ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let f = s.first, f == s.last, f == "\"" || f == "'" {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Scripts of the project in `url` (about.md); empty when there is no file or fields.
    public static func load(projectAt url: URL) -> WorktreeScripts {
        guard let text = try? String(contentsOf: url.appendingPathComponent("about.md"), encoding: .utf8) else { return WorktreeScripts() }
        return parse(Frontmatter.parse(text).fields)
    }

    /// Last lines of the output for the job log (the tail is where the error is).
    public static func tail(_ text: String, limit: Int = 4000) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? "…\n" + String(t.suffix(limit)) : t
    }
}

/// Commands a person has already approved, per project. A command counts as approved only while it is
/// exactly the approved text: any edit asks again.
public struct ScriptApprovals: Codable, Equatable, Sendable {
    public var byProject: [String: [String: String]] = [:]
    public init() {}

    static func key(_ project: URL) -> String { project.standardizedFileURL.path }

    /// An empty command runs nothing, so there is nothing to approve.
    public func isApproved(_ kind: WorktreeScripts.Kind, _ command: String, project: URL) -> Bool {
        command.isEmpty || byProject[Self.key(project)]?[kind.rawValue] == command
    }

    /// Commands of `scripts` that are not approved yet.
    public func pending(_ scripts: WorktreeScripts, project: URL) -> [(kind: WorktreeScripts.Kind, command: String)] {
        WorktreeScripts.Kind.allCases.compactMap { k in
            let c = scripts.command(k)
            return isApproved(k, c, project: project) ? nil : (k, c)
        }
    }

    public mutating func approve(_ scripts: WorktreeScripts, project: URL) {
        var m = byProject[Self.key(project)] ?? [:]
        for k in WorktreeScripts.Kind.allCases {
            let c = scripts.command(k)
            if c.isEmpty { m[k.rawValue] = nil } else { m[k.rawValue] = c }
        }
        byProject[Self.key(project)] = m
    }
}

extension ScriptApprovals {
    static let runKey = "run"

    /// `run:` of about.md (the whole field text) is approved like setup: by exact text, per project.
    public func isRunApproved(_ field: String, project: URL) -> Bool {
        field.isEmpty || byProject[Self.key(project)]?[Self.runKey] == field
    }

    public mutating func approveRun(_ field: String, project: URL) {
        var m = byProject[Self.key(project)] ?? [:]
        m[Self.runKey] = field.isEmpty ? nil : field
        byProject[Self.key(project)] = m
    }
}
