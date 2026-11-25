import Foundation

/// Linear GraphQL. A personal API key goes to `Authorization` without `Bearer`.
struct LinearSource: IssueSource {
    let id = IssueSourceID.linear
    let connection: IssueConnection
    let team: String
    let transport: IssueTransport

    static let query = """
    query($filter: IssueFilter, $first: Int, $after: String) { issues(filter: $filter, first: $first, after: $after, orderBy: updatedAt) { \
    nodes { identifier title description url priority updatedAt state { type } labels(first: 50) { nodes { name } } creator { displayName } } \
    pageInfo { hasNextPage endCursor } } }
    """
    static let closed = ["completed", "canceled", "duplicate"]

    func validate() throws { _ = try connection.requireToken() }

    func checkAccess() async throws { _ = try await send("query { viewer { id } }", [:]) }

    func list(filter: IssueFilter) async throws -> IssueList {
        let f = Self.filter(filter, team: team)
        return try await IssueAPI.pages(filter) { cursor, size in
            let data = try await send(Self.query, ["filter": f, "first": size, "after": cursor ?? NSNull()])
            guard let issues = data["issues"] as? [String: Any], let nodes = issues["nodes"] as? [Any] else { throw IssueSourceError.badResponse }
            let info = IssueAPI.dict(issues["pageInfo"])
            let next = info["hasNextPage"] as? Bool == true ? info["endCursor"] as? String : nil
            return .init(items: nodes.map(Self.issue), next: next)
        }
    }

    /// Values are GraphQL variables, never part of the query text.
    static func filter(_ f: IssueFilter, team: String) -> [String: Any] {
        var o: [String: Any] = [:]
        if !team.isEmpty { o["team"] = ["key": ["eqIgnoreCase": team]] }
        switch f.state {
        case .open: o["state"] = ["type": ["nin": closed]]
        case .closed: o["state"] = ["type": ["in": closed]]
        case .all: break
        }
        let label = IssueAPI.trim(f.label), who = IssueAPI.trim(f.assignee), text = IssueAPI.trim(f.search)
        if !label.isEmpty { o["labels"] = ["some": ["name": ["eqIgnoreCase": label]]] }
        if who == "@me" { o["assignee"] = ["isMe": ["eq": true]] }
        else if !who.isEmpty { o["assignee"] = ["or": [["email": ["eqIgnoreCase": who]], ["displayName": ["eqIgnoreCase": who]]]] }
        if !text.isEmpty { o["or"] = [["title": ["containsIgnoreCase": text]], ["description": ["containsIgnoreCase": text]]] }
        return o
    }

    private func send(_ query: String, _ variables: [String: Any]) async throws -> [String: Any] {
        var r = try IssueAPI.get(try connection.requireBase(.linear) + "/graphql", headers: ["Authorization": try connection.requireToken(),
                                                                                             "Content-Type": "application/json"])
        // Only `query` operations: GraphQL has no GET here.
        r.httpMethod = "POST"
        r.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let a = try await transport.send(r)
        // Errors come with 200 as well as with 4xx; the code says more than the status.
        let body = try? IssueAPI.object(a)
        if let errors = body?["errors"] as? [Any], !errors.isEmpty {
            let codes = errors.map { IssueAPI.string(IssueAPI.dict(IssueAPI.dict($0)["extensions"])["code"]) }
            if codes.contains("RATELIMITED") { throw IssueSourceError.rateLimited }
            if !Set(codes).isDisjoint(with: ["AUTHENTICATION_ERROR", "FORBIDDEN"]) { throw IssueSourceError.noAccess }
            try IssueAPI.check(a)
            throw IssueSourceError.badRequest
        }
        try IssueAPI.check(a)
        guard let data = body?["data"] as? [String: Any] else { throw IssueSourceError.badResponse }
        return data
    }

    static func issue(_ v: Any) -> IssueInfo? {
        let o = IssueAPI.dict(v)
        let key = IssueAPI.string(o["identifier"]).uppercased()
        // The end of the link is the title and changes with it: the normalized link is kept.
        guard IssueKey.isKey(key), let url = IssueKey.normalized(IssueAPI.string(o["url"])),
              url.hasPrefix("https://linear.app/"), url.hasSuffix("/issue/" + key) else { return nil }
        let labels = (IssueAPI.dict(o["labels"])["nodes"] as? [Any] ?? []).map { IssueAPI.string(IssueAPI.dict($0)["name"]) }.filter { !$0.isEmpty }
        let priority: String? = switch IssueAPI.int(o["priority"]) {
        case 1, 2: "high"
        case 3: "medium"
        case 4: "low"
        default: nil
        }
        return IssueInfo(number: Int(key.split(separator: "-").last ?? "") ?? 0, title: IssueAPI.string(o["title"]),
                         body: IssueAPI.string(o["description"]),
                         isOpen: !closed.contains(IssueAPI.string(IssueAPI.dict(o["state"])["type"])), url: url, labels: labels,
                         author: IssueAPI.string(IssueAPI.dict(o["creator"])["displayName"]),
                         updatedAt: IssueAPI.string(o["updatedAt"]), source: .linear, key: key, priority: priority)
    }
}
