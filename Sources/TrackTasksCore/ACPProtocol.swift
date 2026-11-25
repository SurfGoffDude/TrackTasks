import Foundation

/// Program of an ACP agent, as set in a profile. No shell: the arguments go as they are.
public struct ACPCommand: Codable, Hashable, Sendable {
    public var command: String
    public var args: [String]

    public init(command: String, args: [String] = []) {
        self.command = command
        self.args = args
    }

    public var title: String { ([command] + args).joined(separator: " ") }

    /// Why it can't be started; nil = fine.
    public var problem: String? {
        if command.trimmingCharacters(in: .whitespaces).isEmpty { return "Укажи команду ACP-агента" }
        if ([command] + args).contains(where: { $0.contains("\0") || $0.contains("\n") }) { return "Команда и аргументы — по одной строке" }
        if command.contains("/"), !command.hasPrefix("/") { return "Команда — полный путь или имя из PATH" }
        return nil
    }
}

/// What the agent announced in its answer to `initialize`. Anything not named there is not supported.
public struct ACPFeatures: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let resume = ACPFeatures(rawValue: 1)
    public static let load = ACPFeatures(rawValue: 1 << 1)
    public static let systemPrompt = ACPFeatures(rawValue: 1 << 2)
    public static let additionalDirectories = ACPFeatures(rawValue: 1 << 3)

    public init(_ capabilities: [String: Any]) {
        let s = capabilities["sessionCapabilities"] as? [String: Any] ?? [:]
        var f: ACPFeatures = []
        if s["resume"] is [String: Any] { f.insert(.resume) }
        if capabilities["loadSession"] as? Bool == true { f.insert(.load) }
        if s["systemPrompt"] is [String: Any] { f.insert(.systemPrompt) }
        if s["additionalDirectories"] is [String: Any] { f.insert(.additionalDirectories) }
        self = f
    }

    public var canResume: Bool { contains(.resume) || contains(.load) }

    public var title: String {
        [canResume ? "продолжение сессии" : nil, contains(.systemPrompt) ? "системный промпт" : nil,
         contains(.additionalDirectories) ? "дополнительные папки" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

/// One turn over the Agent Client Protocol v1 (JSON-RPC lines on stdio): what to send and what each received line means.
/// No processes and no file contents here. Field names are from the v1 schema 1.35.0 (checked 25.11.2026).
public struct ACPSession {
    public static let protocolVersion = 1

    public struct Command: Equatable, Sendable {
        public var command: String
        public var args: [String]
        public var env: [String: String]
        public var cwd: String
        public var limit: Int?

        public init(command: String, args: [String], env: [String: String], cwd: String, limit: Int?) {
            self.command = command
            self.args = args
            self.env = env
            self.cwd = cwd
            self.limit = limit
        }

        /// What the user approves. Without arguments `command` is a line for the shell.
        public var title: String {
            args.isEmpty ? command : ([command] + args).map(Self.quoted).joined(separator: " ")
        }

        static func quoted(_ s: String) -> String {
            s.range(of: #"^[A-Za-z0-9_./:=@%+,-]+$"#, options: .regularExpression) != nil ? s
                : "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }
    }

    public enum Terminal: Equatable, Sendable {
        case create(Command)
        case output(String), wait(String), kill(String), release(String)
    }

    /// `key` names a request of the agent: answer it with `reply` or `refuse`.
    public enum Action {
        case send([String: Any])
        case event(AgentEvent)
        case permission(AgentPermission)
        case features(ACPFeatures)
        case read(key: String, path: String, line: Int?, limit: Int?)
        case write(key: String, path: String, content: String)
        case terminal(key: String, Terminal)
        /// Nothing more to do: close stdin. The result is in `result`.
        case finished
    }

    public private(set) var result: AgentRunResult
    public private(set) var isFinished = false
    /// The agent has said something about our turn.
    public private(set) var turnStarted = false
    /// Start-up is over.
    public private(set) var promptSent = false
    /// The user asked to stop: nothing new is done for the agent.
    public private(set) var stopping = false

    private enum Step: Int { case initialize = 1, session, model, prompt }
    private enum Asked {
        case permission(allow: String, reject: String?)
        case command(Command)
        case work
    }

    /// nil = only ask what the agent can do.
    private let request: AgentRequest?
    private let access: ACPAccess?
    private let program: String
    private let runID: String
    private var buffer = Data()
    private var features: ACPFeatures = []
    private var name = ""
    private var sessionID: String?
    private var answered: Set<Int> = []
    /// Requests of the agent without an answer yet.
    private var asked: [String: (id: Any, kind: Asked)] = [:]
    private var titles: [String: String] = [:]
    private var message = ""
    private var messageID: String?
    private var seen: Set<String> = []

    /// One message of the agent; more means that it doesn't speak the protocol.
    private static let maxLine = 64 << 20

    public init(_ request: AgentRequest?, program: String, runID: String = UUID().uuidString) {
        self.request = request
        self.program = program
        self.runID = runID
        access = request.map { ACPAccess(access: $0.access, cwd: $0.cwd, addDirs: $0.addDirs) }
        result = AgentRunResult(sessionID: request?.resume, program: program)
    }

    public func begin() -> [String: Any] {
        let files = request != nil && request?.access != .answer
        return call(.initialize, "initialize", [
            "protocolVersion": Self.protocolVersion,
            "clientInfo": ["name": "tracktasks", "title": "TrackTasks", "version": "1"],
            "clientCapabilities": ["fs": ["readTextFile": files, "writeTextFile": files], "terminal": files],
        ])
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
        if buffer.count > Self.maxLine, !isFinished {
            buffer = Data()
            out += fail("\(program): слишком длинное сообщение")
        }
        return out
    }

    /// Answer a permission request; `allow` is for this one action only.
    public mutating func respond(_ id: String, allow: Bool) -> [Action] {
        let prefix = permissionID("")
        guard id.hasPrefix(prefix) else { return [] }
        let key = String(id.dropFirst(prefix.count))
        switch asked[key]?.kind {
        case .permission(let yes, let no):
            return reply(key, Self.outcome(allow ? yes : no))
        case .command(let c):
            guard allow else { return refuse(key, "Пользователь не разрешил команду") }
            // The folder may have been replaced while the user was thinking.
            guard access?.folder(c.cwd) == c.cwd else { return refuse(key, ACPAccess.Refusal.outside.message) }
            asked[key]?.kind = .work
            return [.terminal(key: key, .create(c))]
        case .work, nil:
            return []
        }
    }

    /// Only the first answer counts.
    public mutating func reply(_ key: String, _ result: [String: Any]) -> [Action] {
        guard let a = asked.removeValue(forKey: key), !isFinished else { return [] }
        return [.send(["jsonrpc": "2.0", "id": a.id, "result": result])]
    }

    public mutating func refuse(_ key: String, _ message: String, code: Int = -32602) -> [Action] {
        guard let a = asked.removeValue(forKey: key), !isFinished else { return [] }
        return [error(a.id, code, message)]
    }

    /// nil = no turn yet, the process can just be killed.
    public mutating func interrupt() -> [Action]? {
        stopping = true
        guard !isFinished, promptSent, let sessionID else { return nil }
        var out: [Action] = [.send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionID]])]
        for (key, a) in asked {
            switch a.kind {
            case .permission: out += reply(key, Self.outcome(nil))
            case .command, .work: out += refuse(key, "cancelled", code: Self.cancelled)
            }
        }
        return out
    }

    /// The process ended.
    public mutating func exited(code: Int32) -> AgentRunResult {
        result.exitCode = code
        if stopping, !result.gotResult {
            result.stopped = true
            result.isError = false
        } else if !isFinished {
            result.isError = true
            result.cannotStart = !promptSent
            // The turn may have done something without a word: not to be repeated in a new session.
            if promptSent { result.turns = max(1, result.turns) }
            let tail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)
            result.resultText = (answered.isEmpty ? "\(program) не ответил по протоколу ACP (код \(code))" : "\(program) оборвался до конца хода (код \(code))")
                + (tail.isEmpty ? "" : ": \(tail)")
            isFinished = true
        }
        return result
    }

    public mutating func addStderr(_ s: String) { result.stderr = String((result.stderr + s).suffix(8000)) }

    /// No answer during start-up.
    public mutating func startTimedOut() { _ = cannotStart("\(program) не отвечает по протоколу ACP") }

    // MARK: Messages

    private static let cancelled = -32800, authRequired = -32000

    private func call(_ step: Step, _ method: String, _ params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": step.rawValue, "method": method, "params": params]
    }

    private func error(_ id: Any, _ code: Int, _ message: String) -> Action {
        .send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func outcome(_ option: String?) -> [String: Any] {
        ["outcome": option.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]]
    }

    /// A whole number, not `true`.
    private static func int(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n as? Int
    }

    /// Ids may be numbers and strings: 1 and "1" are different.
    private static func key(_ id: Any) -> String {
        (id as? String).map { "s" + $0 } ?? "n\(id)"
    }

    private func permissionID(_ key: String) -> String { "acp-\(runID)-\(key)" }

    private mutating func handle(_ obj: [String: Any]) -> [Action] {
        if let method = obj["method"] as? String {
            let p = obj["params"] as? [String: Any] ?? [:]
            if let id = obj["id"], !(id is NSNull) { return agentRequest(method, id, p) }
            return notification(method, p)
        }
        guard let n = Self.int(obj["id"]), let step = Step(rawValue: n), sent.contains(n), answered.insert(n).inserted else { return [] }
        if let e = obj["error"] as? [String: Any] {
            return failed(step, Self.int(e["code"]) ?? 0, e["message"] as? String ?? "")
        }
        return answer(step, obj["result"] as? [String: Any] ?? [:])
    }

    /// Our requests so far.
    private var sent: Set<Int> = [Step.initialize.rawValue]

    private mutating func request(_ step: Step, _ method: String, _ params: [String: Any]) -> Action {
        sent.insert(step.rawValue)
        return .send(call(step, method, params))
    }

    private mutating func answer(_ step: Step, _ r: [String: Any]) -> [Action] {
        switch step {
        case .initialize:
            let info = r["agentInfo"] as? [String: Any] ?? [:]
            name = [info["title"] as? String ?? info["name"] as? String ?? program, info["version"] as? String ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
            guard let v = Self.int(r["protocolVersion"]), v == Self.protocolVersion else {
                let theirs = r["protocolVersion"].map { "\($0)" } ?? "не указана"
                return cannotStart("\(name): версия протокола ACP \(theirs) не поддерживается, нужна \(Self.protocolVersion)")
            }
            features = ACPFeatures(r["agentCapabilities"] as? [String: Any] ?? [:])
            guard let request else {
                result.gotResult = true
                result.resultText = "\(name), ACP v\(v)" + (features.title.isEmpty ? "" : ": \(features.title)")
                isFinished = true
                return [.features(features), .finished]
            }
            let begin: Action
            if let sid = request.resume {
                guard features.canResume else { return [.features(features)] + fail("\(name) не продолжает сессии") }
                begin = self.request(.session, features.contains(.resume) ? "session/resume" : "session/load",
                                     sessionParams(request).merging(["sessionId": sid]) { $1 })
            } else {
                begin = self.request(.session, "session/new", sessionParams(request))
            }
            return [.features(features), .event(.tool("ACP: \(name)")), begin]
        case .session:
            guard let request, let id = request.resume ?? r["sessionId"] as? String, !id.isEmpty else {
                return cannotStart("\(name): непонятный ответ на начало сессии")
            }
            sessionID = id
            result.sessionID = id
            return chooseModel(request, id, r["configOptions"])
        case .model:
            guard let request, let o = Self.modelOption(r["configOptions"]), o["currentValue"] as? String == request.model else {
                return cannotStart("\(name) не принял модель «\(request?.model ?? "")»")
            }
            return prompt(request)
        case .prompt:
            turnStarted = true
            result.turns = max(1, result.turns)
            let out = closeMessage()
            switch r["stopReason"] as? String {
            case "end_turn":
                result.gotResult = true
                isFinished = true
                return out + [.finished]
            case "cancelled" where stopping:
                result.stopped = true
                isFinished = true
                return out + [.finished]
            case "cancelled": return out + fail("\(name) прервал ход")
            case "refusal": return out + fail("\(name) отказался выполнять запрос")
            case "max_tokens": return out + fail("\(name): достигнут предел токенов")
            case "max_turn_requests": return out + fail("\(name): достигнут предел запросов за ход")
            case let other: return out + fail("\(name): неизвестная причина остановки «\(other ?? "—")»")
            }
        }
    }

    private func sessionParams(_ r: AgentRequest) -> [String: Any] {
        var p: [String: Any] = ["cwd": r.cwd.path, "mcpServers": [Any]()]
        if features.contains(.additionalDirectories), !r.addDirs.isEmpty { p["additionalDirectories"] = r.addDirs.map(\.path) }
        if features.contains(.systemPrompt), !r.systemPrompt.isEmpty {
            p["systemPrompt"] = ["mode": "append", "content": [["type": "text", "text": r.systemPrompt]]]
        }
        return p
    }

    private static func modelOption(_ options: Any?) -> [String: Any]? {
        (options as? [[String: Any]])?.first { $0["category"] as? String == "model" && $0["type"] as? String == "select" }
    }

    private mutating func chooseModel(_ r: AgentRequest, _ id: String, _ options: Any?) -> [Action] {
        let o = Self.modelOption(options)
        let current = o?["currentValue"] as? String ?? ""
        result.model = current
        guard !r.model.isEmpty, r.model != current else { return prompt(r) }
        guard let o, let config = o["id"] as? String else { return cannotStart("\(name) не даёт выбрать модель — убери модель из профиля") }
        let list = (o["options"] as? [[String: Any]] ?? []).flatMap { $0["options"] as? [[String: Any]] ?? [$0] }.compactMap { $0["value"] as? String }
        guard list.contains(r.model) else {
            return cannotStart("\(name): модели «\(r.model)» нет. Есть: \(list.prefix(20).joined(separator: ", "))")
        }
        result.model = r.model
        return [request(.model, "session/set_config_option", ["sessionId": id, "configId": config, "value": r.model])]
    }

    private mutating func prompt(_ r: AgentRequest) -> [Action] {
        promptSent = true
        let own = features.contains(.systemPrompt) || r.systemPrompt.isEmpty
        let text = own ? r.prompt : r.systemPrompt + "\n\n" + r.prompt
        return [request(.prompt, "session/prompt", ["sessionId": sessionID ?? "", "prompt": [["type": "text", "text": text]]])]
    }

    private mutating func failed(_ step: Step, _ code: Int, _ message: String) -> [Action] {
        if stopping {
            result.stopped = true
            isFinished = true
            return [.finished]
        }
        let who = name.isEmpty ? program : name
        if code == Self.authRequired { return cannotStart("\(who): вход не выполнен. Войди в самом CLI и повтори.") }
        let text = message.isEmpty ? "ошибка \(code)" : String(message.prefix(400))
        switch step {
        // The queue may start a new session instead.
        case .session where request?.resume != nil: return fail("Сессия \(who) не найдена: \(text)")
        case .prompt: return closeMessage() + fail("\(who): \(text)")
        case .initialize, .session, .model: return cannotStart("\(who) не начал работу: \(text)")
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

    // MARK: Notifications

    private mutating func notification(_ method: String, _ p: [String: Any]) -> [Action] {
        switch method {
        case "$/cancel_request":
            guard let id = p["requestId"], !(id is NSNull) else { return [] }
            return refuse(Self.key(id), "cancelled", code: Self.cancelled)
        case "session/update":
            // Before our prompt it is the history replayed by `session/load`.
            guard promptSent, p["sessionId"] as? String == sessionID, let u = p["update"] as? [String: Any] else { return [] }
            return update(u)
        default:
            return []
        }
    }

    private mutating func update(_ u: [String: Any]) -> [Action] {
        switch u["sessionUpdate"] as? String {
        case "agent_message_chunk":
            turnStarted = true
            guard let c = u["content"] as? [String: Any], c["type"] as? String == "text", let t = c["text"] as? String else { return [] }
            var out: [Action] = []
            let id = u["messageId"] as? String
            if let id, let messageID, id != messageID { out = closeMessage() }
            if let id { messageID = id }
            message += t
            return out
        case "agent_thought_chunk", "plan", "tool_call_update":
            turnStarted = true
            return []
        case "tool_call":
            turnStarted = true
            let id = u["toolCallId"] as? String ?? "", title = Self.short(u["title"] as? String ?? "", 300)
            titles[id] = title
            let out = closeMessage()
            guard seen.insert(id).inserted else { return out }
            result.turns += 1
            return out + [.event(.tool(title.isEmpty ? "Инструмент" : title))]
        case "usage_update":
            // Cumulative for the session: what earlier turns of a continued one cost isn't known.
            if request?.resume == nil, let c = u["cost"] as? [String: Any], c["currency"] as? String == "USD",
               let n = c["amount"] as? Double, n.isFinite, n >= 0 { result.costUSD = n }
            return []
        default:
            return []
        }
    }

    private mutating func closeMessage() -> [Action] {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines)
        message = ""
        messageID = nil
        guard !t.isEmpty else { return [] }
        result.turns += 1
        result.resultText = t
        return [.event(.text(t))]
    }

    private static func short(_ s: String, _ n: Int) -> String { s.count > n ? s.prefix(n) + "…" : s }

    // MARK: Requests of the agent

    private mutating func agentRequest(_ method: String, _ id: Any, _ p: [String: Any]) -> [Action] {
        let known = ["session/request_permission", "fs/read_text_file", "fs/write_text_file", "terminal/create", "terminal/output",
                     "terminal/wait_for_exit", "terminal/kill", "terminal/release"]
        // Without an answer the agent waits forever.
        guard known.contains(method) else { return [error(id, -32601, "unsupported: \(method)")] }
        let key = Self.key(id)
        guard asked[key] == nil else { return [] }
        func bad(_ text: String) -> [Action] { [error(id, -32602, text)] }
        if stopping {
            return method == "session/request_permission" ? [.send(["jsonrpc": "2.0", "id": id, "result": Self.outcome(nil)])]
                : [error(id, Self.cancelled, "cancelled")]
        }
        guard promptSent, let sessionID, p["sessionId"] as? String == sessionID else { return bad("unknown session") }
        guard let request, let access, request.access != .answer else { return bad("not allowed") }
        turnStarted = true
        result.turns = max(1, result.turns)
        func work(_ a: Action) -> [Action] {
            asked[key] = (id, .work)
            return [a]
        }
        switch method {
        case "session/request_permission":
            return askPermission(key, id, p)
        case "fs/read_text_file":
            guard let path = p["path"] as? String else { return bad("path") }
            return work(.read(key: key, path: path, line: Self.int(p["line"]), limit: Self.int(p["limit"])))
        case "fs/write_text_file":
            guard let path = p["path"] as? String, let content = p["content"] as? String else { return bad("path, content") }
            return work(.write(key: key, path: path, content: content))
        case "terminal/create":
            guard let command = p["command"] as? String, !command.isEmpty, !command.contains("\0") else { return bad("command") }
            let args = p["args"] as? [String] ?? []
            guard !args.contains(where: { $0.contains("\0") }) else { return bad("args") }
            var env: [String: String] = [:]
            for e in p["env"] as? [[String: Any]] ?? [] {
                guard let n = e["name"] as? String, let v = e["value"] as? String, !n.isEmpty,
                      !n.contains("="), !(n + v).contains("\0") else { return bad("env") }
                env[n] = v
            }
            let folder = p["cwd"] as? String ?? request.cwd.path
            guard let cwd = access.folder(folder) else {
                return bad(ACPAccess.Refusal.outside.message) + [.event(.tool("Отклонено: команда в папке \(folder)"))]
            }
            let c = Command(command: command, args: args, env: env, cwd: cwd, limit: Self.int(p["outputByteLimit"]))
            asked[key] = (id, .command(c))
            let vars = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return [.permission(AgentPermission(
                id: permissionID(key), tool: "Bash", title: c.title,
                note: "Папка: \(cwd)\n" + (vars.isEmpty ? "" : "Переменные: \(vars)\n")
                    + "Команда не ограничена этой папкой: может менять файлы где угодно. Разрешение на один раз."))]
        default:
            guard let t = p["terminalId"] as? String else { return bad("terminalId") }
            let call: Terminal = switch method {
            case "terminal/output": .output(t)
            case "terminal/wait_for_exit": .wait(t)
            case "terminal/kill": .kill(t)
            default: .release(t)
            }
            return work(.terminal(key: key, call))
        }
    }

    private mutating func askPermission(_ key: String, _ id: Any, _ p: [String: Any]) -> [Action] {
        guard let tool = p["toolCall"] as? [String: Any], let options = p["options"] as? [[String: Any]] else {
            return [error(id, -32602, "toolCall, options")]
        }
        func option(_ kind: String) -> String? { options.first { $0["kind"] as? String == kind }?["optionId"] as? String }
        let title = tool["title"] as? String ?? titles[tool["toolCallId"] as? String ?? ""] ?? ""
        let reject = option("reject_once")
        // «Always» would be the agent's own rule, for later runs too.
        guard let allow = option("allow_once") else {
            return [.send(["jsonrpc": "2.0", "id": id, "result": Self.outcome(reject)]),
                    .event(.tool("Отклонено (агент не предложил разрешить один раз): \(Self.short(title, 300))"))]
        }
        asked[key] = (id, .permission(allow: allow, reject: reject))
        let kind = tool["kind"] as? String ?? ""
        let input = tool["rawInput"] as? [String: Any]
        let command = input?["command"] as? String ?? ""
        var note: [String] = []
        if !command.isEmpty, command != title { note.append(Self.short(command, 2000)) }
        let paths = (tool["locations"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        if !paths.isEmpty { note.append("Файлы: " + Self.short(paths.joined(separator: ", "), 1000)) }
        if command.isEmpty, let input, let d = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]) {
            note.append(Self.short(String(decoding: d, as: UTF8.self), 1000))
        }
        note.append("Агент выполнит это сам: папка запуска его не ограничивает.")
        return [.permission(AgentPermission(id: permissionID(key), tool: kind == "execute" ? "Bash" : kind == "edit" ? "Edit" : kind.isEmpty ? "ACP" : kind,
                                            title: title.isEmpty ? "Действие агента" : title, note: note.joined(separator: "\n")))]
    }
}
