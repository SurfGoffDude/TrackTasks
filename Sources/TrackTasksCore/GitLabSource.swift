import Foundation

/// GitLab REST v4: gitlab.com or an own server.
struct GitLabSource: IssueSource {
    let id = IssueSourceID.gitlab
    let connection: IssueConnection
    let project: String
    let transport: IssueTransport

    func validate() throws {
        _ = try headers()
        _ = try connection.requireBase(.gitlab)
        guard !project.isEmpty else { throw IssueSourceError.notConfigured("проект GitLab (группа/проект)") }
    }

    func checkAccess() async throws {
        let h = try headers(), base = try connection.requireBase(.gitlab)
        try IssueAPI.check(try await transport.send(IssueAPI.get(base + "/api/v4/user", headers: h)))
    }

    func list(filter: IssueFilter) async throws -> IssueList {
        try validate()
        let h = try headers(), base = try connection.requireBase(.gitlab)
        let url = base + "/api/v4/projects/" + IssueAPI.encode(project) + "/issues"
        var common = [("state", filter.state == .open ? "opened" : filter.state.rawValue), ("order_by", "updated_at")]
        let label = IssueAPI.trim(filter.label), who = IssueAPI.trim(filter.assignee), text = IssueAPI.trim(filter.search)
        if !label.isEmpty { common.append(("labels", label)) }
        if who == "@me" { common.append(("scope", "assigned_to_me")) } else if !who.isEmpty { common.append(("assignee_username", who)) }
        if !text.isEmpty { common.append(("search", text)) }
        return try await IssueAPI.pages(filter) { [common] cursor, size in
            let r = try await transport.send(IssueAPI.get(url, query: common + [("per_page", String(size)), ("page", cursor ?? "1")], headers: h))
            try IssueAPI.check(r)
            // Only the number is taken: the address of the next page is built here.
            let next = IssueAPI.trim(r.headers["x-next-page"] ?? "")
            return .init(items: try IssueAPI.array(r).map { Self.issue($0, base: base) }, next: IssueKey.isNumber(next) ? next : nil)
        }
    }

    private func headers() throws -> [String: String] { ["PRIVATE-TOKEN": try connection.requireToken()] }

    static func issue(_ v: Any, base: String) -> IssueInfo? {
        let o = IssueAPI.dict(v)
        guard let n = IssueAPI.int(o["iid"]), n > 0, var c = URLComponents(string: IssueAPI.string(o["web_url"])),
              let b = URLComponents(string: base), c.scheme?.lowercased() == b.scheme, c.host?.lowercased() == b.host, c.port == b.port,
              c.user == nil, c.password == nil, c.path.hasSuffix("/issues/\(n)") || c.path.hasSuffix("/-/work_items/\(n)") else { return nil }
        c.query = nil
        c.fragment = nil
        guard let url = c.string else { return nil }
        return IssueInfo(number: n, title: IssueAPI.string(o["title"]), body: IssueAPI.string(o["description"]),
                         isOpen: IssueAPI.string(o["state"]) != "closed", url: url,
                         labels: (o["labels"] as? [Any] ?? []).compactMap { $0 as? String },
                         author: IssueAPI.string(IssueAPI.dict(o["author"])["username"]),
                         updatedAt: IssueAPI.string(o["updated_at"]), source: .gitlab)
    }
}
