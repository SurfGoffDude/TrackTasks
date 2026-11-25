import Foundation

/// `tt mcp`: Model Context Protocol over stdio, one JSON-RPC message per line. Serves both eras:
/// the `initialize` handshake (up to 2025-11-25) and stateless requests with `_meta` (2026-07-28).
/// Requests are answered one at a time, so `notifications/cancelled` has nothing to interrupt.
final class MCPServer {
    static let modern = ["2026-07-28"]
    /// 2025-03-26 is absent on purpose: it requires accepting batches.
    static let legacy = ["2025-11-25", "2025-06-18", "2024-11-05"]
    static let maxLine = 1 << 20
    private static let meta = "io.modelcontextprotocol/"
    private static let info: [String: Any] = ["name": "tracktasks", "title": "TrackTasks", "version": CLI.version]

    private struct Failure: Error {
        var code: Int
        var message: String
        var data: [String: Any]?
    }

    private let cli: CLI
    private let tools: MCPTools
    private var initialized = false

    init(_ cli: CLI, maxCreated: Int = MCPTools.maxCreated) {
        self.cli = cli
        tools = MCPTools(cli, maxCreated: maxCreated)
    }

    /// Reads lines until the end of input.
    func serve() {
        var lines = MCPLines(limit: Self.maxLine)
        func answer(_ batch: [MCPLines.Line]) {
            for l in batch {
                let reply = switch l {
                case .text(let d): handle(d)
                case .tooLong: encode(error: Failure(code: -32600, message: "message is longer than \(Self.maxLine) bytes"), id: NSNull())
                }
                if let reply { cli.out(reply + "\n") }
            }
        }
        while let chunk = cli.input(), !chunk.isEmpty { answer(lines.feed(chunk)) }
        answer(lines.finish())
    }

    /// One message → the response line, nil when none is due.
    func handle(_ line: Data) -> String? {
        guard let text = String(data: line, encoding: .utf8) else {
            return encode(error: Failure(code: -32700, message: "not UTF-8"), id: NSNull())
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            return encode(error: Failure(code: -32700, message: "parse error"), id: NSNull())
        }
        guard let m = any as? [String: Any], m["jsonrpc"] as? String == "2.0" else {
            return encode(error: Failure(code: -32600, message: "expected one JSON-RPC 2.0 object"), id: NSNull())
        }
        // Responses: this server asks nothing.
        if m["method"] == nil, m["result"] != nil || m["error"] != nil { return nil }
        let id = m["id"].flatMap(Self.validID)
        guard let method = m["method"] as? String, m["id"] == nil || id != nil else {
            return encode(error: Failure(code: -32600, message: "invalid request"), id: id ?? NSNull())
        }
        guard let id else { return nil }
        do {
            return encode(["jsonrpc": "2.0", "id": id, "result": try result(method, m["params"])])
        } catch let f as Failure {
            return encode(error: f, id: id)
        } catch {
            return encode(error: Failure(code: -32603, message: "internal error"), id: id)
        }
    }

    private static func validID(_ v: Any) -> Any? {
        if v is String { return v }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue == n.doubleValue.rounded() else { return nil }
        return n
    }

    // MARK: Methods

    private func result(_ method: String, _ raw: Any?) throws -> [String: Any] {
        guard raw == nil || raw is [String: Any] else { throw Failure(code: -32602, message: "params must be an object") }
        let params = raw as? [String: Any] ?? [:]
        let isModern = try checkMeta(method, params["_meta"])

        let known = isModern ? ["server/discover", "tools/list", "tools/call"] : ["initialize", "ping", "tools/list", "tools/call"]
        guard known.contains(method) else { throw Failure(code: -32601, message: "method not found: \(method)") }
        if !isModern, !initialized, method.hasPrefix("tools/") {
            throw Failure(code: -32602, message: "no _meta.\(Self.meta)protocolVersion and no initialize before")
        }

        var out: [String: Any]
        switch method {
        case "initialize":
            guard let asked = params["protocolVersion"] as? String else {
                throw Failure(code: -32602, message: "protocolVersion is required")
            }
            initialized = true
            return ["protocolVersion": Self.legacy.contains(asked) ? asked : Self.legacy[0],
                    "capabilities": ["tools": [String: Any]()], "serverInfo": Self.info, "instructions": MCPTools.instructions]
        case "ping":
            return [:]
        case "server/discover":
            out = ["supportedVersions": Self.modern, "capabilities": ["tools": [String: Any]()], "instructions": MCPTools.instructions]
        case "tools/list":
            guard params["cursor"] == nil else { throw Failure(code: -32602, message: "unknown cursor") }
            out = ["tools": MCPTools.list]
        default:
            guard let name = params["name"] as? String else { throw Failure(code: -32602, message: "name is required") }
            guard MCPTools.names.contains(name) else { throw Failure(code: -32602, message: "unknown tool: \(name)") }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                throw Failure(code: -32602, message: "arguments must be an object")
            }
            out = call(name, params["arguments"] as? [String: Any] ?? [:])
        }
        if isModern {
            out["resultType"] = "complete"
            out["_meta"] = [Self.meta + "serverInfo": Self.info]
            if method != "tools/call" {
                out["ttlMs"] = 3_600_000
                out["cacheScope"] = "public"
            }
        }
        return out
    }

    /// True for a valid request of the modern era. Other `_meta` keys (progressToken) exist in the legacy one too.
    private func checkMeta(_ method: String, _ raw: Any?) throws -> Bool {
        let m = raw as? [String: Any] ?? [:]
        guard method == "server/discover" || m.keys.contains(where: {
            [Self.meta + "protocolVersion", Self.meta + "clientCapabilities", Self.meta + "clientInfo"].contains($0)
        }) else { return false }
        guard let version = m[Self.meta + "protocolVersion"] as? String else {
            throw Failure(code: -32602, message: "_meta.\(Self.meta)protocolVersion is required")
        }
        guard Self.modern.contains(version) else {
            throw Failure(code: -32022, message: "Unsupported protocol version",
                          data: ["supported": Self.modern, "requested": version])
        }
        guard m[Self.meta + "clientCapabilities"] is [String: Any] else {
            throw Failure(code: -32602, message: "_meta.\(Self.meta)clientCapabilities is required")
        }
        return true
    }

    private func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
        var out: [String: Any]
        do {
            out = ["structuredContent": cleaned(try tools.call(name, args)), "isError": false]
        } catch {
            let e = CLIError(error)
            out = ["structuredContent": cleaned(["error": ["code": e.code.name, "message": e.message]]), "isError": true]
        }
        out["content"] = [["type": "text", "text": encode(out["structuredContent"] as? [String: Any] ?? [:])]]
        return out
    }

    /// File text goes to a model and often to a terminal: no control characters.
    private func cleaned(_ v: Any) -> Any {
        switch v {
        case let s as String: cli.clean(s)
        case let a as [Any]: a.map(cleaned)
        case let d as [String: Any]: d.mapValues(cleaned)
        default: v
        }
    }

    private func encode(error f: Failure, id: Any) -> String {
        var e: [String: Any] = ["code": f.code, "message": f.message]
        if let d = f.data { e["data"] = d }
        return encode(["jsonrpc": "2.0", "id": id, "error": e])
    }

    /// Only strings, numbers, arrays, dictionaries and NSNull get here; newlines inside strings are escaped.
    private func encode(_ o: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Splits a byte stream into lines. A line over the limit is dropped up to its end and reported once.
struct MCPLines {
    enum Line: Equatable { case text(Data), tooLong }

    let limit: Int
    private var buffer = Data()
    private var skipping = false

    init(limit: Int) { self.limit = limit }

    mutating func feed(_ chunk: Data) -> [Line] {
        var out: [Line] = []
        let parts = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (i, part) in parts.enumerated() {
            if !skipping {
                buffer.append(part)
                if buffer.count > limit {
                    out.append(.tooLong)
                    buffer = Data()
                    skipping = true
                }
            }
            guard i < parts.count - 1 else { break }
            if !skipping, !buffer.isEmpty { out.append(.text(buffer)) }
            buffer = Data()
            skipping = false
        }
        return out
    }

    mutating func finish() -> [Line] {
        defer { buffer = Data() }
        return buffer.isEmpty ? [] : [.text(buffer)]
    }
}

enum MCPConfig {
    static func text(_ tt: String) -> String {
        let shell = "'" + tt.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Quotes and backslashes are escaped the same way in JSON and in a TOML basic string.
        let quoted = Frontmatter.quote(tt)
        return """
            # Claude Code
            claude mcp add --scope user tracktasks -- \(shell) mcp

            # Claude Code, .mcp.json в папке проекта
            {
              "mcpServers": {
                "tracktasks": { "command": \(quoted), "args": ["mcp"] }
              }
            }

            # Codex
            codex mcp add tracktasks -- \(shell) mcp

            # Codex, ~/.codex/config.toml
            [mcp_servers.tracktasks]
            command = \(quoted)
            args = ["mcp"]

            """
    }
}
