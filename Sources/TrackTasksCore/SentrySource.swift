import Foundation

/// Sentry: issues of an organization. Only title, culprit and level are read: events hold personal data,
/// counters and `lastSeen` change all the time and would make every task "changed".
struct SentrySource: IssueSource {
    let id = IssueSourceID.sentry
    let connection: IssueConnection
    let project: String
    let transport: IssueTransport

    func validate() throws { _ = try endpoint(); _ = try headers() }

    /// The issue list needs the same right as the import, an organization request would need one more.
    func checkAccess() async throws {
        let r = try await transport.send(IssueAPI.get(endpoint().url, query: [("limit", "1"), ("collapse", "stats")], headers: headers()))
        try IssueAPI.check(r)
        _ = try IssueAPI.array(r)
    }

    func list(filter: IssueFilter) async throws -> IssueList {
        let e = try endpoint(), h = try headers()
        var common = [("query", Self.query(filter)), ("statsPeriod", "90d"), ("sort", "date"), ("collapse", "stats")]
        if !project.isEmpty { common.append(("project", project)) }
        return try await IssueAPI.pages(filter) { [common] cursor, size in
            let r = try await transport.send(IssueAPI.get(e.url, query: common + [("limit", String(size))] + (cursor.map { [("cursor", $0)] } ?? []), headers: h))
            try IssueAPI.check(r)
            return .init(items: try IssueAPI.array(r).map { Self.issue($0, base: e.base, org: e.org) }, next: Self.cursor(r.headers["link"] ?? ""))
        }
    }

    private func endpoint() throws -> (url: String, base: String, org: String) {
        let base = try connection.requireBase(.sentry)
        let org = IssueAPI.trim(connection.organization).lowercased()
        guard org.range(of: "^[a-z0-9_-]+$", options: .regularExpression) != nil else { throw IssueSourceError.notConfigured("организация Sentry (slug)") }
        return (base + "/api/0/organizations/\(org)/issues/", base, org)
    }

    private func headers() throws -> [String: String] { ["Authorization": "Bearer " + (try connection.requireToken())] }

    static func query(_ f: IssueFilter) -> String {
        var q: [String] = []
        switch f.state {
        case .open: q.append("is:unresolved")
        case .closed: q.append("is:resolved")
        case .all: break
        }
        let who = IssueAPI.trim(f.assignee), text = IssueAPI.trim(f.search)
        if who == "@me" { q.append("assigned:me") }
        else if !who.isEmpty { q.append("assigned:\"" + who.replacingOccurrences(of: "\"", with: "") + "\"") }
        if !text.isEmpty { q.append(text) }
        return q.joined(separator: " ")
    }

    /// `<…>; rel="next"; results="true"; cursor="0:100:0"`. Only the cursor is taken, not the address.
    static func cursor(_ link: String) -> String? {
        for part in link.components(separatedBy: ", <") where part.contains("rel=\"next\"") && part.contains("results=\"true\"") {
            guard let r = part.range(of: "cursor=\"[0-9:-]+\"", options: .regularExpression) else { continue }
            return String(part[r].dropFirst(8).dropLast())
        }
        return nil
    }

    /// The link is built from the configured server, the one in the answer is not trusted.
    static func issue(_ v: Any, base: String, org: String) -> IssueInfo? {
        let o = IssueAPI.dict(v)
        let id = IssueAPI.string(o["id"])
        guard IssueKey.isNumber(id) else { return nil }
        let host = URLComponents(string: base)?.host ?? ""
        let cloud = host == "sentry.io" || host.hasSuffix(".sentry.io")
        let level = IssueAPI.string(o["level"])
        let priority: String? = switch IssueAPI.string(o["priority"]) {
        case "high", "medium", "low": IssueAPI.string(o["priority"])
        default: level == "fatal" ? "high" : ["info", "debug"].contains(level) ? "low" : nil
        }
        let culprit = IssueAPI.string(o["culprit"])
        let short = IssueAPI.string(o["shortId"])
        let body = [culprit.isEmpty ? "" : "Где: \(culprit)", level.isEmpty ? "" : "Уровень: \(level)"].filter { !$0.isEmpty }
        return IssueInfo(number: Int(id) ?? 0, title: IssueAPI.string(o["title"]), body: body.joined(separator: "\n"),
                         isOpen: !["resolved", "ignored"].contains(IssueAPI.string(o["status"])),
                         url: cloud ? "https://sentry.io/organizations/\(org)/issues/\(id)/" : "\(base)/organizations/\(org)/issues/\(id)/",
                         source: .sentry, key: short.isEmpty ? id : String(short.prefix(80)), priority: priority)
    }
}
