import Foundation
import TrackTasksCore

/// Connections to the trackers: tokens in Keychain, the rest in UserDefaults. The team/project is per project
/// and not in about.md: agents edit that file.
enum IssueSourceStore {
    static let service = "TrackTasks.issues"
    private static let scopesKey = "issueScopes"
    private static var d: UserDefaults { .standard }

    static func enabledKey(_ id: IssueSourceID) -> String { "issues.\(id.rawValue).enabled" }
    static func addressKey(_ id: IssueSourceID) -> String { "issues.\(id.rawValue).address" }
    static func emailKey(_ id: IssueSourceID) -> String { "issues.\(id.rawValue).email" }
    static func organizationKey(_ id: IssueSourceID) -> String { "issues.\(id.rawValue).organization" }

    static var enabled: [IssueSourceID] { IssueSourceID.withToken.filter { d.bool(forKey: enabledKey($0)) } }

    /// Reads the token from Keychain: call off the main thread.
    static func connection(_ id: IssueSourceID) -> IssueConnection {
        let address = d.string(forKey: addressKey(id)) ?? ""
        let token = IssueConnection.tokenAccount(id, address: address).map { Keychain.get(service: service, account: $0) } ?? ""
        return IssueConnection(address: address, email: d.string(forKey: emailKey(id)) ?? "",
                               organization: d.string(forKey: organizationKey(id)) ?? "", token: IssueSecret(token))
    }

    static func hasToken(_ id: IssueSourceID, address: String) -> Bool {
        IssueConnection.tokenAccount(id, address: address).map { Keychain.exists(service: service, account: $0) } ?? false
    }

    /// An empty token removes the record.
    static func saveToken(_ id: IssueSourceID, address: String, _ token: String) -> Bool {
        guard let account = IssueConnection.tokenAccount(id, address: address) else { return false }
        return Keychain.set(service: service, account: account, token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static var scopes: [String: [String: String]] { d.dictionary(forKey: scopesKey) as? [String: [String: String]] ?? [:] }

    static func scope(_ id: IssueSourceID, project: String) -> String { scopes[project]?[id.rawValue] ?? "" }

    static func setScope(_ id: IssueSourceID, project: String, _ value: String) {
        var all = scopes
        all[project, default: [:]][id.rawValue] = value.isEmpty ? nil : value
        if all[project]?.isEmpty == true { all[project] = nil }
        d.set(all, forKey: scopesKey)
    }
}

/// GitHub through the installed `gh`: the app has no token for it.
struct GitHubSource: IssueSource {
    let id = IssueSourceID.github
    let repo: GitHubRepo
    let dir: URL

    func validate() throws {}

    func checkAccess() async throws {
        let r = await run { GitHubCLI.authStatus(repo.host, in: dir) }
        if !r.ok { throw IssueSourceError.noAccess }
    }

    func list(filter: IssueFilter) async throws -> IssueList {
        let r = await run { GitHubCLI.run(filter.arguments(repo: repo), in: dir) }
        guard r.ok else { throw IssueSourceError.tool(r.err.isEmpty ? "gh не сработал" : r.err) }
        guard let issues = IssueInfo.parseList(r.out) else { throw IssueSourceError.tool("gh вернул непонятный ответ") }
        return IssueList(issues: issues, hasMore: issues.count >= min(max(filter.limit, 1), 200))
    }

    /// `gh` blocks its thread: not on the cooperative pool.
    private func run(_ work: @escaping @Sendable () -> Worktrees.Result) async -> Worktrees.Result {
        await withCheckedContinuation { c in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) } }
    }
}
