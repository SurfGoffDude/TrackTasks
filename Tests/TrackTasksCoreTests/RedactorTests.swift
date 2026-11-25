import Foundation
import Testing
@testable import TrackTasksCore

/// Fake keys are glued from parts so that secret scanners don't stop the push.
@Suite("Вычистка ключей и путей")
struct RedactorTests {
    let r = Redactor(home: "/Users/ivan.petrov")
    static func x(_ n: Int) -> String { String(String(repeating: "aB3dE5gH7j", count: n / 10 + 1).prefix(n)) }
    static func up(_ n: Int) -> String { x(n).uppercased() }
    static func hex(_ n: Int) -> String { String(String(repeating: "0a1b2c3d4e5f", count: n / 12 + 1).prefix(n)) }

    static let keys: [String] = [
        "sk-" + "ant-api03-" + x(40), "sk-" + "proj-" + x(40), "sk-" + x(48),
        "ghp" + "_" + x(36), "gho" + "_" + x(36), "ghs" + "_" + x(36), "github" + "_pat_" + x(50),
        "glpat" + "-" + x(20), "AKIA" + up(16), "ASIA" + up(16), "AIza" + x(35), "GOCSPX" + "-" + x(28), "ya29" + "." + x(40),
        "xoxb" + "-123456789-" + x(20), "xapp" + "-1-" + x(20), "sk" + "_live_" + x(24), "rk" + "_test_" + x(24), "whsec" + "_" + x(32),
        "npm" + "_" + x(36), "pypi" + "-" + x(60), "hf" + "_" + x(34), "SG" + "." + x(22) + "." + x(43),
        "dop" + "_v1_" + hex(64), "sbp" + "_" + hex(40), "lin" + "_api_" + x(40), "ntn" + "_" + x(46),
        "dckr" + "_pat_" + x(27), "hvs" + "." + x(30), "AGE-SECRET" + "-KEY-1" + up(58), "gsk" + "_" + x(50), "xai" + "-" + x(60),
        "eyJ" + x(20) + "." + x(40) + "." + x(43), "SK" + hex(32), "123456789" + ":" + x(35),
    ]

    @Test(arguments: keys) func knownFormats(_ key: String) {
        for text in [key, "ключ \(key).", "`\(key)`", "a\\n\(key)\\n", "(\(key))", "X=\(key)", "{\"k\":\"\(key)\"}"] {
            let c = r.clean(text)
            #expect(!c.text.contains(key), "\(text)")
            #expect(!c.text.contains(key.suffix(12)), "\(text) → \(c.text)")
            #expect(c.secrets >= 1)
        }
    }

    @Test(arguments: [
        "password: hunter22", "\"password\": \"два слова и ещё\"", "DB_PASSWORD='hun ter22'", "**Пароль:** `hunter22`",
        "api_key = hunter22", "\\\"apiKey\\\":\\\"hunter22\\\"", "MY_SECRET=hunter22", "--token hunter22", "--db-password=hunter22",
        "aws_secret_access_key=hunter22/abc+def", "Authorization: Bearer hunter22hunter22", "authorization: basic aHVudGVyMjI=aHVudA",
        "postgres://user:hunter22@host/db", "redis://:hunter22@host", "https://hunter22hunter22xx@github.com/a/b",
        "AccountKey=hunter22==;Endpoint", "https://hooks.slack.com/services/T00/B00/hunter22", "https://discord.com/api/webhooks/123/hunter22",
    ]) func namedValues(_ text: String) {
        let c = r.clean(text)
        for s in ["hunter22", "hun ter22", "два слова", "aHVudGVy"] { #expect(!c.text.contains(s), "\(c.text)") }
        #expect(c.text.contains(Redactor.mark))
    }

    @Test func privateKeys() {
        let body = Self.x(64) + "\n" + Self.x(64)
        let begin = "-----BEGIN OPENSSH " + "PRIVATE KEY-----", end = "-----END OPENSSH " + "PRIVATE KEY-----"
        #expect(r.clean("до\n\(begin)\n\(body)\n\(end)\nпосле").text == "до\n\(Redactor.mark)\nпосле")
        // Cut and escaped.
        #expect(!r.clean("\(begin)\n\(body)").text.contains("aB3"))
        #expect(!r.clean("\(begin)\\n\(Self.x(64))\\n").text.contains("aB3"))
    }

    @Test(arguments: [
        "/Users/ivan.petrov/Projects/a.swift", "file:///Users/ivan.petrov/a", "/users/Ivan.Petrov/a", "cd /Users/ivan.petrov",
        "\\/Users\\/ivan.petrov\\/a", "%2FUsers%2Fivan.petrov%2Fa", "~/.claude/projects/-Users-ivan-petrov-Projects-a",
        "worktrees/Users__ivan.petrov__Projects__a/b", "x\\n/Users/ivan.petrov/a", "-I/Users/ivan.petrov/include",
        "\"/Users/ivan.petrov\"",
    ]) func homePath(_ text: String) {
        let c = r.clean(text)
        for s in ["ivan", "Ivan"] { #expect(!c.text.contains(s), "\(c.text)") }
        #expect(c.paths >= 1)
    }

    @Test func homeKeepsTheRest() {
        #expect(r.clean("/Users/ivan.petrov/Projects/a.swift:12").text == "~/Projects/a.swift:12")
        #expect(r.clean("/Users/ivan.petrov").text == "~")
        #expect(r.clean("/Users/ivan.petrov2/x и /home/olga/y").text == "~/x и ~/y")
        #expect(r.clean("/var/folders/ab/c1d2/T/x").text == "$TMPDIR/T/x")
        let spaced = Redactor(home: "/Volumes/Big Disk/me")
        #expect(spaced.clean("/Volumes/Big Disk/me/a, /Volumes/Big\\ Disk/me/b, file:///Volumes/Big%20Disk/me/c").text == "~/a, ~/b, file://~/c")
    }

    @Test func ordinaryTextStays() {
        let t = "Токены посчитаны. GET /users/list, src/Users/View.swift, /Users/Shared/x, task-list-for-the-whole-project. Commit 0a1b2c3d4e5f60718293a4b5c6d7e8f901234567."
        #expect(r.clean(t) == .init(text: t, secrets: 0, paths: 0))
    }

    @Test func cleaningTwiceChangesNothing() {
        let t = (Self.keys + ["password: hunter22", "Authorization: Bearer hunter22hunter22", "postgres://u:hunter22@h",
                              "--token hunter22", "/Users/ivan.petrov/a", "/var/folders/a/b/T"]).joined(separator: "\n")
        let once = r.clean(t)
        #expect(r.clean(once.text) == .init(text: once.text, secrets: 0, paths: 0))
    }

    @Test func longLineIsFast() {
        let start = Date()
        _ = r.clean(String(repeating: "a", count: 300_000) + String(repeating: "-token ", count: 20_000))
        #expect(Date().timeIntervalSince(start) < 20)
    }
}

@Suite("Снимок задачи и статистика")
struct SnapshotStatsTests {
    @Test func conversationIsOnlyWhatWasSaid() throws {
        let root = try SessionTests.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try SessionTests.write([
            SessionTests.user("<command-name>/clear</command-name>"),
            SessionTests.user("побочное", extra: #","isSidechain":true"#),
            SessionTests.user("<system-reminder>скрыто</system-reminder>Сделай"),
            SessionTests.assistant("Раз"),
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"вывод"}]}]}}"#,
            SessionTests.assistant("Два"),
            "битая строка \"type\":\"user\"",
            SessionTests.user("Ещё"),
        ], "s", in: root)
        let m = try SessionLog.conversation(path: path)
        #expect(m == [.init(.user, "Сделай"), .init(.agent, "Раз\n\nДва"), .init(.user, "Ещё")])
        let md = TaskSnapshot(title: "T", project: "P", facts: ["", "$0.10"], messages: m, review: "ок").markdown
        #expect(md == "# T\n\nP · $0.10\n\n## Пользователь\n\nСделай\n\n## Агент\n\nРаз\n\nДва\n\n## Пользователь\n\nЕщё\n\n## Ревью\n\nок\n")
    }

    @Test func gistIsAlwaysSecret() throws {
        let o = try #require(try JSONSerialization.jsonObject(with: Data(GistAPI.createBody("текст \"x\"").utf8)) as? [String: Any])
        #expect(o["public"] as? Bool == false)
        #expect(Set(o.keys) == ["public", "files"])
        #expect(GistAPI.parseCreated(#"{"id":"ab12","html_url":"https://gist.github.com/u/ab12"}"#)?.id == "ab12")
        #expect(GistAPI.parseCreated("{}") == nil)
        #expect(GistAPI.deleteArgs("ab12")?.last == "gists/ab12")
        #expect(GistAPI.deleteArgs("../user") == nil)
        #expect(GistAPI.deleteArgs("") == nil)
    }

    private func entry(_ cost: Double?, ms: Int? = nil, turns: Int? = nil, task: String? = nil, file: String? = nil, at: Double = 0) -> SpendEntry {
        SpendEntry(date: Date(timeIntervalSince1970: at), project: "p", model: "Opus", kind: "k", cost: cost, input: 1, output: 1,
                   duration: ms, turns: turns, task: task, taskFile: file)
    }

    @Test func oldEntriesDecode() throws {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let e = try d.decode(SpendEntry.self, from: Data(#"{"id":"6E5F0B0A-0000-0000-0000-000000000000","date":"2026-11-01T00:00:00Z","project":"p","model":"Opus","kind":"Чат","cost":0.1,"input":5,"output":2}"#.utf8))
        #expect(e.duration == nil && e.turns == nil && e.taskKey == nil)
    }

    @Test func unknownIsNotZero() throws {
        let row = try #require(AgentStats.rows([entry(0.5, ms: 61_000, turns: 3), entry(nil)], by: { $0.model }).first)
        #expect(row.runs == 2)
        #expect(row.text(.cost) == "≥ $0.50")
        #expect(row.text(.time) == "≥ 1 мин 1 с")
        #expect(row.text(.turns) == "≥ 3")
        let none = try #require(AgentStats.rows([entry(nil)], by: { $0.model }).first)
        #expect(AgentStats.Metric.allCases.map(none.text) == ["нет данных", "нет данных", "нет данных"])
        #expect(AgentStats.Metric.allCases.allSatisfy { $0.value(entry(nil)) == nil })
    }

    @Test func tasksGroupByFile() {
        let rows = AgentStats.tasks([entry(1, turns: 1, task: "Старое", file: "a.md", at: 1), entry(2, turns: 1, task: "Новое", file: "a.md", at: 2),
                                     entry(0.5, turns: 9, task: "B", file: "b.md"), entry(9)])
        #expect(rows.map(\.name) == ["Новое", "B"])
        #expect(rows.first?.cost.usd == 3)
        #expect(AgentStats.tasks([entry(1, turns: 1, task: "A", file: "a.md"), entry(0.5, turns: 9, task: "B", file: "b.md")], sort: .turns).first?.name == "B")
    }
}
