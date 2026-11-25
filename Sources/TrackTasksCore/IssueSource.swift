import Foundation

public enum IssueSourceID: String, Sendable, CaseIterable, Codable {
    case github, linear, jira, gitlab, sentry

    public var name: String {
        switch self {
        case .github: "GitHub"
        case .linear: "Linear"
        case .jira: "Jira"
        case .gitlab: "GitLab"
        case .sentry: "Sentry"
        }
    }

    public var supportsLabel: Bool { self != .sentry }
    /// Sources with a token of their own; GitHub goes through `gh`.
    public static let withToken: [IssueSourceID] = [.linear, .jira, .gitlab, .sentry]
}

/// A token that does not show up in `print`, `dump`, string interpolation or an error.
public struct IssueSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) { self.value = value.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isEmpty: Bool { value.isEmpty }
    /// A token goes to a header: nothing but printable ASCII.
    var isValid: Bool { !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 } }
    /// Only for building a request.
    func reveal() -> String { value }

    public var description: String { "<скрыто>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// Carries no URL, header, or response body: those may hold a token or someone's data.
public enum IssueSourceError: Error, Sendable, Equatable {
    case notConfigured(String)
    case noAccess, notFound, rateLimited, badRequest, redirect, tooLarge, network, timeout, badResponse
    case http(Int)
    /// Message of a local tool (`gh`).
    case tool(String)

    public var message: String {
        switch self {
        case .notConfigured(let what): "не настроено: \(what)"
        case .noAccess: "нет доступа: проверьте токен и его права"
        case .notFound: "не найдено: проверьте адрес и проект"
        case .rateLimited: "лимит запросов, попробуйте позже"
        case .badRequest: "сервер не принял запрос: проверьте проект и фильтр"
        case .redirect: "сервер перенаправляет на другой адрес: укажите конечный адрес"
        case .tooLarge: "ответ слишком большой"
        case .network: "нет связи с сервером"
        case .timeout: "сервер не ответил вовремя"
        case .badResponse: "непонятный ответ сервера"
        case .http(let code): "ошибка сервера (\(code))"
        case .tool(let text): text
        }
    }

    static func of(_ error: Error) -> IssueSourceError { error as? IssueSourceError ?? .network }
}

public struct IssueList: Sendable, Equatable {
    public var issues: [IssueInfo]
    /// The source has more than the filter's limit.
    public var hasMore: Bool
    /// Entries of the response that made no sense and were dropped.
    public var skipped: Int

    public init(issues: [IssueInfo], hasMore: Bool = false, skipped: Int = 0) {
        self.issues = issues
        self.hasMore = hasMore
        self.skipped = skipped
    }
}

/// A tracker to import from. Reading only.
public protocol IssueSource: Sendable {
    var id: IssueSourceID { get }
    /// Throws `IssueSourceError.notConfigured` without touching the network.
    func validate() throws
    func list(filter: IssueFilter) async throws -> IssueList
    /// The cheapest request that proves the token works.
    func checkAccess() async throws
}

/// How to reach a source (shared by all projects). The token is kept apart from what goes to UserDefaults.
public struct IssueConnection: Sendable, Equatable {
    public var address: String
    public var email: String
    public var organization: String
    public var token: IssueSecret

    public init(address: String = "", email: String = "", organization: String = "", token: IssueSecret = IssueSecret("")) {
        self.address = address
        self.email = email
        self.organization = organization
        self.token = token
    }

    /// `https://host[:port][/path]` without a trailing slash; empty = the default of the source.
    /// nil: not https (http only for this computer), or a URL with a password, query or fragment.
    public static func base(_ id: IssueSourceID, address: String) -> String? {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if id == .linear { return "https://api.linear.app" }
        if s.isEmpty {
            switch id {
            case .gitlab: return "https://gitlab.com"
            case .sentry: return "https://sentry.io"
            default: return nil
            }
        }
        if !s.contains("://") { s = "https://" + s }
        guard PushRequestBuilder.serverAllowed(s), var c = URLComponents(string: s), let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return nil }
        c.scheme = c.scheme?.lowercased()
        c.host = host.lowercased()
        while c.path.hasSuffix("/") { c.path.removeLast() }
        return c.string
    }

    /// Keychain account. Includes the server: after a change of address the old token is not sent to the new one.
    public static func tokenAccount(_ id: IssueSourceID, address: String) -> String? {
        guard let b = base(id, address: address), let c = URLComponents(string: b), let scheme = c.scheme, let host = c.host else { return nil }
        return "\(id.rawValue) \(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
    }

    /// `scope`: team (Linear) or project (Jira, GitLab, Sentry) of the tracker project.
    public func source(_ id: IssueSourceID, scope: String, transport: IssueTransport = IssueHTTP()) -> IssueSource? {
        let scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        switch id {
        case .github: return nil
        case .linear: return LinearSource(connection: self, team: scope, transport: transport)
        case .jira: return JiraSource(connection: self, project: scope, transport: transport)
        case .gitlab: return GitLabSource(connection: self, project: scope, transport: transport)
        case .sentry: return SentrySource(connection: self, project: scope, transport: transport)
        }
    }

    func requireBase(_ id: IssueSourceID) throws -> String {
        guard let b = Self.base(id, address: address) else { throw IssueSourceError.notConfigured("адрес (https://…)") }
        return b
    }

    func requireToken() throws -> String {
        guard token.isValid else { throw IssueSourceError.notConfigured("токен не сохранён или Keychain не дал доступ") }
        return token.reveal()
    }
}

/// Loads several sources at once: each has its own result, timeout and error.
public enum IssueLoader {
    public static func load(_ sources: [IssueSource], filter: IssueFilter, timeout: TimeInterval = 90)
        async -> [IssueSourceID: Result<IssueList, IssueSourceError>] {
        await withTaskGroup(of: (IssueSourceID, Result<IssueList, IssueSourceError>).self) { group in
            for s in sources { group.addTask { (s.id, await one(s, filter: filter, timeout: timeout)) } }
            var out: [IssueSourceID: Result<IssueList, IssueSourceError>] = [:]
            for await (id, r) in group { out[id] = r }
            return out
        }
    }

    public static func one(_ source: IssueSource, filter: IssueFilter, timeout: TimeInterval = 90) async -> Result<IssueList, IssueSourceError> {
        await limited(timeout) {
            try source.validate()
            return try await source.list(filter: filter)
        }
    }

    public static func check(_ source: IssueSource, timeout: TimeInterval = 60) async -> Result<Bool, IssueSourceError> {
        await limited(timeout) {
            try await source.checkAccess()
            return true
        }
    }

    /// The answer comes in time even if the work ignores cancellation (a task group would wait for it).
    private static func limited<T: Sendable>(_ timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> T)
        async -> Result<T, IssueSourceError> {
        let once = Once<Result<T, IssueSourceError>>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                once.start(c)
                once.add(Task {
                    do { once.finish(.success(try await work())) } catch { once.finish(.failure(.of(error))) }
                })
                once.add(Task {
                    guard (try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))) != nil else { return }
                    once.finish(.failure(.timeout))
                })
            }
        } onCancel: {
            once.finish(.failure(.timeout))
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        private var early: T?
        private var done = false
        private var tasks: [Task<Void, Never>] = []

        func start(_ c: CheckedContinuation<T, Never>) {
            lock.lock()
            if let e = early { lock.unlock(); c.resume(returning: e); return }
            continuation = c
            lock.unlock()
        }

        func add(_ t: Task<Void, Never>) {
            lock.lock()
            if done { lock.unlock(); t.cancel(); return }
            tasks.append(t)
            lock.unlock()
        }

        func finish(_ value: T) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let c = continuation, all = tasks
            continuation = nil
            tasks = []
            if c == nil { early = value }
            lock.unlock()
            c?.resume(returning: value)
            all.forEach { $0.cancel() }
        }
    }
}

// MARK: Issue links

/// Normalized links of Linear, Jira, GitLab and Sentry: the same issue gives the same key.
enum IssueKey {
    static func normalized(_ url: String) -> String? {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        let origin = "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
        let p = c.path.split(separator: "/").map(String.init)
        if host == "linear.app", p.count >= 3, p[1] == "issue", isKey(p[2]) {
            return "https://linear.app/\(p[0].lowercased())/issue/\(p[2].uppercased())"
        }
        // GitLab: `/group/sub/project/-/issues/7`; `work_items` is the newer link to the same issue.
        if p.count >= 4, p[p.count - 3] == "-", ["issues", "work_items"].contains(p[p.count - 2]), isNumber(p[p.count - 1]) {
            return origin + "/" + p.dropLast(3).joined(separator: "/").lowercased() + "/-/issues/" + p[p.count - 1]
        }
        if host == "sentry.io" || host.hasSuffix(".sentry.io") {
            let sub = host.split(separator: ".")[0].description
            if p.count == 2, p[0] == "issues", isNumber(p[1]), host != "sentry.io" { return "https://sentry.io/\(sub)/issues/\(p[1])" }
            if p.count == 4, p[0] == "organizations", p[2] == "issues", isNumber(p[3]) { return "https://sentry.io/\(p[1].lowercased())/issues/\(p[3])" }
            if p.count == 4, p[2] == "issues", isNumber(p[3]) { return "https://sentry.io/\(p[0].lowercased())/issues/\(p[3])" }
        }
        if p.count >= 2, p[p.count - 2] == "browse", isKey(p[p.count - 1]) {
            return origin + "/" + (p.dropLast(2) + ["browse", p[p.count - 1].uppercased()]).joined(separator: "/")
        }
        return nil
    }

    /// `ENG-12`.
    static func isKey(_ s: String) -> Bool { s.range(of: "^[A-Za-z][A-Za-z0-9_]*-[0-9]{1,18}$", options: .regularExpression) != nil && s.count < 64 }
    /// Up to 18 digits: always fits `Int`.
    static func isNumber(_ s: String) -> Bool { !s.isEmpty && s.utf8.count <= 18 && s.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
}
