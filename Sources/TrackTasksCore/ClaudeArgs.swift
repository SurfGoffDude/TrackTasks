import Foundation

/// Pure pieces of the `claude` command line, kept here so they are covered by tests.
public enum ClaudeArgs {
    /// Isolated run: no user MCP servers, plugins, hooks, user-level settings or slash commands
    /// (checked against claude 2.1.x `--help`).
    public static let isolation = ["--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                                   "--setting-sources", "project,local", "--disable-slash-commands"]

    /// Prefix of an interactive `claude` in a shell: Code Mode on. Only the interactive terminal has it (`-p` ignores
    /// the variable, checked on 2.1.325), and a session started in it is resumed only with it. Sessions started
    /// without it resume as before; a `0` in the user's settings still turns it off.
    public static let codeMode = "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1"

    /// `-p --resume` (a fork too) of a Code Mode session is refused with this text in stderr.
    public static func refusedCodeMode(_ error: String) -> Bool {
        error.contains("session was started in Code Mode")
    }

    /// Full access, or asking over stdio for everything outside the allowed tools.
    public static func permissions(bypass: Bool) -> [String] {
        bypass ? ["--dangerously-skip-permissions"]
            : ["--permission-mode", "acceptEdits", "--permission-prompt-tool", "stdio"]
    }

    /// Full command line of one headless run. The order matters: `--allowedTools` is variadic, so the prompt
    /// goes via stdin, never as a trailing argument. stream-json input keeps stdin open as a control channel:
    /// claude asks for permissions there (`can_use_tool`) and we answer — like the Agent SDK does.
    public static func run(systemPrompt: String, model: String, allowedTools: [String], bypassPermissions: Bool = false,
                           resume: String? = nil, fork: Bool = false, resumeAt: String? = nil, addDirs: [String] = [],
                           isolated: Bool = false, tools: [String]? = nil) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        args += permissions(bypass: bypassPermissions)
        args += ["--allowedTools", allowedTools.joined(separator: ","), "--append-system-prompt", systemPrompt]
        if !model.isEmpty { args += ["--model", model] }
        if let resume { args += ClaudeArgs.resume(resume, fork: fork, at: resumeAt) }
        for d in addDirs { args += ["--add-dir", d] }
        if isolated { args += isolation }
        if let tools { args += ClaudeArgs.tools(tools) }
        return args
    }

    /// `--tools` value: built-in tools available at all. `[]` → `--tools ""` (no tools, checked on 2.1.325).
    public static func tools(_ names: [String]) -> [String] {
        ["--tools", names.joined(separator: ",")]
    }
}

/// Fork of a Claude session: `claude --resume <id> --fork-session` continues the history under a new id,
/// the original session file is not touched (checked on claude 2.1.x, also from another folder).
extension ClaudeArgs {
    /// `at`: uuid of the last message to keep; later ones are left out of the new session. The flag is hidden
    /// in `--help`; checked on 2.1.325: the source jsonl stays byte-identical, an unknown uuid is an error.
    public static func resume(_ id: String, fork: Bool, at point: String? = nil) -> [String] {
        ["--resume", id] + (fork ? ["--fork-session"] : []) + (point.map { ["--resume-session-at", $0] } ?? [])
    }
}

/// Links between a session and its forks. Claude's own files don't record the parent, so the app keeps it.
public enum SessionFork {
    /// A fork started in the terminal: its new id is unknown until the CLI writes the file.
    public struct Pending: Codable, Hashable, Sendable {
        public var parent: String
        public var cwd: String
        public var firstPrompt: String
        public var at: Date
        public init(parent: String, cwd: String, firstPrompt: String, at: Date) {
            self.parent = parent; self.cwd = cwd; self.firstPrompt = firstPrompt; self.at = at
        }
    }

    /// The session that appeared after `p.at` in the same folder with the history copied from the parent
    /// (same first prompt). `taken` are ids already linked or the parent itself. Earliest start wins.
    public static func match(_ p: Pending, in sessions: [ClaudeSessionInfo], taken: Set<String>) -> ClaudeSessionInfo? {
        sessions
            .filter { $0.id != p.parent && !taken.contains($0.id) && $0.cwd == p.cwd
                && $0.firstPrompt == p.firstPrompt && $0.updated >= p.at }
            .min { $0.started < $1.started }
    }
}
