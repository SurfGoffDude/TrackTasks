import Foundation

/// One turn over `codex app-server` (JSON lines on stdio): what to send and what each received line means.
/// No processes here. Field names are from the schema of codex 0.162 (`app-server generate-ts`).
public struct CodexSession {
    public enum Action {
        case send([String: Any])
        case event(AgentEvent)
        case permission(AgentPermission)
        /// The id of the session is known.
        case started(String)
        /// Nothing more to do: close stdin. The result is in `result`.
        case finished
    }

    public private(set) var result: AgentRunResult
    public private(set) var isFinished = false
    /// The turn was accepted: events follow, no more start-up.
    public private(set) var turnStarted = false

    private enum Step: Int { case initialize = 1, account, config, thread, turn, interrupt }

    /// nil = only check that codex works and is signed in.
    private let request: AgentRequest?
    private let policy: CodexPolicy?
    /// Server request ids are small numbers: unique across runs only with this.
    private let runID: String
    private var buffer = Data()
    private var threadID: String?
    private var turnID: String?
    private var version = ""
    private var answered: Set<Int> = []
    /// Pending server requests by permission id.
    private var asked: [String: Any] = [:]
    /// Paths of file changes by item id: the approval request doesn't name them.
    private var changes: [String: [String]] = [:]
    private var seen: Set<String> = []
    private var lastError = ""
    private var lastLimit = false
    private var baseUsage: [String: Int]?
    private var stopping = false

    public init(_ request: AgentRequest?, runID: String = UUID().uuidString) {
        self.request = request
        self.runID = runID
        policy = request.map { CodexPolicy(access: $0.access, cwd: $0.cwd, addDirs: $0.addDirs) }
        result = AgentRunResult(sessionID: request?.resume, program: "codex")
    }

    public func begin() -> [String: Any] {
        call(.initialize, "initialize", ["clientInfo": ["name": "tracktasks", "title": "TrackTasks", "version": "1"],
                                         "capabilities": NSNull()])
    }

    public mutating func consume(_ data: Data) -> [Action] {
        buffer.append(data)
        var out: [Action] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !isFinished, let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            out += handle(obj)
        }
        return out
    }

    /// Answer a permission request; `allow` is for this one action only.
    public mutating func respond(_ id: String, allow: Bool) -> [Action] {
        guard let rid = asked.removeValue(forKey: id) else { return [] }
        return [.send(["id": rid, "result": ["decision": allow ? "accept" : "decline"]])]
    }

    /// nil = no turn yet, the process can just be killed.
    public mutating func interrupt() -> [String: Any]? {
        stopping = true
        guard !isFinished, let threadID, let turnID else { return nil }
        return call(.interrupt, "turn/interrupt", ["threadId": threadID, "turnId": turnID])
    }

    /// The process ended.
    public mutating func exited(code: Int32) -> AgentRunResult {
        result.exitCode = code
        if stopping, !result.gotResult {
            result.stopped = true
        } else if !isFinished {
            if answered.isEmpty {
                _ = cannotStart(Self.outdated(version))
            } else {
                result.isError = true
                result.cannotStart = !turnStarted
                let tail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)
                result.resultText = "Codex оборвался до конца хода (код \(code))" + (tail.isEmpty ? "" : ": \(tail)")
            }
            isFinished = true
        }
        return result
    }

    public mutating func addStderr(_ s: String) { result.stderr = String((result.stderr + s).suffix(8000)) }

    /// No answer during start-up.
    public mutating func startTimedOut() { _ = cannotStart(Self.silent + " " + Self.outdated(version)) }

    // MARK: Messages

    private func call(_ step: Step, _ method: String, _ params: [String: Any]) -> [String: Any] {
        ["id": step.rawValue, "method": method, "params": params]
    }

    private mutating func handle(_ obj: [String: Any]) -> [Action] {
        if let method = obj["method"] as? String {
            let p = obj["params"] as? [String: Any] ?? [:]
            if let id = obj["id"], !(id is NSNull) { return serverRequest(method, id, p) }
            return notification(method, p)
        }
        guard let n = obj["id"] as? Int, let step = Step(rawValue: n), answered.insert(n).inserted else { return [] }
        if let e = obj["error"] as? [String: Any] { return failed(step, e["message"] as? String ?? "") }
        return answer(step, obj["result"] as? [String: Any] ?? [:])
    }

    private mutating func answer(_ step: Step, _ r: [String: Any]) -> [Action] {
        switch step {
        case .initialize:
            // "tracktasks/0.162.0 (Mac OS …)"
            version = (r["userAgent"] as? String ?? "").split(separator: " ").first?.split(separator: "/").last.map(String.init) ?? ""
            return [.send(["method": "initialized"]), .send(call(.account, "account/read", [:]))]
        case .account:
            guard let needs = r["requiresOpenaiAuth"] as? Bool else { return cannotStart(Self.outdated(version)) }
            if needs, !(r["account"] is [String: Any]) { return cannotStart(Self.noLogin) }
            guard let request else {
                result.gotResult = true
                result.resultText = "codex \(version), вход выполнен"
                isFinished = true
                return [.finished]
            }
            return [.send(call(.config, "config/read", ["cwd": request.cwd.path, "includeLayers": false]))]
        case .config:
            guard let request, let policy, let config = r["config"] as? [String: Any] else { return cannotStart(Self.outdated(version)) }
            let servers = (config["mcp_servers"] as? [String: Any] ?? [:]).keys.sorted()
            var p: [String: Any] = ["cwd": request.cwd.path, "approvalPolicy": CodexPolicy.approvalPolicy,
                                    "approvalsReviewer": "user", "sandbox": policy.sandboxMode,
                                    "config": policy.config(mcpServers: servers)]
            if !request.systemPrompt.isEmpty { p["developerInstructions"] = request.systemPrompt }
            if !request.model.isEmpty { p["model"] = request.model }
            if let sid = request.resume {
                p["threadId"] = sid
                p["excludeTurns"] = true
                return [.send(call(.thread, "thread/resume", p))]
            }
            p["ephemeral"] = request.access == .answer
            return [.send(call(.thread, "thread/start", p))]
        case .thread:
            guard let request, let policy, let id = (r["thread"] as? [String: Any])?["id"] as? String else {
                return cannotStart(Self.outdated(version))
            }
            // Managed settings or another version may have changed them: never run with wider rights than asked.
            guard r["approvalPolicy"] as? String == CodexPolicy.approvalPolicy,
                  r["approvalsReviewer"] as? String ?? "user" == "user",
                  (r["sandbox"] as? [String: Any])?["type"] as? String == policy.sandboxType else {
                return cannotStart("Codex не принял ограничения прав (песочница и запрос разрешений) — запуск отменён")
            }
            threadID = id
            result.sessionID = id
            result.model = r["model"] as? String ?? ""
            return [.started(id), .send(call(.turn, "turn/start", [
                "threadId": id, "cwd": request.cwd.path, "approvalPolicy": CodexPolicy.approvalPolicy,
                "approvalsReviewer": "user", "sandboxPolicy": policy.sandbox,
                "input": [["type": "text", "text": request.prompt, "text_elements": [Any]()]],
            ]))]
        case .turn:
            turnStarted = true
            if turnID == nil { turnID = (r["turn"] as? [String: Any])?["id"] as? String }
            return []
        case .interrupt:
            return []
        }
    }

    private mutating func failed(_ step: Step, _ message: String) -> [Action] {
        switch step {
        case .initialize, .account, .config:
            return cannotStart(Self.outdated(version) + (message.isEmpty ? "" : " Ответ: \(message.prefix(200))"))
        case .thread where request?.resume != nil:
            // The queue may start a new session instead.
            return fail("Сессия Codex не найдена: \(message.prefix(300))")
        case .thread, .turn:
            let text = "Codex не начал работу: \(message.prefix(400))"
            return step == .thread ? cannotStart(text) : fail(text)
        case .interrupt:
            return []
        }
    }

    private mutating func fail(_ text: String) -> [Action] {
        result.isError = true
        result.resultText = text
        isFinished = true
        return [.finished]
    }

    private mutating func cannotStart(_ text: String) -> [Action] {
        result.cannotStart = true
        return fail(text)
    }

    private func isOurs(_ p: [String: Any]) -> Bool {
        guard let t = p["threadId"] as? String else { return true }
        return t == threadID
    }

    private mutating func notification(_ method: String, _ p: [String: Any]) -> [Action] {
        guard isOurs(p) else { return [] }
        switch method {
        case "turn/started":
            turnStarted = true
            if let id = (p["turn"] as? [String: Any])?["id"] as? String { turnID = id }
        case "item/started":
            return item(p["item"] as? [String: Any] ?? [:], done: false)
        case "item/completed":
            return item(p["item"] as? [String: Any] ?? [:], done: true)
        case "thread/tokenUsage/updated":
            usage(p)
        case "model/rerouted":
            if let m = p["toModel"] as? String { result.model = m }
        case "error":
            if p["willRetry"] as? Bool != true, let e = p["error"] as? [String: Any] { (lastError, lastLimit) = (Self.text(e), Self.isLimit(e)) }
        case "turn/completed":
            return completed(p["turn"] as? [String: Any] ?? [:])
        default:
            break
        }
        return []
    }

    private mutating func item(_ i: [String: Any], done: Bool) -> [Action] {
        let id = i["id"] as? String ?? "", type = i["type"] as? String ?? ""
        if type == "fileChange" {
            changes[id] = (i["changes"] as? [[String: Any]] ?? []).flatMap { c -> [String] in
                [c["path"] as? String, (c["kind"] as? [String: Any])?["move_path"] as? String].compactMap { $0 }
            }
        }
        if ["", "userMessage", "reasoning", "hookPrompt", "contextCompaction"].contains(type) { return [] }
        let new = seen.insert(id).inserted
        if new { result.turns += 1 }
        switch type {
        case "agentMessage":
            guard done, let t = i["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            result.resultText = t
            return [.event(.text(t))]
        case "commandExecution":
            return new ? [.event(.tool("$ " + (i["command"] as? String ?? "")))] : []
        case "fileChange":
            return new ? [.event(.tool("Правит " + (changes[id] ?? []).map(shown).joined(separator: ", ")))] : []
        case "mcpToolCall":
            return new ? [.event(.tool("MCP \(i["server"] as? String ?? "") \(i["tool"] as? String ?? "")"))] : []
        case "plan":
            return []
        default:
            return new ? [.event(.tool(type))] : []
        }
    }

    private func shown(_ path: String) -> String {
        guard let cwd = request?.cwd.path, path.hasPrefix(cwd + "/") else { return path }
        return String(path.dropFirst(cwd.count + 1))
    }

    /// `total` is for the whole thread, with earlier turns: count from where this turn began.
    private mutating func usage(_ p: [String: Any]) {
        guard p["turnId"] as? String == turnID, turnID != nil, let u = p["tokenUsage"] as? [String: Any],
              let total = u["total"] as? [String: Any], let last = u["last"] as? [String: Any] else { return }
        func n(_ d: [String: Any], _ k: String) -> Int { d[k] as? Int ?? 0 }
        let keys = ["inputTokens", "cachedInputTokens", "cacheWriteInputTokens", "outputTokens"]
        let base = baseUsage ?? Dictionary(uniqueKeysWithValues: keys.map { ($0, n(total, $0) - n(last, $0)) })
        baseUsage = base
        func spent(_ k: String) -> Int { max(0, n(total, k) - (base[k] ?? 0)) }
        result.cacheReadTokens = spent("cachedInputTokens")
        result.cacheWriteTokens = spent("cacheWriteInputTokens")
        // Cached ones are a part of `inputTokens`.
        result.inputTokens = max(0, spent("inputTokens") - result.cacheReadTokens - result.cacheWriteTokens)
        result.outputTokens = spent("outputTokens")
    }

    private mutating func completed(_ turn: [String: Any]) -> [Action] {
        if let id = turn["id"] as? String, let turnID, id != turnID { return [] }
        result.durationMs = turn["durationMs"] as? Int ?? 0
        switch turn["status"] as? String {
        case "completed":
            result.gotResult = true
            isFinished = true
            return [.finished]
        case "interrupted" where stopping:
            result.stopped = true
            isFinished = true
            return [.finished]
        case "interrupted":
            return fail("Codex прервал ход")
        default:
            let error = turn["error"] as? [String: Any]
            let e = error.map(Self.text) ?? lastError
            // When it resets isn't in the error.
            if turn["status"] as? String == "failed", error.map(Self.isLimit) ?? lastLimit { result.limit = RunLimit() }
            return fail(e.isEmpty ? "Codex завершил ход с ошибкой" : e)
        }
    }

    // MARK: Requests of the server

    private mutating func serverRequest(_ method: String, _ id: Any, _ p: [String: Any]) -> [Action] {
        func reply(_ r: [String: Any]) -> [Action] { [.send(["id": id, "result": r])] }
        let decline: [String: Any] = ["decision": "decline"]
        switch method {
        case "item/commandExecution/requestApproval":
            guard isOurs(p), let policy, policy.access != .answer else { return reply(decline) }
            let net = (p["networkApprovalContext"] as? [String: Any])?["host"] as? String
            let command = p["command"] as? String ?? ""
            let title = net.map { "Сеть: \($0)" + (command.isEmpty ? "" : " — \(command)") } ?? (command.isEmpty ? "Команда" : command)
            return ask(id, tool: "Bash", title: title, reason: p["reason"])
        case "item/fileChange/requestApproval":
            guard isOurs(p), let policy else { return reply(decline) }
            let paths = changes[p["itemId"] as? String ?? ""] ?? []
            // Asks for a whole folder, not for this change.
            let grant = p["grantRoot"] as? String
            switch policy.edit(paths) {
            case .deny: return reply(decline)
            case .allow where grant == nil: return reply(["decision": "accept"])
            case .allow, .ask:
                let what = paths.map(shown).joined(separator: ", ")
                return ask(id, tool: "Edit", title: "Правка: " + (grant.map { "всё в \($0) " } ?? "") + (what.isEmpty ? "файлы не названы" : what),
                           reason: p["reason"])
            }
        case "item/permissions/requestApproval":
            return reply(["permissions": [String: Any](), "scope": "turn"])
        case "mcpServer/elicitation/request":
            return reply(["action": "decline", "content": NSNull(), "_meta": NSNull()])
        default:
            // Without an answer the server waits forever.
            return [.send(["id": id, "error": ["code": -32601, "message": "unsupported"]])]
        }
    }

    private mutating func ask(_ id: Any, tool: String, title: String, reason: Any?) -> [Action] {
        let key = "codex-\(runID)-\(id)"
        asked[key] = id
        let why = (reason as? String).map { $0 + "\n" } ?? ""
        return [.permission(AgentPermission(id: key, tool: tool, title: title,
                                            note: why + "Codex может выполнить одобренное вне песочницы."))]
    }

    // MARK: Errors

    public static let noLogin = "Codex: вход не выполнен. Выполни в терминале `codex login`."

    private static let outdatedMark = "не поддерживает нужный протокол app-server", silent = "Codex не отвечает."

    static func isOutdated(_ text: String) -> Bool { text.contains(outdatedMark) && !text.hasPrefix(silent) }

    static func outdated(_ version: String) -> String {
        "Codex\(version.isEmpty ? "" : " \(version)") \(outdatedMark): обнови Codex или укажи путь к новой версии в Настройках (⌘,)."
    }

    private static func kind(_ e: [String: Any]) -> String {
        let info = e["codexErrorInfo"]
        return info as? String ?? (info as? [String: Any])?.keys.first ?? ""
    }

    /// The account's limit. `rateLimitExceeded` and `sessionBudgetExceeded` are something else.
    private static func isLimit(_ e: [String: Any]) -> Bool { kind(e) == "usageLimitExceeded" }

    private static func text(_ e: [String: Any]) -> String {
        let message = e["message"] as? String ?? "", kind = kind(e)
        let what: String? = switch kind {
        case "unauthorized": noLogin
        case "usageLimitExceeded", "sessionBudgetExceeded", "rateLimitExceeded": "Codex: исчерпан лимит."
        case "serverOverloaded": "Codex: сервер перегружен."
        case "contextWindowExceeded": "Codex: разговор не помещается в контекст модели."
        case "sandboxError": "Codex: ошибка песочницы."
        case "badRequest": "Codex: запрос отклонён (проверь модель профиля)."
        case "httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected", "responseTooManyFailedAttempts":
            "Codex: нет связи с сервером."
        default: nil
        }
        return [what, message.isEmpty ? nil : String(message.prefix(600))].compactMap { $0 }.joined(separator: " ")
    }
}
