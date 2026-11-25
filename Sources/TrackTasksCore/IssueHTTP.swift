import Foundation

public struct IssueHTTPResponse: Sendable {
    public var status: Int
    /// Names in lower case.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }
}

/// One HTTP exchange; tests put recorded answers here.
public protocol IssueTransport: Sendable {
    func send(_ request: URLRequest) async throws -> IssueHTTPResponse
}

/// URLSession without cache, cookies and stored credentials. Redirects are not followed: a token in a custom
/// header would go along. Errors are replaced with `IssueSourceError`: the original ones contain the URL.
public struct IssueHTTP: IssueTransport {
    public static let timeout: TimeInterval = 30
    let maxBytes: Int

    public init(maxBytes: Int = 16 * 1024 * 1024) { self.maxBytes = maxBytes }

    public func send(_ request: URLRequest) async throws -> IssueHTTPResponse {
        guard let url = request.url, let host = url.host(), !host.isEmpty,
              PushRequestBuilder.serverAllowed(url.absoluteString) else { throw IssueSourceError.notConfigured("адрес (https://…)") }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout * 2
        let fetch = Fetch(limit: maxBytes)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: fetch, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                fetch.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Delegate calls come one by one; `continuation` is set before the task starts.
    private final class Fetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let limit: Int
        var continuation: CheckedContinuation<IssueHTTPResponse, Error>?
        private var body = Data()
        private var tooLarge = false

        init(limit: Int) { self.limit = limit }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !tooLarge else { return }
            if body.count + data.count > limit {
                tooLarge = true
                dataTask.cancel()
            } else { body.append(data) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let c = continuation
            continuation = nil
            if tooLarge { c?.resume(throwing: IssueSourceError.tooLarge); return }
            if let error {
                c?.resume(throwing: (error as? URLError)?.code == .timedOut ? IssueSourceError.timeout : .network)
                return
            }
            guard let r = task.response as? HTTPURLResponse else { c?.resume(throwing: IssueSourceError.badResponse); return }
            var h: [String: String] = [:]
            for (k, v) in r.allHeaderFields { if let k = k as? String, let v = v as? String { h[k] = v } }
            c?.resume(returning: IssueHTTPResponse(status: r.statusCode, headers: h, body: body))
        }
    }
}

// MARK: Shared by the sources

enum IssueAPI {
    /// Percent-encodes everything but unreserved characters, `/` and `&` included.
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    static func get(_ url: String, query: [(String, String)] = [], headers: [String: String]) throws -> URLRequest {
        let q = query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        guard let u = URL(string: url + (q.isEmpty ? "" : "?" + q)) else { throw IssueSourceError.notConfigured("адрес (https://…)") }
        var r = URLRequest(url: u, timeoutInterval: IssueHTTP.timeout)
        r.httpMethod = "GET"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    static func check(_ r: IssueHTTPResponse) throws {
        switch r.status {
        case 200..<300: return
        case 300..<400: throw IssueSourceError.redirect
        case 400, 422: throw IssueSourceError.badRequest
        case 401, 403: throw IssueSourceError.noAccess
        case 404, 410: throw IssueSourceError.notFound
        case 429: throw IssueSourceError.rateLimited
        default: throw IssueSourceError.http(r.status)
        }
    }

    static func object(_ r: IssueHTTPResponse) throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else { throw IssueSourceError.badResponse }
        return o
    }

    static func array(_ r: IssueHTTPResponse) throws -> [Any] {
        guard let a = try? JSONSerialization.jsonObject(with: r.body) as? [Any] else { throw IssueSourceError.badResponse }
        return a
    }

    struct Page {
        var items: [IssueInfo?]
        /// Cursor of the next page, nil on the last one.
        var next: String?
    }

    /// Collects pages up to the filter's limit. `fetch` gets the cursor (nil = first page) and the page size.
    static func pages(_ filter: IssueFilter, pageSize: Int = 100, _ fetch: (String?, Int) async throws -> Page) async throws -> IssueList {
        let limit = min(max(filter.limit, 1), 200)
        let size = min(limit, pageSize)
        var out: [IssueInfo] = [], seen: Set<String> = [], cursors: Set<String> = []
        var skipped = 0, cursor: String?, more = false
        // A server that keeps giving short pages or the same cursor does not hold us.
        for _ in 0..<20 {
            try Task.checkCancellation()
            let p = try await fetch(cursor, size)
            let good = p.items.compactMap { $0 }
            if good.isEmpty, !p.items.isEmpty, out.isEmpty { throw IssueSourceError.badResponse }
            skipped += p.items.count - good.count
            for i in good where seen.insert(IssueRef.key(i.url)).inserted { out.append(i) }
            guard let n = p.next, !n.isEmpty else { more = false; break }
            more = true
            if out.count >= limit || !cursors.insert(n).inserted { break }
            cursor = n
        }
        return IssueList(issues: Array(out.prefix(limit)), hasMore: more || out.count > limit, skipped: skipped)
    }

    static func string(_ v: Any?) -> String { v as? String ?? "" }
    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    static func dict(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
