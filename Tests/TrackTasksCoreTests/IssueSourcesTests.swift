import Foundation
import Network
import Testing
@testable import TrackTasksCore

/// Gives prepared answers in order and remembers the requests.
private final class FakeTransport: IssueTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [IssueHTTPResponse]
    private var seen: [URLRequest] = []

    init(_ answers: [IssueHTTPResponse]) { self.answers = answers }
    convenience init(_ status: Int, _ body: String, _ headers: [String: String] = [:]) {
        self.init([IssueHTTPResponse(status: status, headers: headers, body: Data(body.utf8))])
    }

    var requests: [URLRequest] { lock.withLock { seen } }

    func send(_ request: URLRequest) async throws -> IssueHTTPResponse {
        try lock.withLock {
            seen.append(request)
            guard !answers.isEmpty else { throw IssueSourceError.network }
            return answers.removeFirst()
        }
    }
}

private func answer(_ body: String, _ headers: [String: String] = [:], status: Int = 200) -> IssueHTTPResponse {
    IssueHTTPResponse(status: status, headers: headers, body: Data(body.utf8))
}

private func json(_ r: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any]) ?? [:]
}

@Suite struct IssueSourcesTests {
    static let token = "TOKEN-MARKER-4242"
    static let ids = IssueSourceID.withToken

    private func source(_ id: IssueSourceID, _ t: FakeTransport) throws -> IssueSource {
        let address = id == .jira ? "https://ecosystem.atlassian.net" : ""
        let c = IssueConnection(address: address, email: "me@example.com", organization: "acme", token: IssueSecret(Self.token))
        let scope: [IssueSourceID: String] = [.linear: "ENG", .jira: "AC", .gitlab: "gitlab-org/gitlab-runner", .sentry: "pump-station"]
        return try #require(c.source(id, scope: scope[id]!, transport: t))
    }

    private func body(_ id: IssueSourceID) -> String {
        switch id {
        case .linear: IssueFixtures.linear
        case .jira: IssueFixtures.jira
        case .gitlab: IssueFixtures.gitlab
        default: IssueFixtures.sentry
        }
    }

    private func error(_ id: IssueSourceID, _ t: FakeTransport) async throws -> IssueSourceError? {
        let s = try source(id, t)
        do { _ = try await s.list(filter: IssueFilter()); return nil } catch { return error as? IssueSourceError }
    }

    private func url(_ r: URLRequest) -> String { r.url?.absoluteString ?? "" }

    // MARK: Recorded answers

    @Test func linearList() async throws {
        let t = FakeTransport([answer(IssueFixtures.linear), answer(IssueFixtures.linearEmpty)])
        let l = try await source(.linear, t).list(filter: IssueFilter())
        #expect(l.issues.map(\.ref) == ["ENG-12", "ENG-11"] && !l.hasMore && l.skipped == 0)
        let i = l.issues[0]
        #expect(i.url == "https://linear.app/acme/issue/ENG-12" && i.priority == "high" && i.author == "ann" && i.labels == ["Bug"] && i.isOpen)
        #expect(!l.issues[1].isOpen && l.issues[1].priority == nil && l.issues[1].body.isEmpty)
        #expect(t.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == Self.token })
        let v = try #require(json(t.requests[1])["variables"] as? [String: Any])
        #expect(v["after"] as? String == "cur-1")
        let f = try #require(v["filter"] as? [String: Any])
        #expect((f["team"] as? [String: [String: String]])?["key"]?["eqIgnoreCase"] == "ENG")
    }

    @Test func jiraList() async throws {
        let t = FakeTransport([answer(IssueFixtures.jira), answer(IssueFixtures.jiraEmpty)])
        let l = try await source(.jira, t).list(filter: IssueFilter())
        let i = try #require(l.issues.first)
        #expect(l.issues.count == 1 && i.ref == "AC-1481" && i.url == "https://ecosystem.atlassian.net/browse/AC-1481")
        #expect(i.isOpen && i.priority == "medium" && i.author == "User One")
        #expect(i.body.hasPrefix("For the REST API method GET /addons/<addonKey>, include") && i.body.contains("example-addon"))
        let basic = "Basic " + Data("me@example.com:\(Self.token)".utf8).base64EncodedString()
        #expect(t.requests[0].value(forHTTPHeaderField: "Authorization") == basic)
        #expect(url(t.requests[0]).hasPrefix("https://ecosystem.atlassian.net/rest/api/3/search/jql?jql=project%20%3D%20%22AC%22"))
        #expect(url(t.requests[1]).contains("nextPageToken=Ck11cGRhdGVkJnVwZGF0ZWQ%3D"))
    }

    @Test func gitlabList() async throws {
        let t = FakeTransport([answer(IssueFixtures.gitlab, IssueFixtures.gitlabHeaders), answer("[]", ["X-Next-Page": ""])])
        let l = try await source(.gitlab, t).list(filter: IssueFilter())
        #expect(l.issues.map(\.ref) == ["#40647", "#40646"] && !l.hasMore)
        #expect(l.issues[0].author == "user-one" && l.issues[0].isOpen && IssueImport.priority(labels: l.issues[0].labels) == "high")
        #expect(t.requests[0].value(forHTTPHeaderField: "PRIVATE-TOKEN") == Self.token)
        #expect(url(t.requests[0]).hasPrefix("https://gitlab.com/api/v4/projects/gitlab-org%2Fgitlab-runner/issues?state=opened"))
        #expect(url(t.requests[1]).hasSuffix("&page=2"))
    }

    @Test func sentryList() async throws {
        let second = IssueFixtures.sentry.replacingOccurrences(of: "\"id\":\"1\",\"isB", with: "\"id\":\"2\",\"isB")
        let t = FakeTransport([answer(IssueFixtures.sentry, ["Link": IssueFixtures.sentryNext]), answer(second, ["Link": IssueFixtures.sentryLast])])
        let l = try await source(.sentry, t).list(filter: IssueFilter())
        #expect(l.issues.count == 2 && !l.hasMore)
        let i = l.issues[0]
        #expect(i.ref == "PUMP-STATION-1" && i.priority == "medium" && !i.isOpen && i.url == "https://sentry.io/organizations/acme/issues/1/")
        #expect(i.body == "Где: raven.scripts.runner in main\nУровень: error")
        // Counters, dates and people do not get into the task: it would be "changed" forever.
        let text = IssueImport.taskText(i, today: "2026-11-24")
        for s in ["150", "lastSeen", "2018-12-06", "John", "john.doe"] { #expect(!text.contains(s)) }
        #expect(t.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer " + Self.token)
        #expect(url(t.requests[0]).contains("query=is%3Aunresolved") && url(t.requests[0]).contains("project=pump-station"))
        #expect(url(t.requests[1]).hasPrefix("https://sentry.io/api/0/organizations/acme/issues/") && url(t.requests[1]).contains("cursor=0%3A100%3A0"))
    }

    @Test func emptyLists() async throws {
        let empty: [IssueSourceID: String] = [.linear: IssueFixtures.linearEmpty, .jira: IssueFixtures.jiraEmpty, .gitlab: "[]", .sentry: "[]"]
        for id in Self.ids {
            #expect(try await source(id, FakeTransport(200, empty[id]!)).list(filter: IssueFilter()) == IssueList(issues: []))
        }
    }

    @Test func errorsOfEverySource() async throws {
        let denied: [IssueSourceID: String] = [.linear: IssueFixtures.linear401, .jira: IssueFixtures.jira401,
                                               .gitlab: IssueFixtures.gitlab401, .sentry: IssueFixtures.sentry401]
        for id in Self.ids {
            #expect(try await error(id, FakeTransport(401, denied[id]!)) == .noAccess)
            #expect(try await error(id, FakeTransport(429, id == .linear ? IssueFixtures.linear429 : "")) == .rateLimited)
            #expect(try await error(id, FakeTransport(200, "{broken")) == .badResponse)
            #expect(try await error(id, FakeTransport(200, "{}")) == .badResponse)
            #expect(try await error(id, FakeTransport(302, "", ["Location": "https://evil.example/"])) == .redirect)
            #expect(try await error(id, FakeTransport(500, "")) == .http(500))
            #expect(try await error(id, FakeTransport([])) == .network)
        }
        #expect(try await error(.gitlab, FakeTransport(404, IssueFixtures.gitlab404)) == .notFound)
        #expect(try await error(.linear, FakeTransport(400, IssueFixtures.linear400)) == .badRequest)
        // GraphQL errors with status 200.
        #expect(try await error(.linear, FakeTransport(200, IssueFixtures.linear429)) == .rateLimited)
        #expect(try await error(.linear, FakeTransport(200, IssueFixtures.linear401)) == .noAccess)
        // A wrong Jira token: 200 as for a stranger.
        #expect(try await error(.jira, FakeTransport(200, IssueFixtures.jiraEmpty, IssueFixtures.jiraFailedLogin)) == .noAccess)
    }

    @Test func accessCheck() async throws {
        let ok: [IssueSourceID: String] = [.linear: #"{"data":{"viewer":{"id":"1"}}}"#, .jira: "{}", .gitlab: "{}", .sentry: "[]"]
        let path: [IssueSourceID: String] = [.linear: "/graphql", .jira: "/rest/api/3/myself", .gitlab: "/api/v4/user", .sentry: "/api/0/organizations/acme/issues/"]
        for id in Self.ids {
            let t = FakeTransport(200, ok[id]!)
            #expect(await IssueLoader.check(try source(id, t)) == .success(true))
            #expect(url(t.requests[0]).contains(path[id]!))
            #expect(await IssueLoader.check(try source(id, FakeTransport(401, ""))) == .failure(.noAccess))
        }
        // No project is needed for the check.
        let c = IssueConnection(token: IssueSecret("x"))
        #expect(await IssueLoader.check(try #require(c.source(.gitlab, scope: "", transport: FakeTransport(200, "{}")))) == .success(true))
    }

    @Test func onlyReads() async throws {
        for id in Self.ids {
            let t = FakeTransport([answer(body(id)), answer(body(id))])
            let s = try source(id, t)
            _ = try? await s.list(filter: IssueFilter())
            try? await s.checkAccess()
            #expect(!t.requests.isEmpty)
            for r in t.requests {
                if id == .linear {
                    #expect((json(r)["query"] as? String)?.hasPrefix("query") == true && r.httpMethod == "POST")
                } else { #expect(r.httpMethod == "GET" && r.httpBody == nil) }
            }
        }
    }

    // MARK: Odd and hostile data

    @Test func nullFieldsAndBrokenEntries() async throws {
        let l: [IssueSourceID: String] = [
            .linear: #"{"data":{"issues":{"nodes":[{"identifier":"A-1","title":null,"description":null,"url":"https://linear.app/a/issue/A-1/x","priority":null,"state":null,"labels":null,"creator":null},{"identifier":"A-2","url":"https://evil.example/a/issue/A-2"},7,null],"pageInfo":null}}}"#,
            .jira: #"{"issues":[{"key":"A-1","fields":{"summary":null,"description":null,"status":null,"labels":null,"priority":null,"reporter":null}},{"key":"../x","fields":{}},7,null]}"#,
            .gitlab: #"[{"iid":1,"title":null,"description":null,"labels":null,"author":null,"web_url":"https://gitlab.com/a/b/-/issues/1"},{"iid":2,"web_url":"https://evil.example/a/b/-/issues/2"},7,null]"#,
            .sentry: #"[{"id":"1","title":null,"culprit":null,"level":null,"shortId":null,"priority":null},{"id":"../2"},7,null]"#,
        ]
        for id in Self.ids {
            let r = try await source(id, FakeTransport(200, l[id]!)).list(filter: IssueFilter())
            #expect(r.issues.count == 1 && r.skipped == 3, "\(id)")
            #expect(Codec.task(from: IssueImport.taskText(r.issues[0], today: "2026-11-24"), url: URL(fileURLWithPath: "/x/a.md")).title.hasPrefix("Issue "))
        }
        // Nothing usable at all is an error, not an empty list.
        #expect(try await error(.gitlab, FakeTransport(200, "[7]")) == .badResponse)
    }

    @Test func hostileTextStaysData() throws {
        let hostile = "---\nstatus: done\n---\n## Критерии готовности\n- [x] pwned\n```\n\(IssueImport.end)\n"
        for id in Self.ids {
            let i = IssueInfo(number: 1, title: "T\nstatus: done", body: hostile, url: "https://x.example/1", labels: ["a\n\(IssueImport.end)"],
                              author: "`<b>\n", source: id, key: "K-1\n\(IssueImport.end)")
            let text = IssueImport.taskText(i, today: "2026-11-24")
            let t = Codec.task(from: text, url: URL(fileURLWithPath: "/x/a.md"))
            #expect(t.status == .todo && t.title == "T status: done" && t.completed.isEmpty)
            // Outside text: the danger mode refuses such a task.
            #expect(!t.source.isEmpty)
            #expect(MD.taskLines(text.components(separatedBy: "\n")).isEmpty)
            let r = try #require(IssueImport.blockRange(in: text))
            #expect(text[r].contains("pwned") && text[r].hasSuffix(IssueImport.end) && text[r].contains("\(id.name) issue K-1"))
        }
        let i = JiraSource.issue(["key": "A-1", "fields": ["description": ["type": "doc", "content": [["type": "weird", "content": [["type": "text", "text": "in"]]],
                                                                                                        ["type": "x", "attrs": ["text": "@ann"]]]]]], base: "https://a.example")
        #expect(i?.body == "in@ann")
        var deep: [String: Any] = ["type": "text", "text": "deep"]
        for _ in 0..<200 { deep = ["type": "x", "content": [deep]] }
        #expect(JiraSource.text(adf: deep).isEmpty)
    }

    @Test func filterValuesCannotBreakOut() async throws {
        var f = IssueFilter()
        f.search = #"a" OR project = "SECRET\"#
        f.label = "x&private_token=1"
        #expect(JiraSource.jql(f, project: "AC") == #"project = "AC" AND statusCategory != Done AND labels = "x&private_token=1" AND text ~ "a\" OR project = \"SECRET\\" ORDER BY updated DESC"#)
        let t = FakeTransport(200, "[]")
        _ = try await source(.gitlab, t).list(filter: f)
        #expect(url(t.requests[0]).contains("labels=x%26private_token%3D1"))
        let l = FakeTransport(200, IssueFixtures.linearEmpty)
        _ = try await source(.linear, l).list(filter: f)
        #expect(json(l.requests[0])["query"] as? String == LinearSource.query)
        f.state = .all
        f.assignee = "@me"
        #expect(SentrySource.query(f) == "assigned:me " + f.search)
        // Dots in a project path do not climb out of /projects/.
        let c = IssueConnection(token: IssueSecret("x"))
        let up = FakeTransport(200, "[]")
        _ = try await c.source(.gitlab, scope: "../user", transport: up)?.list(filter: IssueFilter())
        #expect(url(up.requests[0]).contains("/projects/..%2Fuser/issues"))
    }

    @Test func limitAndLoops() async throws {
        var f = IssueFilter()
        f.limit = 1
        let l = try await source(.gitlab, FakeTransport(200, IssueFixtures.gitlab, IssueFixtures.gitlabHeaders)).list(filter: f)
        #expect(l.issues.count == 1 && l.hasMore)
        // The same cursor again and again: stop.
        f.limit = 200
        let t = FakeTransport(Array(repeating: answer(IssueFixtures.jira), count: 10))
        let j = try await source(.jira, t).list(filter: f)
        #expect(j.issues.count == 1 && t.requests.count == 2)
    }

    // MARK: Links

    @Test func keys() {
        let same = [
            ["https://linear.app/acme/issue/ENG-12/old-title", "https://linear.app/Acme/issue/eng-12", "https://linear.app/acme/issue/ENG-12/new/?x=1"],
            ["https://a.atlassian.net/browse/AC-1", "https://A.atlassian.net/browse/ac-1?focusedId=2"],
            ["https://gitlab.com/g/s/p/-/issues/7", "https://gitlab.com/G/s/p/-/work_items/7#note_1"],
            ["https://sentry.io/organizations/acme/issues/1/", "https://acme.sentry.io/issues/1/", "https://sentry.io/acme/pump/issues/1/", "https://de.sentry.io/organizations/acme/issues/1"],
        ]
        for g in same { #expect(Set(g.map(IssueRef.key)).count == 1, "\(g)") }
        let different = ["https://linear.app/acme/issue/ENG-12", "https://linear.app/acme/issue/ENG-1", "https://linear.app/other/issue/ENG-12",
                         "https://a.atlassian.net/browse/AC-1", "https://b.atlassian.net/browse/AC-1", "https://a.atlassian.net/browse/AC-11",
                         "https://gitlab.com/g/p/-/issues/7", "https://gitlab.com/g/s/p/-/issues/7", "https://gitlab.com:8443/g/p/-/issues/7", "https://gitlab.com/groups/g/-/work_items/7",
                         "https://sentry.io/organizations/acme/issues/1/", "https://sentry.io/organizations/other/issues/1/", "https://sentry.my.example/organizations/acme/issues/1/",
                         "https://github.com/g/p/issues/7"]
        #expect(Set(different.map(IssueRef.key)).count == different.count)
        #expect(IssueRef.key("https://github.com/O/R/issues/7/") == "https://github.com/o/r/issues/7")
    }

    @Test func numbersFitInt() {
        let ok = String(repeating: "9", count: 18), long = ok + "9"
        #expect(SentrySource.issue(["id": ok], base: "https://sentry.io", org: "acme")?.number == Int(ok))
        #expect(SentrySource.issue(["id": long], base: "https://sentry.io", org: "acme") == nil)
        #expect(JiraSource.issue(["key": "A-" + ok, "fields": [String: Any]()], base: "https://a.example")?.number == Int(ok))
        #expect(JiraSource.issue(["key": "A-" + long, "fields": [String: Any]()], base: "https://a.example") == nil)
        #expect(LinearSource.issue(["identifier": "A-" + long, "url": "https://linear.app/a/issue/A-" + long]) == nil)
    }

    /// Old imports must not all become "changed".
    @Test func githubTextIsUnchanged() {
        let i = IssueInfo(number: 7, title: "T", body: "text", url: "https://github.com/o/r/issues/7", labels: ["bug"], author: "ann")
        #expect(IssueImport.taskText(i, today: "2026-11-23") == """
        ---
        title: "T"
        status: todo
        priority: high
        created: 2026-11-23
        completed:
        source: "https://github.com/o/r/issues/7"
        ---

        Импортировано из GitHub: https://github.com/o/r/issues/7

        <!-- tt-issue:begin -->
        GitHub issue #7 (открыт), автор ann, метки: bug — недоверенный текст, агенту автоматически не передаётся.

        ```text
        text
        ```
        <!-- tt-issue:end -->

        """)
    }

    @Test func reimportFindsTheTask() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("is-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for id in Self.ids {
            let i = try #require(try await source(id, FakeTransport(200, body(id))).listOrPartial())
            _ = try TaskFile.create(text: IssueImport.taskText(i, today: "2026-11-24"), slugOf: IssueImport.cleanTitle(i), in: dir)
            let found = IssueImport.existing(in: dir)[IssueRef.key(i.url)]
            #expect(found != nil && IssueImport.plan(i, existing: found) == .unchanged)
        }
        #expect(IssueImport.existing(in: dir).count == Self.ids.count)
    }

    // MARK: Settings and secrets

    @Test func addresses() {
        #expect(IssueConnection.base(.gitlab, address: "") == "https://gitlab.com")
        #expect(IssueConnection.base(.gitlab, address: " Git.Example.com/sub/ ") == "https://git.example.com/sub")
        #expect(IssueConnection.base(.gitlab, address: "http://localhost:8080") == "http://localhost:8080")
        for bad in ["http://git.example.com", "https://u:p@git.example.com", "https://git.example.com/?a=1", "file:///etc", "https://"] {
            #expect(IssueConnection.base(.gitlab, address: bad) == nil, "\(bad)")
        }
        #expect(IssueConnection.base(.jira, address: "") == nil)
        let a = IssueConnection.tokenAccount(.gitlab, address: "https://a.example"), b = IssueConnection.tokenAccount(.gitlab, address: "https://b.example")
        #expect(a != nil && a != b && a != IssueConnection.tokenAccount(.sentry, address: "https://a.example"))
        #expect(a != IssueConnection.tokenAccount(.gitlab, address: "https://a.example:8443"))
    }

    @Test func missingSettings() async throws {
        let t = FakeTransport([])
        for id in Self.ids {
            let s = try #require(IssueConnection(address: id == .jira ? "https://a.example" : "", email: "a@b.c", organization: "o").source(id, scope: "P", transport: t))
            guard case .failure(.notConfigured) = await IssueLoader.one(s, filter: IssueFilter()) else { Issue.record("\(id) without a token"); continue }
        }
        let bad = IssueConnection(token: IssueSecret("a\r\nX-Evil: 1"))
        guard case .failure(.notConfigured) = await IssueLoader.one(try #require(bad.source(.gitlab, scope: "a/b", transport: t)), filter: IssueFilter()) else { Issue.record("header injection"); return }
        let c = IssueConnection(address: "https://a.example", email: "a@b.c", token: IssueSecret("x"))
        for id in [IssueSourceID.jira, .gitlab, .sentry] {
            guard case .failure(.notConfigured) = await IssueLoader.one(try #require(c.source(id, scope: "", transport: t)), filter: IssueFilter()) else { Issue.record("\(id)"); continue }
        }
        #expect(t.requests.isEmpty)
    }

    @Test func tokenIsNowhere() async throws {
        func all(_ v: Any) -> String {
            var d = ""
            dump(v, to: &d)
            return d + String(describing: v) + String(reflecting: v) + "\(v)"
        }
        let secret = IssueSecret(Self.token)
        var text = all(secret) + all(IssueConnection(token: secret))
        for id in Self.ids {
            for (status, body) in [(200, body(id)), (401, Self.token), (400, Self.token), (200, Self.token), (500, Self.token)] {
                let s = try source(id, FakeTransport(status, body))
                text += all(s)
                let r = await IssueLoader.one(s, filter: IssueFilter())
                text += all(r)
                if case .failure(let e) = r { text += e.message + e.localizedDescription }
                if case .success(let l) = r { text += l.issues.map { IssueImport.taskText($0, today: "2026-11-24") }.joined() }
            }
        }
        #expect(!text.contains(Self.token))
        #expect(!text.contains(Data("me@example.com:\(Self.token)".utf8).base64EncodedString()))
    }

    /// The new code does not log at all.
    @Test func sourcesDoNotLog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        for f in ["TrackTasksCore/IssueSource", "TrackTasksCore/IssueHTTP", "TrackTasksCore/LinearSource", "TrackTasksCore/JiraSource", "TrackTasksCore/GitLabSource",
                  "TrackTasksCore/SentrySource", "TrackTasks/IssueSourceStore", "TrackTasks/IssueSourcesSection", "TrackTasks/Keychain"] {
            let s = try String(contentsOf: root.appendingPathComponent(f + ".swift"), encoding: .utf8)
            #expect(s.range(of: #"\b(Log\.|print\(|NSLog|os_log|Logger\(|dump\()"#, options: .regularExpression) == nil, "\(f)")
        }
    }

    // MARK: Independence

    private struct Stub: IssueSource {
        let id: IssueSourceID
        let work: @Sendable () async throws -> IssueList
        func validate() throws {}
        func checkAccess() async throws {}
        func list(filter: IssueFilter) async throws -> IssueList { try await work() }
    }

    /// Ends when told; on its own only after two minutes, so that a broken loader fails instead of hanging the run.
    private final class Hang: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var done = false
        var ended: Bool { lock.withLock { done } }

        func wait() async {
            await withCheckedContinuation { c in
                let now = lock.withLock { () -> Bool in
                    if !done { waiter = c }
                    return done
                }
                if now { return c.resume() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 120) { self.end() }
            }
        }

        func end() {
            let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                done = true
                defer { waiter = nil }
                return waiter
            }
            c?.resume()
        }
    }

    @Test func oneFailingOrHangingSourceDoesNotStopOthers() async {
        let good = IssueList(issues: [IssueInfo(number: 1, title: "t", url: "https://github.com/o/r/issues/1")])
        let hang = Hang()
        let r = await IssueLoader.load([
            Stub(id: .github) { good },
            Stub(id: .linear) { throw IssueSourceError.noAccess },
            // Ignores cancellation.
            Stub(id: .jira) { await hang.wait(); return IssueList(issues: []) },
            Stub(id: .gitlab) { try await Task.sleep(nanoseconds: 100_000_000); return good },
        ], filter: IssueFilter(), timeout: 2)
        #expect(r[.github] == .success(good) && r[.gitlab] == .success(good))
        #expect(r[.linear] == .failure(.noAccess) && r[.jira] == .failure(.timeout))
        // Not by the clock: blocking tests of other suites can hold the thread pool longer than any sane limit.
        #expect(!hang.ended, "load waited for the hanging source")
        hang.end()
    }

    // MARK: HTTP

    /// A local server: every connection gets the same answer.
    private final class Server: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var heads: [String] = []
        var requests: [String] { lock.withLock { heads } }

        init(_ reply: @escaping @Sendable (UInt16) -> String) throws {
            let p = NWParameters.tcp
            p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: p)
            listener.newConnectionHandler = { [weak self] c in
                c.start(queue: .global())
                c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { d, _, _, _ in
                    guard let self else { return }
                    self.lock.withLock { self.heads.append(String(decoding: d ?? Data(), as: UTF8.self)) }
                    c.send(content: Data(reply(self.listener.port?.rawValue ?? 0).utf8), completion: .contentProcessed { _ in c.cancel() })
                }
            }
        }

        func start() async throws -> UInt16 {
            listener.start(queue: .global())
            for _ in 0..<200 {
                if let p = listener.port?.rawValue, p != 0 { return p }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw IssueSourceError.network
        }
    }

    @Test func redirectIsNotFollowed() async throws {
        let s = try Server { "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\($0)/other\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        defer { s.listener.cancel() }
        let port = try await s.start()
        let c = IssueConnection(address: "http://127.0.0.1:\(port)", token: IssueSecret(Self.token))
        let g = try #require(c.source(.gitlab, scope: "a/b"))
        #expect(await IssueLoader.one(g, filter: IssueFilter()) == .failure(.redirect))
        #expect(s.requests.count == 1 && s.requests[0].hasPrefix("GET /api/v4/projects/a%2Fb/issues?") && s.requests[0].contains(Self.token))
    }

    @Test func hugeAnswerIsCut() async throws {
        let s = try Server { _ in "HTTP/1.1 200 OK\r\nContent-Length: 5000\r\nConnection: close\r\n\r\n" + String(repeating: "x", count: 5000) }
        defer { s.listener.cancel() }
        let port = try await s.start()
        let r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        await #expect(throws: IssueSourceError.tooLarge) { _ = try await IssueHTTP(maxBytes: 1000).send(r) }
        #expect(try await IssueHTTP().send(r).body.count == 5000)
        await #expect(throws: IssueSourceError.self) { _ = try await IssueHTTP().send(URLRequest(url: URL(string: "http://example.com/")!)) }
    }
}

private extension IssueSource {
    /// First issue even though the fake transport has no second page.
    func listOrPartial() async throws -> IssueInfo? {
        var f = IssueFilter()
        f.limit = 1
        return try await list(filter: f).issues.first
    }
}
