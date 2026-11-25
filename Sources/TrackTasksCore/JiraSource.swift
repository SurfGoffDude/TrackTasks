import Foundation

/// Jira Cloud REST v3, Basic auth (email + API token).
struct JiraSource: IssueSource {
    let id = IssueSourceID.jira
    let connection: IssueConnection
    let project: String
    let transport: IssueTransport

    func validate() throws {
        _ = try headers()
        _ = try connection.requireBase(.jira)
        // Jira refuses a search without restrictions.
        guard !project.isEmpty else { throw IssueSourceError.notConfigured("ключ проекта Jira") }
    }

    func checkAccess() async throws {
        let h = try headers(), base = try connection.requireBase(.jira)
        try Self.check(try await transport.send(IssueAPI.get(base + "/rest/api/3/myself", headers: h)))
    }

    func list(filter: IssueFilter) async throws -> IssueList {
        try validate()
        let h = try headers(), base = try connection.requireBase(.jira), jql = Self.jql(filter, project: project)
        return try await IssueAPI.pages(filter) { cursor, size in
            var q = [("jql", jql), ("maxResults", String(size)), ("fields", "summary,description,status,labels,priority,reporter,updated")]
            if let cursor { q.append(("nextPageToken", cursor)) }
            let r = try await transport.send(IssueAPI.get(base + "/rest/api/3/search/jql", query: q, headers: h))
            try Self.check(r)
            let o = try IssueAPI.object(r)
            guard let items = o["issues"] as? [Any] else { throw IssueSourceError.badResponse }
            return .init(items: items.map { Self.issue($0, base: base) },
                         next: o["isLast"] as? Bool == true ? nil : o["nextPageToken"] as? String)
        }
    }

    private func headers() throws -> [String: String] {
        let email = IssueAPI.trim(connection.email)
        guard !email.isEmpty, !email.contains(":") else { throw IssueSourceError.notConfigured("email") }
        return ["Authorization": "Basic " + Data("\(email):\(try connection.requireToken())".utf8).base64EncodedString()]
    }

    /// With a wrong token Jira answers as to a stranger: 200 and only public issues (or an empty list).
    private static func check(_ r: IssueHTTPResponse) throws {
        try IssueAPI.check(r)
        if let why = r.headers["x-seraph-loginreason"], why.contains("AUTHENTICATED_FAILED") || why.contains("AUTHENTICATION_DENIED") {
            throw IssueSourceError.noAccess
        }
    }

    static func jql(_ f: IssueFilter, project: String) -> String {
        var c = ["project = \(quote(project))"]
        switch f.state {
        case .open: c.append("statusCategory != Done")
        case .closed: c.append("statusCategory = Done")
        case .all: break
        }
        let label = IssueAPI.trim(f.label), who = IssueAPI.trim(f.assignee), text = IssueAPI.trim(f.search)
        if !label.isEmpty { c.append("labels = \(quote(label))") }
        if who == "@me" { c.append("assignee = currentUser()") } else if !who.isEmpty { c.append("assignee = \(quote(who))") }
        if !text.isEmpty { c.append("text ~ \(quote(text))") }
        return c.joined(separator: " AND ") + " ORDER BY updated DESC"
    }

    private static func quote(_ s: String) -> String {
        let clean = s.unicodeScalars.filter { $0.properties.generalCategory != .control }.map(String.init).joined()
        return "\"" + clean.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func issue(_ v: Any, base: String) -> IssueInfo? {
        let o = IssueAPI.dict(v)
        let key = IssueAPI.string(o["key"]).uppercased()
        guard IssueKey.isKey(key), let f = o["fields"] as? [String: Any] else { return nil }
        let priority: String? = switch IssueAPI.string(IssueAPI.dict(f["priority"])["name"]).lowercased() {
        case "highest", "high", "critical", "blocker", "urgent": "high"
        case "medium", "major", "normal": "medium"
        case "low", "lowest", "minor", "trivial": "low"
        default: nil
        }
        let category = IssueAPI.string(IssueAPI.dict(IssueAPI.dict(f["status"])["statusCategory"])["key"])
        return IssueInfo(number: Int(key.split(separator: "-").last ?? "") ?? 0, title: IssueAPI.string(f["summary"]),
                         body: (f["description"] as? String) ?? text(adf: f["description"]), isOpen: category != "done",
                         url: base + "/browse/" + key, labels: (f["labels"] as? [Any] ?? []).compactMap { $0 as? String },
                         author: IssueAPI.string(IssueAPI.dict(f["reporter"])["displayName"]),
                         updatedAt: IssueAPI.string(f["updated"]), source: .jira, key: key, priority: priority)
    }

    /// Atlassian Document Format as plain text. An unknown node gives its text.
    static func text(adf v: Any?) -> String {
        func walk(_ v: Any?, _ depth: Int) -> String {
            guard depth < 50, let n = v as? [String: Any] else { return "" }
            let attrs = IssueAPI.dict(n["attrs"])
            let inner = (n["content"] as? [Any] ?? []).map { walk($0, depth + 1) }.joined()
            switch IssueAPI.string(n["type"]) {
            case "text": return IssueAPI.string(n["text"])
            case "hardBreak": return "\n"
            case "paragraph", "heading", "codeBlock": return inner + "\n"
            case "rule": return "---\n"
            case "listItem", "taskItem", "decisionItem": return "- " + inner + (inner.hasSuffix("\n") ? "" : "\n")
            case "tableCell", "tableHeader": return inner.trimmingCharacters(in: .newlines) + " | "
            case "tableRow": return inner + "\n"
            case "emoji": return IssueAPI.string(attrs["text"] ?? attrs["shortName"])
            case "inlineCard", "blockCard", "embedCard": return IssueAPI.string(attrs["url"])
            default:
                let own = IssueAPI.string(n["text"]) + inner
                return own.isEmpty ? IssueAPI.string(attrs["text"]) : own
            }
        }
        return walk(v, 0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
