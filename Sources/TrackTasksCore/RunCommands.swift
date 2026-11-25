import Darwin
import Foundation

/// `run:` in about.md — how to start the project's dev server(s). One command: `run: npm run dev`.
/// Several, named: `run: {"web": "npm run dev", "api": "go run ."}` (started in the order of names).
public struct RunCommand: Equatable, Sendable, Identifiable {
    public let name: String
    public let command: String
    public var id: String { name }
    public init(name: String, command: String) { self.name = name; self.command = command }
}

public enum RunCommands {
    /// The raw field text (what the person approves) and its commands.
    public struct Parsed: Equatable, Sendable {
        public var field: String
        public var commands: [RunCommand]
        public var isEmpty: Bool { commands.isEmpty }
        public init(field: String, commands: [RunCommand]) { self.field = field; self.commands = commands }
    }

    public static let defaultName = "dev"

    public static func parse(_ fields: [String: String]) -> Parsed {
        let raw = (fields["run"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return Parsed(field: "", commands: []) }
        if raw.hasPrefix("{"), let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let list = obj.keys.sorted().compactMap { k -> RunCommand? in
                guard let c = (obj[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
                return RunCommand(name: k, command: c)
            }
            return Parsed(field: raw, commands: list)
        }
        let one = WorktreeScripts.clean(raw)
        return Parsed(field: raw, commands: one.isEmpty ? [] : [RunCommand(name: defaultName, command: one)])
    }

    public static func load(projectAt url: URL) -> Parsed {
        guard let text = try? String(contentsOf: url.appendingPathComponent("about.md"), encoding: .utf8) else {
            return Parsed(field: "", commands: [])
        }
        return parse(Frontmatter.parse(text).fields)
    }

    // MARK: Output

    /// Without terminal escape sequences (colors, cursor moves) and carriage returns.
    public static func plain(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Last `limit` characters, cut at a line start.
    public static func trimLog(_ text: String, limit: Int = 60_000) -> String {
        guard text.count > limit else { return text }
        let cut = String(text.suffix(limit * 3 / 4))
        if let nl = cut.firstIndex(of: "\n") { return String(cut[cut.index(after: nl)...]) }
        return cut
    }

    /// First local URL port in the output: `http://localhost:3000`, `Local: http://127.0.0.1:5173/`, `listening on port 8080`.
    public static func port(in output: String) -> Int? {
        let text = plain(output)
        let patterns = [
            #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|[A-Za-z0-9.-]+\.local):(\d{2,5})"#,
            #"(?i)listening\s+(?:on|at)\s+(?:\S*:|port\s+)(\d{2,5})"#,
            #"(?i)\bport\s*(?:is|:|=)?\s*(\d{2,5})\b"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text), let n = Int(text[r]), (1...65535).contains(n) else { continue }
            return n
        }
        return nil
    }

    // MARK: Ports

    /// A port nobody listens on, from `start`, not in `avoiding` (ports given to other servers that may not listen yet).
    public static func freePort(from start: Int = 3000, avoiding: Set<Int> = []) -> Int? {
        for p in start..<min(start + 500, 65535) where !avoiding.contains(p) && isFree(p) { return p }
        return nil
    }

    /// Both IPv4 and IPv6 wildcard must be bindable: dev servers use either.
    public static func isFree(_ port: Int) -> Bool {
        func tryBind(_ family: Int32) -> Bool {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { return true }
            defer { close(fd) }
            if family == AF_INET {
                var a = sockaddr_in()
                a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                a.sin_family = sa_family_t(AF_INET)
                a.sin_port = in_port_t(port).bigEndian
                return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
            }
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = in_port_t(port).bigEndian
            return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } == 0
        }
        return tryBind(AF_INET) && tryBind(AF_INET6)
    }
}
