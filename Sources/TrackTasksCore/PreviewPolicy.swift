import Foundation

/// Which addresses the preview of a task's dev server may show. Everything on the page is untrusted.
public struct PreviewPolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case show
        /// Another site: only the person may open it, in their own browser.
        case offerOutside(URL)
        case deny
    }

    /// The only port whose pages are shown.
    public let port: Int
    /// Other servers of the same task (an API): the page may ask them, but they aren't shown.
    public let others: Set<Int>

    public static let hosts = ["localhost", "127.0.0.1", "[::1]"]

    public init(port: Int, others: Set<Int> = []) {
        self.port = port
        self.others = others.subtracting([port])
    }

    public var start: URL? { URL(string: "http://localhost:\(port)/") }

    /// For navigation and redirects, of the page and of its frames.
    public func decide(_ url: URL?, mainFrame: Bool = true) -> Decision {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: true), let scheme = c.scheme?.lowercased() else { return .deny }
        // Empty frames and `srcdoc` belong to the page that made them.
        if !mainFrame, ["about:blank", "about:srcdoc"].contains(url.absoluteString.lowercased()) { return .show }
        guard ["http", "https"].contains(scheme), c.user == nil, c.password == nil, let host = c.host?.lowercased(), !host.isEmpty else { return .deny }
        if scheme == "http", Self.isLocal(host), (c.port ?? 80) == port { return .show }
        return mainFrame ? .offerOutside(url) : .deny
    }

    /// Elements are picked only on the page of this server, and while it is known to be this task's.
    public func canPick(_ url: URL?, mainFrame: Bool, serverConfirmed: Bool) -> Bool {
        serverConfirmed && mainFrame && decide(url) == .show
    }

    private static func isLocal(_ host: String) -> Bool { host == "::1" || hosts.contains(host) }

    /// `WKContentRuleList`: nothing is loaded but these ports; WebSocket too (hot reload). No `|` in its patterns.
    public var rules: String {
        var list: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        func allow(_ pattern: String) {
            list.append(["trigger": ["url-filter": pattern, "url-filter-is-case-sensitive": true], "action": ["type": "ignore-previous-rules"]])
        }
        for p in [port] + others.sorted() {
            for h in Self.hosts {
                let host = h.replacingOccurrences(of: ".", with: "\\.").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                for s in ["http", "ws"] {
                    allow("^\(s)://\(host):\(p)/")
                    if p == 80 { allow("^\(s)://\(host)/") }
                }
            }
        }
        // Made by the page itself; they can't be navigated to.
        for s in ["data", "blob"] { allow("^\(s):") }
        let data = (try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
