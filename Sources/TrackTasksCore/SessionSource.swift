import Foundation

/// Who started a Claude session.
public enum SessionSource: String, CaseIterable, Sendable {
    case mine, app, other

    /// - known: the app started this session (its own list or a queue job).
    /// - entrypoints: `ClaudeSessionInfo.entrypoints`.
    /// - chat: the user started it in the app's chat (side panel), not a background run.
    /// A session of the app continued in the terminal is both `app` and `mine`.
    public static func of(entrypoints: [String], known: Bool, chat: Bool = false, inWorktree: Bool) -> Set<SessionSource> {
        if chat { return [.app, .mine] }
        let typed = entrypoints.contains("cli")
        if known {
            // A fork keeps the lines of its source, so `cli` at the start doesn't mean the user continued it.
            let continued = entrypoints.drop { $0 == "cli" }.contains("cli")
            return continued ? [.app, .mine] : [.app]
        }
        // A worktree the user opened a terminal in: don't hide that session from «Мои».
        if inWorktree { return typed ? [.app, .mine] : [.app] }
        return typed ? [.mine] : [.other]
    }

    public static func isInWorktree(cwd: String, root: String) -> Bool {
        cwd.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// Filter of the sessions screen; raw values are stored in UserDefaults.
public enum SessionFilter: String, CaseIterable, Sendable {
    case all, mine, app, other

    public func matches(_ s: Set<SessionSource>) -> Bool {
        switch self {
        case .all: true
        case .mine: s.contains(.mine)
        case .app: s.contains(.app)
        case .other: s.contains(.other)
        }
    }
}
