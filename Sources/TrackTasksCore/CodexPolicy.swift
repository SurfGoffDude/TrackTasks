import Darwin
import Foundation

/// What a Codex run may do without asking. Never wider than Claude's pre-approved tools: edit files in its
/// folders; every command outside Codex's own list of read-only ones is asked about (`untrusted`).
public struct CodexPolicy: Sendable {
    public let access: AgentAccess
    public let cwd: URL
    public let addDirs: [URL]

    public init(access: AgentAccess, cwd: URL, addDirs: [URL] = []) {
        self.access = access
        self.cwd = cwd
        self.addDirs = addDirs
    }

    public static let approvalPolicy = "untrusted"

    /// For `thread/start` and `thread/resume`.
    public var sandboxMode: String { access == .coding ? "workspace-write" : "read-only" }
    /// `type` the server must report back.
    public var sandboxType: String { access == .coding ? "workspaceWrite" : "readOnly" }

    /// For `turn/start`.
    public var sandbox: [String: Any] {
        guard access == .coding else { return ["type": "readOnly", "networkAccess": false] }
        // cwd isn't writable by itself (checked with 0.162 `command/exec`).
        return ["type": "workspaceWrite", "writableRoots": ([cwd] + addDirs).map(\.path), "networkAccess": false,
                "excludeTmpdirEnvVar": true, "excludeSlashTmp": true]
    }

    /// Nothing of the user's that runs outside the sandbox: MCP servers, apps, plugins, hooks, browser.
    public func config(mcpServers: [String]) -> [String: Any] {
        var c: [String: Any] = ["web_search": "disabled"]
        let off = ["apps", "plugins", "remote_plugin", "hooks", "browser_use", "browser_use_external", "in_app_browser",
                   "computer_use", "multi_agent", "image_generation", "memories", "goals", "request_permissions_tool"]
        c["features"] = Dictionary(uniqueKeysWithValues: off.map { ($0, false) })
        if !mcpServers.isEmpty {
            c["mcp_servers"] = Dictionary(uniqueKeysWithValues: mcpServers.map { ($0, ["enabled": false]) })
        }
        return c
    }

    public enum Edit: Equatable, Sendable { case allow, ask, deny }

    /// All paths of one change must be fine, otherwise the user decides.
    public func edit(_ paths: [String]) -> Edit {
        if access == .answer { return .deny }
        return !paths.isEmpty && paths.allSatisfy(mayEdit) ? .allow : .ask
    }

    private func mayEdit(_ path: String) -> Bool {
        let full = path.hasPrefix("/") ? path : cwd.path + "/" + path
        guard let target = Self.real(full), let root = Self.real(cwd.path) else { return false }
        func inside(_ dir: String) -> Bool { target.hasPrefix(dir + "/") }
        if addDirs.compactMap({ Self.real($0.path) }).contains(where: inside) { return true }
        guard inside(root) else { return false }
        let rel = target.dropFirst(root.count + 1)
        switch access {
        case .answer: return false
        case .planning: return rel.hasPrefix("tasks/") || rel == "about.md" || rel == "spectrack.md"
        // Git internals and agents' own settings are not code.
        case .coding: return !rel.lowercased().split(separator: "/").contains { [".git", ".codex", ".agents", ".claude"].contains($0) }
        }
    }

    /// Absolute path with `..` and symlinks resolved; the tail may not exist yet. nil = can't be trusted (dangling link).
    static func real(_ path: String) -> String? {
        var out = ""
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                out = (out as NSString).deletingLastPathComponent
                if out == "/" { out = "" }
                continue
            }
            let next = out + "/" + part
            var st = stat()
            if lstat(next, &st) != 0 {
                if errno != ENOENT { return nil }
                out = next
            } else if let r = realpath(next, nil) {
                out = String(cString: r)
                free(r)
                if out == "/" { out = "" }
            } else {
                return nil
            }
        }
        return out.isEmpty ? "/" : out
    }
}
