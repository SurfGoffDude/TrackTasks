import Foundation

/// One Claude Code session file (`~/.claude/projects/<folder>/<id>.jsonl`), without its text.
public struct ClaudeSessionInfo: Identifiable, Hashable, Sendable {
    /// Session id = file name; what `claude --resume` takes.
    public var id: String
    public var path: String
    /// Folder the session was started in; `claude --resume` works only from it.
    public var cwd: String
    public var title: String
    public var firstPrompt: String
    public var started: Date
    public var updated: Date
    /// Messages of the user with text (tool results are not counted).
    public var turns: Int
    /// `tasks/<file>.md` mentioned in the first prompt.
    public var taskFile: String?
    /// How it was run, in order, repeats collapsed: `cli` = terminal, `sdk-cli` = `claude -p`.
    /// `["sdk-cli", "cli"]` = started by a program, continued in the terminal. Empty = not recorded.
    public var entrypoints: [String]

    public init(id: String, path: String, cwd: String, title: String, firstPrompt: String,
                started: Date, updated: Date, turns: Int, taskFile: String?, entrypoints: [String] = []) {
        self.id = id; self.path = path; self.cwd = cwd; self.title = title; self.firstPrompt = firstPrompt
        self.started = started; self.updated = updated; self.turns = turns; self.taskFile = taskFile
        self.entrypoints = entrypoints
    }
}

/// Read-only streaming parser. Only what people and Claude wrote is kept: no tool output, thinking or attachments.
public enum SessionLog {
    public struct Parsed: Sendable {
        public var info: ClaudeSessionInfo
        /// Term → count over the whole conversation. The text itself is not kept.
        public var terms: [String: Int]
        /// Lines that look like messages but are not valid JSON; skipped.
        public var badLines: Int
    }

    /// A longer line (an embedded file or image) is skipped without being held in memory.
    public static let maxLine = 16 << 20
    static let promptLimit = 400

    /// nil: the file has no conversation. Throws only when it can't be read.
    public static func parse(path: String, modified: Date, maxLine: Int = SessionLog.maxLine) throws -> Parsed? {
        var cwd = "", title = "", prompt = "", firstStamp = "", lastStamp = ""
        var taskFile: String?
        var entrypoints: [String] = []
        var terms: [String: Int] = [:]
        var turns = 0, bad = 0, hasText = false

        try forEachLine(path: path, maxLine: maxLine) { line in
            guard isCandidate(line) else { return }
            // Foundation's JSON leaves autoreleased objects behind.
            autoreleasepool {
                guard let base = line.baseAddress,
                      let obj = try? JSONSerialization.jsonObject(with: Data(
                        bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)),
                      let o = obj as? [String: Any] else { bad += 1; return }
                let type = o["type"] as? String
                if type == "ai-title" {
                    if let t = o["aiTitle"] as? String { title = t }
                    return
                }
                guard type == "user" || type == "assistant", o["isSidechain"] as? Bool != true else { return }
                if cwd.isEmpty, let c = o["cwd"] as? String { cwd = c }
                if let e = o["entrypoint"] as? String, !e.isEmpty, e != entrypoints.last { entrypoints.append(e) }
                guard o["isMeta"] as? Bool != true,
                      let content = (o["message"] as? [String: Any])?["content"] else { return }
                let text = clean(plainText(content))
                guard !text.isEmpty else { return }
                hasText = true
                if let s = o["timestamp"] as? String {
                    if firstStamp.isEmpty { firstStamp = s }
                    lastStamp = s
                }
                for t in SearchText.tokens(text) { terms[t, default: 0] += 1 }
                if type == "user", !isCommand(text) {
                    turns += 1
                    if prompt.isEmpty, o["isCompactSummary"] as? Bool != true {
                        prompt = String(text.prefix(promptLimit))
                        taskFile = taskReference(String(text.prefix(4000)))
                    }
                }
            }
        }
        guard hasText else { return nil }
        for t in SearchText.tokens(title) { terms[t, default: 0] += 1 }
        let updated = date(lastStamp) ?? modified
        let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let info = ClaudeSessionInfo(id: id, path: path, cwd: cwd, title: title, firstPrompt: prompt,
                                     started: date(firstStamp) ?? updated, updated: updated, turns: turns, taskFile: taskFile,
                                     entrypoints: entrypoints)
        return Parsed(info: info, terms: terms, badLines: bad)
    }

    // MARK: - Lines

    /// Cheap byte check, so that JSON is decoded only for messages (a small part of the file).
    static func isCandidate(_ line: UnsafeRawBufferPointer) -> Bool {
        if contains(line, "\"type\":\"user\"") {
            return !contains(line, "\"type\":\"tool_result\"") || contains(line, "\"type\":\"text\"")
        }
        if contains(line, "\"type\":\"assistant\"") { return contains(line, "\"type\":\"text\"") }
        return contains(line, "\"type\":\"ai-title\"")
    }

    private static func contains(_ line: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        memmem(line.baseAddress!, line.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    static func forEachLine(path: String, maxLine: Int, _ body: (UnsafeRawBufferPointer) -> Void) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var chunk = [UInt8](repeating: 0, count: 1 << 18)
        var pending: [UInt8] = []
        var skipping = false
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { break }
            chunk.withUnsafeBytes { raw in
                var start = 0
                while start < n {
                    let rest = UnsafeRawBufferPointer(rebasing: raw[start..<n])
                    let end = memchr(rest.baseAddress!, 0x0A, rest.count).map { UnsafeRawPointer($0) - rest.baseAddress! }
                    let piece = UnsafeRawBufferPointer(rebasing: rest[0..<(end ?? rest.count)])
                    if !skipping, pending.count + piece.count > maxLine {
                        skipping = true
                        pending = []
                    }
                    if end == nil {
                        if !skipping { pending.append(contentsOf: piece) }
                    } else if skipping {
                        skipping = false
                    } else if pending.isEmpty {
                        if !piece.isEmpty { body(piece) }
                    } else {
                        pending.append(contentsOf: piece)
                        pending.withUnsafeBytes(body)
                        pending.removeAll(keepingCapacity: pending.capacity < 1 << 20)
                    }
                    start += (end ?? rest.count - 1) + 1
                }
            }
        }
        // The last line may be still being written; if it's incomplete, it is a bad line.
        if !skipping, !pending.isEmpty { pending.withUnsafeBytes(body) }
    }

    // MARK: - Text

    static func plainText(_ content: Any) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    /// Drops what the CLI adds around the message.
    static func clean(_ s: String) -> String {
        var t = s
        if t.contains("<system-reminder>") {
            t = t.replacing(#/<system-reminder>.*?</system-reminder>/#.dotMatchesNewlines(), with: "")
        }
        if t.contains("pasted_content") { t = t.replacing(#/</?pasted_content[^>]*>/#, with: "") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Slash commands and their output are not replies.
    static func isCommand(_ s: String) -> Bool {
        s.hasPrefix("<command-") || s.hasPrefix("<local-command-") || s.hasPrefix("[Request interrupted")
    }

    /// File name of the first `tasks/<file>.md` in the text.
    static func taskReference(_ s: String) -> String? {
        s.firstMatch(of: #/(?:^|[\s/`"'(«@])tasks/([^\s/`"'()«»]+\.md)/#).map { String($0.1) }
    }

    private static func date(_ s: String) -> Date? {
        try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            ?? Date(s, strategy: .iso8601)
    }
}

/// Which project a session belongs to.
public enum SessionProject {
    /// `cwd` inside a project (the deepest one wins) or inside its tracker worktree
    /// (`<worktreesRoot>/<path with "__">/<id>`).
    public static func find(cwd: String, projects: [String], worktreesRoot: String) -> String? {
        let root = worktreesRoot.hasSuffix("/") ? worktreesRoot : worktreesRoot + "/"
        if cwd.hasPrefix(root) {
            let key = cwd.dropFirst(root.count).prefix { $0 != "/" }
            return projects.first {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "__") == key
            }
        }
        return projects.filter { cwd == $0 || cwd.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }
}

extension SessionLog {
    /// `<id>.jsonl` in one of the folders of `~/.claude/projects`.
    public static func file(session id: String, in projects: URL) -> String? {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        return dirs.lazy.map { projects.appendingPathComponent($0).appendingPathComponent(id + ".jsonl").path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// uuid of the agent's last message: what `claude --resume-session-at` takes. Subagents don't count.
    public static func lastAssistant(path: String) -> String? {
        var last = Data()
        try? forEachLine(path: path, maxLine: maxLine) { line in
            // Quotes inside message texts are escaped, so these bytes are real keys.
            guard contains(line, "\"type\":\"assistant\""), contains(line, "\"uuid\":\""),
                  !contains(line, "\"isSidechain\":true") else { return }
            last = Data(line)
        }
        return ((try? JSONSerialization.jsonObject(with: last)) as? [String: Any])?["uuid"] as? String
    }
}

extension SessionLog {
    /// What people and the agent wrote, in order. No tool output, subagents, service messages or compaction summaries.
    /// Consecutive messages of one side are joined.
    public static func conversation(path: String) throws -> [SessionMessage] {
        var out: [SessionMessage] = []
        try forEachLine(path: path, maxLine: maxLine) { line in
            guard isCandidate(line) else { return }
            autoreleasepool {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let type = o["type"] as? String, type == "user" || type == "assistant",
                      o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true, o["isCompactSummary"] as? Bool != true,
                      let content = (o["message"] as? [String: Any])?["content"] else { return }
                let text = clean(plainText(content))
                guard !text.isEmpty, type == "assistant" || !isCommand(text) else { return }
                let role: SessionMessage.Role = type == "user" ? .user : .agent
                if out.last?.role == role { out[out.count - 1].text += "\n\n" + text } else { out.append(.init(role, text)) }
            }
        }
        return out
    }
}
