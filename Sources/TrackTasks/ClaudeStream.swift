import Foundation
import TrackTasksCore

/// `can_use_tool` control request as claude sent it: the answer returns its parts.
private struct ClaudePermission {
    let tool: String
    let input: [String: Any]
    let suggestions: [Any]

    func shown(id: String, note: String) -> AgentPermission {
        AgentPermission(id: id, tool: tool, title: title, note: note, ruleText: ruleText)
    }

    /// Main line shown to the user: the command, the file, or the tool name.
    var title: String {
        switch tool {
        case "Bash": return input["command"] as? String ?? "Bash"
        case "Write", "Edit", "MultiEdit", "Read", "NotebookEdit":
            return "\(tool): \(input["file_path"] as? String ?? input["notebook_path"] as? String ?? "")"
        case "WebFetch": return "WebFetch: \(input["url"] as? String ?? "")"
        case "WebSearch": return "WebSearch: \(input["query"] as? String ?? "")"
        default:
            let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return "\(tool) \(json.prefix(300))"
        }
    }

    /// What "always allow" would add, e.g. `Bash(npm run build:*)`.
    var ruleText: String {
        let rules = suggestions.compactMap { $0 as? [String: Any] }
            .filter { $0["type"] as? String == "addRules" }
            .flatMap { ($0["rules"] as? [[String: Any]]) ?? [] }
            .map { r in
                let name = r["toolName"] as? String ?? tool
                return (r["ruleContent"] as? String).map { "\(name)(\($0))" } ?? name
            }
        return rules.joined(separator: ", ")
    }
}

/// Tool calls in full, for the chat: `AgentEvent.tool` is only a line of the log.
enum ClaudeToolEvent {
    case started(ChatToolCall, title: String)
    case finished(id: String, result: String, failed: Bool)
}

/// How full the model's context is.
struct ClaudeContext: Equatable {
    var tokens: Int
    /// Known after the first result.
    var window: Int?
}

/// Claude's stream-json output without the process: events, permission requests, the result of the run.
@MainActor
final class ClaudeStream {
    var onEvent: ((AgentEvent) -> Void)?
    /// The same calls as `.tool` of `onEvent`, with their results.
    var onTool: ((ClaudeToolEvent) -> Void)?
    var onContext: ((ClaudeContext) -> Void)?
    /// Last message of the model itself (not of a subagent): where a branch of the session may start.
    private(set) var point: String?
    private var context: ClaudeContext?
    private var contextModel = ""
    /// Always answered through `answer`.
    var onPermission: ((AgentPermission) -> Void)?
    /// A message for claude.
    var onSend: (([String: Any]) -> Void)?
    var onResult: (() -> Void)?
    var onSession: ((String) -> Void)?
    /// The model answers: the prompt is in the session. `init` isn't enough, a refused run has it too.
    var onTurnStarted: (() -> Void)?
    var onLimits: (([String: Any]) -> Void)?
    /// After each whole line.
    var onLine: (() -> Void)?

    var stats: AgentRunResult
    /// Bytes of whole lines read so far.
    private(set) var consumed = 0
    private var buffer = Data()
    /// The last `rate_limit_info` of this run, nil = not a refusal.
    private var refusal: RunLimit?
    /// Source of a fork: its id may come before (or instead of) the new one and isn't ours.
    private let forkSource: String?
    private let cwd: String
    /// Unanswered permission requests by id.
    private var asked: [String: ClaudePermission] = [:]

    init(resume: String? = nil, fork: Bool = false, cwd: String = "/") {
        self.cwd = cwd
        forkSource = fork ? resume : nil
        stats = AgentRunResult(sessionID: fork ? nil : resume)
    }

    /// First messages of a run.
    nonisolated static func opening(prompt: String, images: [Data] = []) -> [[String: Any]] {
        let blocks: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": $0.base64EncodedString()]]
        }
        let content: Any = images.isEmpty ? prompt : blocks + [["type": "text", "text": prompt]]
        return [["type": "control_request", "request_id": "init", "request": ["subtype": "initialize"]],
         ["type": "user", "session_id": "", "parent_tool_use_id": NSNull(),
          "message": ["role": "user", "content": content]]]
    }

    /// nil: there is no such request (any more).
    func answer(_ id: String, allow: Bool, always: Bool) -> [String: Any]? {
        guard let raw = asked.removeValue(forKey: id) else { return nil }
        var answer: [String: Any]
        if allow {
            answer = ["behavior": "allow", "updatedInput": raw.input]
            if always, !raw.suggestions.isEmpty { answer["updatedPermissions"] = raw.suggestions }
        } else {
            answer = ["behavior": "deny", "message": "Пользователь отклонил это действие. Не повторяй его; продолжай без него или объясни, что нужно сделать вручную."]
        }
        return ["type": "control_response",
                "response": ["subtype": "success", "request_id": id, "response": answer]]
    }

    func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            consumed += line.count + 1
            if !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(obj) }
            onLine?()
        }
    }

    private func handle(_ obj: [String: Any]) {
        if let s = obj["session_id"] as? String {
            stats.sessionID = s
            if s != forkSource { onSession?(s) }
        }
        switch obj["type"] as? String {
        case "system":
            if obj["subtype"] as? String == "init" {
                if let m = obj["model"] as? String { stats.model = m }
                let servers = (obj["mcp_servers"] as? [Any])?.count ?? 0
                let mcpTools = (obj["tools"] as? [String])?.filter { $0.hasPrefix("mcp__") }.count ?? 0
                stats.mcpServers = servers
                stats.mcpTools = mcpTools
            }
        case "assistant":
            guard let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return }
            // Errors (API, limit) come as messages of a "<synthetic>" model.
            if let model = msg["model"] as? String, model != "<synthetic>", obj["error"] == nil {
                onTurnStarted?()
                if !(obj["parent_tool_use_id"] is String) { answered(msg, model: model, uuid: obj["uuid"] as? String) }
            }
            for c in content {
                switch c["type"] as? String {
                case "text":
                    if let t = c["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onEvent?(.text(t))
                    }
                case "tool_use":
                    let name = c["name"] as? String ?? "tool", input = c["input"] as? [String: Any] ?? [:]
                    let title = describe(tool: name, input: input)
                    onEvent?(.tool(title))
                    if let onTool, let id = c["id"] as? String {
                        onTool(.started(ChatToolCall(id: id, name: name, detail: ChatToolCall.detail(tool: name, input: input),
                                                     parent: obj["parent_tool_use_id"] as? String),
                                        title: ChatToolCall.clean(title, limit: 300)))
                    }
                default: break
                }
            }
        case "user":
            guard let onTool, let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            for c in content where c["type"] as? String == "tool_result" {
                guard let id = c["tool_use_id"] as? String else { continue }
                onTool(.finished(id: id, result: ChatToolCall.result(c["content"]), failed: c["is_error"] as? Bool == true))
            }
        case "result":
            if var c = context, let all = obj["modelUsage"] as? [String: [String: Any]],
               let w = (all[contextModel] ?? all[stats.model] ?? (all.count == 1 ? all.first?.value : nil))?["contextWindow"] as? Int {
                c.window = w
                context = c
                onContext?(c)
            }
            // One prompt per process: closing stdin lets claude exit.
            onResult?()
            stats.gotResult = true
            stats.isError = (obj["is_error"] as? Bool) == true
            stats.resultText = obj["result"] as? String ?? ""
            // Both must agree: a 429 alone may be a server throttle, a refusal alone may be something the turn got over.
            stats.limit = stats.isError && obj["api_error_status"] as? Int == 429 ? refusal : nil
            stats.costUSD = obj["total_cost_usd"] as? Double
            stats.durationMs = obj["duration_ms"] as? Int ?? 0
            stats.turns = obj["num_turns"] as? Int ?? 0
            if let u = obj["usage"] as? [String: Any] {
                stats.inputTokens = u["input_tokens"] as? Int ?? 0
                stats.cacheWriteTokens = u["cache_creation_input_tokens"] as? Int ?? 0
                stats.cacheReadTokens = u["cache_read_input_tokens"] as? Int ?? 0
                stats.outputTokens = u["output_tokens"] as? Int ?? 0
            }
        case "control_request":
            guard let rid = obj["request_id"] as? String, let req = obj["request"] as? [String: Any] else { return }
            if req["subtype"] as? String == "can_use_tool" {
                let raw = ClaudePermission(
                    tool: req["tool_name"] as? String ?? "tool",
                    input: req["input"] as? [String: Any] ?? [:],
                    suggestions: req["permission_suggestions"] as? [Any] ?? [])
                asked[rid] = raw
                let r = raw.shown(id: rid, note: req["description"] as? String ?? "")
                onPermission?(r)
            } else {
                onSend?(["type": "control_response",
                      "response": ["subtype": "error", "request_id": rid, "error": "unsupported"]])
            }
        case "rate_limit_event":
            guard let info = obj["rate_limit_info"] as? [String: Any] else { return }
            // A subagent may be refused while the turn goes on.
            if !(obj["parent_tool_use_id"] is String) { refusal = RunLimit(claude: info) }
            onLimits?(info)
        default: break
        }
    }

    private func answered(_ msg: [String: Any], model: String, uuid: String?) {
        if let uuid { point = uuid }
        guard let u = msg["usage"] as? [String: Any] else { return }
        let n = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (u[$1] as? Int ?? 0) }
        guard n > 0 else { return }
        contextModel = model
        let c = ClaudeContext(tokens: n, window: context?.window)
        guard c != context else { return }
        context = c
        onContext?(c)
    }

    private func describe(tool: String, input: [String: Any]) -> String {
        func rel(_ p: String) -> String {
            p.hasPrefix(cwd + "/") ? String(p.dropFirst(cwd.count + 1)) : p
        }
        let file = rel(input["file_path"] as? String ?? "")
        switch tool {
        case "Write": return "Создаёт \(file)"
        case "Edit", "MultiEdit": return "Правит \(file)"
        case "Read": return "Читает \(file)"
        case "Glob": return "Ищет файлы \(input["pattern"] as? String ?? "")"
        case "Grep": return "Ищет «\(input["pattern"] as? String ?? "")»"
        case "Bash": return "$ \(input["command"] as? String ?? "")"
        case "TodoWrite": return "Планирует шаги"
        default: return tool
        }
    }
}
