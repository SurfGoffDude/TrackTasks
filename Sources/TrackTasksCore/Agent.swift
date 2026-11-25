import Foundation

// The queue talks to coding agents only through these types; everything about a particular CLI
// (flags, event format, permission payloads) stays inside its adapter.

/// Kind of agent, e.g. `claude`. Stored in queue.json.
public struct AgentID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let claude = AgentID(rawValue: "claude")
    public static let codex = AgentID(rawValue: "codex")
    /// Claude on a server over SSH.
    public static let ssh = AgentID(rawValue: "ssh")
    /// Any CLI that speaks the Agent Client Protocol.
    public static let acp = AgentID(rawValue: "acp")
}

/// What the agent can do. The queue and UI don't offer the rest.
public struct AgentCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Continue an earlier session in the same folder.
    public static let resume = AgentCapabilities(rawValue: 1)
    /// Continue a copy of a session; the source stays as it is.
    public static let fork = AgentCapabilities(rawValue: 1 << 1)
    /// Fork from an earlier message of the session.
    public static let resumeAt = AgentCapabilities(rawValue: 1 << 2)
    /// Asks before using tools that aren't pre-approved.
    public static let permissions = AgentCapabilities(rawValue: 1 << 3)
    /// Can run without the user's own plugins and settings.
    public static let isolation = AgentCapabilities(rawValue: 1 << 4)
    /// Model of a task is picked by the tracker (heuristic, then a cheap model): Claude's model names.
    public static let autoModel = AgentCapabilities(rawValue: 1 << 5)
    /// Reports what a run cost.
    public static let cost = AgentCapabilities(rawValue: 1 << 6)
    /// Spends the subscription limit that the queue's limit guard watches.
    public static let guardedLimit = AgentCapabilities(rawValue: 1 << 7)
    /// May run without any permission checks when the user turned that on in Settings.
    public static let bypass = AgentCapabilities(rawValue: 1 << 8)
    /// A restriction: edits code only in a worktree, never in the main folder.
    public static let requiresWorktree = AgentCapabilities(rawValue: 1 << 9)
    /// Works on a server: needs `AgentRequest.remote`.
    public static let remote = AgentCapabilities(rawValue: 1 << 10)
    /// Can run in a container (`executor: docker`).
    public static let container = AgentCapabilities(rawValue: 1 << 11)
    /// Takes images with the prompt. Others get a path to the file.
    public static let images = AgentCapabilities(rawValue: 1 << 12)
}

public enum AgentEvent: Equatable, Sendable {
    case text(String)
    case tool(String)
}

/// What the run may touch.
public enum AgentAccess: Sendable {
    /// Read the project, write only tracker files (the prompt says which).
    case planning
    /// Edit code too.
    case coding
    /// One short text answer, no tools.
    case answer
}

/// The agent asks to use a tool that isn't pre-approved. The raw request stays in the adapter, found by `id`.
public struct AgentPermission: Identifiable, Equatable, Sendable {
    public let id: String
    public let tool: String
    /// Main line shown to the user: the command, the file, or the tool name.
    public let title: String
    public let note: String
    /// What "always allow" would add, e.g. `Bash(npm run build:*)`; empty = not offered.
    public let ruleText: String

    public init(id: String, tool: String, title: String, note: String = "", ruleText: String = "") {
        self.id = id
        self.tool = tool
        self.title = title
        self.note = note
        self.ruleText = ruleText
    }
}

public struct AgentRequest: Sendable {
    public var cwd: URL
    public var prompt: String
    public var systemPrompt: String
    /// Model name as the agent knows it; empty = its default.
    public var model: String
    public var access: AgentAccess
    public var resume: String?
    /// With `resume`: continue the history in a new session; the resumed one stays as it is.
    public var fork: Bool
    /// With `fork`: keep the history only up to this message.
    public var resumeAt: String?
    public var bypassPermissions: Bool
    /// Extra folders the agent may edit outside cwd.
    public var addDirs: [URL]
    public var isolated: Bool
    public var remote: AgentRemote?
    /// Only for `AgentID.acp`.
    public var acp: ACPCommand?
    /// PNG. Only for agents with `.images`.
    public var images: [Data]

    public init(cwd: URL, prompt: String, systemPrompt: String = "", model: String = "", access: AgentAccess,
                resume: String? = nil, fork: Bool = false, resumeAt: String? = nil, bypassPermissions: Bool = false,
                addDirs: [URL] = [], isolated: Bool = false, remote: AgentRemote? = nil, acp: ACPCommand? = nil, images: [Data] = []) {
        self.cwd = cwd
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.model = model
        self.access = access
        self.resume = resume
        self.fork = fork
        self.resumeAt = resumeAt
        self.bypassPermissions = bypassPermissions
        self.addDirs = addDirs
        self.isolated = isolated
        self.remote = remote
        self.acp = acp
        self.images = images
    }
}

/// How one run ended.
public struct AgentRunResult: Sendable {
    public var sessionID: String?
    /// nil = the agent didn't report it: «нет данных», not zero.
    public var costUSD: Double?
    public var durationMs = 0
    /// Uncached input tokens (full price).
    public var inputTokens = 0
    /// Input written to the prompt cache (≈1.25–2× price) and read from it (≈0.1× price).
    public var cacheWriteTokens = 0
    public var cacheReadTokens = 0
    public var outputTokens = 0
    public var turns = 0
    public var isError = false
    public var gotResult = false
    /// Nothing was started (no login, wrong version): a new session wouldn't help.
    public var cannotStart = false
    /// The subscription limit refused the run (the agent's own record, never its text).
    public var limit: RunLimit?
    public var resultText = ""
    public var exitCode: Int32 = 0
    public var stopped = false
    public var stderr = ""
    /// Actual model id, e.g. "claude-sonnet-5-5".
    public var model = ""
    /// MCP servers and `mcp__*` tools loaded into the session.
    public var mcpServers = 0
    public var mcpTools = 0
    /// Program name for error messages.
    public var program: String

    public init(sessionID: String? = nil, program: String = "claude") {
        self.sessionID = sessionID
        self.program = program
    }

    /// Everything the model read: uncached + cache write + cache read.
    public var totalInput: Int { inputTokens + cacheWriteTokens + cacheReadTokens }

    public var failed: Bool { !stopped && (isError || (exitCode != 0 && !gotResult)) }

    public var errorText: String {
        if isError, !resultText.isEmpty { return resultText }
        let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if turns == 0, ClaudeArgs.refusedCodeMode(tail) { return "Сессия Code Mode: продолжить её можно только в терминале" }
        return tail.isEmpty ? "\(program) завершился с кодом \(exitCode)" : String(tail.suffix(800))
    }

    public var summary: String {
        var parts: [String] = []
        if let costUSD {
            if costUSD > 0 { parts.append(String(format: "$%.3f", costUSD)) }
        } else if totalInput + outputTokens > 0 {
            parts.append("стоимость: \(AgentCost.noData)")
        }
        if durationMs > 0 { parts.append(Self.duration(durationMs)) }
        if totalInput + outputTokens > 0 {
            var t = "\(Self.k(totalInput)) → \(Self.k(outputTokens)) ток."
            if cacheReadTokens > 0 { t += " (из кеша \(Int((Double(cacheReadTokens) / Double(totalInput) * 100).rounded()))%)" }
            parts.append(t)
        }
        if turns > 0 { parts.append("шагов: \(turns)") }
        return parts.joined(separator: " · ")
    }

    /// "$0.10 · 1 мин" + "$0.02 · 9 с" → "$0.12 · …" (keeps it simple: newest wins, cost summed by caller).
    public static func combine(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : (b.isEmpty ? a : b)
    }

    public static func k(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    public static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        return s >= 60 ? "\(s / 60) мин \(s % 60) с" : "\(s) с"
    }
}

/// Sum of run costs, some of which may be unknown.
public struct AgentCost: Codable, Equatable, Sendable {
    public static let noData = "нет данных"

    /// Known part.
    public var usd: Double
    /// At least one run didn't report its cost.
    public var unknown: Bool

    public init(usd: Double = 0, unknown: Bool = false) {
        self.usd = usd
        self.unknown = unknown
    }

    public mutating func add(_ cost: Double?) {
        if let cost { usd += cost } else { unknown = true }
    }

    public static func + (a: AgentCost, b: AgentCost) -> AgentCost {
        AgentCost(usd: a.usd + b.usd, unknown: a.unknown || b.unknown)
    }

    /// "$0.123", "≥ $0.123" (part is unknown), «нет данных»; nil = nothing was spent.
    public func text(digits: Int = 2) -> String? {
        guard usd > 0 else { return unknown ? Self.noData : nil }
        return (unknown ? "≥ " : "") + String(format: "$%.\(digits)f", usd)
    }
}

/// One run of an agent: one prompt, one process.
@MainActor
public protocol AgentRun: AnyObject {
    var onEvent: ((AgentEvent) -> Void)? { get set }
    var onExit: ((AgentRunResult) -> Void)? { get set }
    /// Tool use needing approval. nil = everything that isn't pre-approved is denied.
    var onPermission: ((AgentPermission) -> Void)? { get set }
    /// The agent itself said that it has the prompt and the turn goes on; may come more than once.
    /// Never from the start of the process, a container or a connection.
    var onTurnStarted: (() -> Void)? { get set }

    func start(_ request: AgentRequest) throws
    /// `always`: also remember the suggested rule for the project.
    func respond(_ permission: AgentPermission, allow: Bool, always: Bool)
    /// `onExit` follows with `stopped`.
    func stop()
    /// Kill the agent together with every command it started.
    func killTree()
}

@MainActor
public protocol Agent {
    var id: AgentID { get }
    var title: String { get }
    var capabilities: AgentCapabilities { get }
    func makeRun() -> any AgentRun
}

/// Agents this build knows.
@MainActor
public struct AgentRegistry {
    public let all: [any Agent]
    public init(_ all: [any Agent]) { self.all = all }

    public subscript(id: AgentID) -> (any Agent)? { all.first { $0.id == id } }
}

/// Named choice for a task (`agent:` in its frontmatter): which agent and, optionally, which model.
/// A profile never widens what the agent may do.
public struct AgentProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var agent: AgentID
    /// Empty = the agent's usual choice.
    public var model: String
    /// Only for `AgentID.ssh`. Optional: older profiles don't have it.
    public var server: RemoteServer?
    /// Only for `AgentID.acp`. Optional: older profiles don't have it.
    public var acp: ACPCommand?

    public init(id: String, title: String, agent: AgentID, model: String = "", server: RemoteServer? = nil, acp: ACPCommand? = nil) {
        self.server = server
        self.acp = acp
        self.id = id
        self.title = title
        self.agent = agent
        self.model = model
    }

    public static let claude = AgentProfile(id: "claude", title: "Claude", agent: .claude)

    /// A server is used only where the task names it: a default would send about.md updates and quick tasks there too.
    /// An ACP agent works only in a worktree, and those have none.
    public var canBeDefault: Bool { agent != .ssh && agent != .acp }

    /// Value allowed in `agent:`.
    public static func isValidID(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9][a-z0-9._-]{0,39}$"#, options: .regularExpression) != nil
    }
}

public struct AgentProfiles: Codable, Equatable, Sendable {
    /// User's profiles; the built-in `claude` is always there.
    public var custom: [AgentProfile]
    public var defaultID: String

    public init(custom: [AgentProfile] = [], defaultID: String = AgentProfile.claude.id) {
        self.custom = custom
        self.defaultID = defaultID
    }

    public var all: [AgentProfile] { [.claude] + custom.filter { $0.id != AgentProfile.claude.id } }

    /// Empty name = the default profile. nil = no such profile: the caller must report it, not fall back.
    public func resolve(_ name: String) -> AgentProfile? {
        let key = name.isEmpty ? defaultID : name
        return all.first { $0.id == key && (!name.isEmpty || $0.canBeDefault) }
    }

    /// nil = added.
    public mutating func add(_ p: AgentProfile) -> String? {
        guard AgentProfile.isValidID(p.id) else { return "Имя: строчные латинские буквы, цифры, «.», «_», «-»" }
        guard !all.contains(where: { $0.id == p.id }) else { return "Профиль «\(p.id)» уже есть" }
        if p.agent == .ssh, let e = p.server.map(\.problem) ?? "Укажи сервер" { return e }
        if p.agent == .acp, let e = p.acp.map(\.problem) ?? "Укажи команду ACP-агента" { return e }
        custom.append(p)
        return nil
    }

    public mutating func remove(_ id: String) {
        custom.removeAll { $0.id == id }
        if resolve("") == nil { defaultID = AgentProfile.claude.id }
    }
}
