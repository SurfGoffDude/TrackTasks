import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Сессии Claude")
struct SessionTests {
    static func user(_ text: String, at: String = "2026-11-20T10:00:00.000Z", extra: String = "") -> String {
        #"{"parentUuid":null,"type":"user","cwd":"/p/app","timestamp":"\#(at)"\#(extra),"message":{"role":"user","content":"\#(text)"}}"#
    }
    static func assistant(_ text: String, at: String = "2026-11-20T10:05:00.000Z") -> String {
        #"{"type":"assistant","cwd":"/p/app/sub","timestamp":"\#(at)","message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    static func tempRoot() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tt-sessions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: u.appendingPathComponent("-p-app"), withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    static func write(_ lines: [String], _ id: String, in root: URL) throws -> String {
        let f = root.appendingPathComponent("-p-app/\(id).jsonl")
        try lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        return f.path
    }

    static func parse(_ lines: [String], maxLine: Int = SessionLog.maxLine) throws -> SessionLog.Parsed? {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        return try SessionLog.parse(path: write(lines, "abc", in: root), modified: Date(timeIntervalSince1970: 0), maxLine: maxLine)
    }

    // MARK: - Разбор

    @Test func readsConversation() throws {
        let p = try #require(try Self.parse([
            #"{"type":"session-owner","sessionId":"abc"}"#,
            Self.user("<command-name>/clear</command-name>"),
            Self.user("служебное", extra: #","isMeta":true"#),
            Self.user("побочное", extra: #","isSidechain":true"#),
            Self.user("<system-reminder>скрыто</system-reminder>Сделай tasks/20261123-1-x.md"),
            Self.assistant("Готово, вот пингвин"),
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"вывод"}]}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"мысль"}]}}"#,
            #"{"type":"ai-title","aiTitle":"Заголовок","sessionId":"abc"}"#,
        ]))
        #expect(p.info.id == "abc")
        #expect(p.info.cwd == "/p/app")
        #expect(p.info.firstPrompt == "Сделай tasks/20261123-1-x.md")
        #expect(p.info.taskFile == "20261123-1-x.md")
        #expect(p.info.title == "Заголовок")
        #expect(p.info.turns == 1)
        #expect(p.info.updated.timeIntervalSince(p.info.started) == 300)
        #expect(p.terms["пингвин"] == 1 && p.terms["заголовок"] == 1)
        for hidden in ["скрыто", "служебное", "побочное", "вывод", "мысль"] { #expect(p.terms[hidden] == nil) }
        #expect(p.badLines == 0)
    }

    @Test func brokenLinesAreSkipped() throws {
        let p = try #require(try Self.parse([
            Self.user("первая"), #"{"type":"user","message":{"content":"обрыв"#, "мусор", "",
            Self.assistant("вторая"), #"{"type":"assistant","message":{"content":[{"type":"text","te"#,
        ]))
        #expect(p.badLines == 2)
        #expect(p.terms["первая"] == 1 && p.terms["вторая"] == 1)
    }

    @Test func invalidUTF8IsSkipped() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("-p-app/a.jsonl")
        var d = Data(#"{"type":"user","message":{"content":""#.utf8)
        d.append(contentsOf: [0xFF, 0xFE]); d.append(Data("\"}}\n\(Self.user("цела"))\n".utf8))
        try d.write(to: f)
        #expect(try SessionLog.parse(path: f.path, modified: Date())?.info.firstPrompt == "цела")
    }

    @Test func longLines() throws {
        // Longer than the read chunk, and longer than the limit.
        let big = String(repeating: "слово ", count: 100_000)
        #expect(try Self.parse([Self.user(big), Self.assistant("хвост")])?.terms["слово"] == 100_000)
        let cut = try #require(try Self.parse([Self.user(big), Self.assistant("хвост")], maxLine: 10_000))
        #expect(cut.terms["слово"] == nil && cut.terms["хвост"] == 1)
    }

    @Test func noConversation() throws {
        #expect(try Self.parse([#"{"type":"mode"}"#]) == nil)
        #expect(try Self.parse([]) == nil)
        #expect(throws: (any Error).self) { try SessionLog.parse(path: "/nonexistent/x.jsonl", modified: Date()) }
    }

    @Test func taskReference() {
        #expect(SessionLog.taskReference("из файла /p/app/tasks/a-b.md («x»)") == "a-b.md")
        #expect(SessionLog.taskReference("mytasks/a.md и tasks/a.txt") == nil)
    }

    @Test func projectOfSession() {
        let ps = ["/p/app", "/p/app/inner", "/p/app2"]
        func find(_ c: String) -> String? { SessionProject.find(cwd: c, projects: ps, worktreesRoot: "/wt") }
        #expect(find("/p/app") == "/p/app")
        #expect(find("/p/app/inner/src") == "/p/app/inner")
        #expect(find("/p/app2/x") == "/p/app2")
        #expect(find("/p/app3") == nil)
        #expect(find("/wt/p__app/ab12cd") == "/p/app")
        #expect(find("/wt/other/ab12cd") == nil)
    }

    // MARK: - Ранжирование

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func doc(_ id: String, _ text: String, daysAgo: Double = 0) -> SessionLog.Parsed {
        let d = now.addingTimeInterval(-daysAgo * 86400)
        var terms: [String: Int] = [:]
        for t in SearchText.tokens(text) { terms[t, default: 0] += 1 }
        return .init(info: .init(id: id, path: id, cwd: "", title: "", firstPrompt: text, started: d, updated: d,
                                 turns: 1, taskFile: nil), terms: terms, badLines: 0)
    }
    static func index(_ docs: SessionLog.Parsed...) -> SessionIndex {
        var i = SessionIndex()
        docs.forEach { i.put($0) }
        return i
    }
    static func ids(_ i: SessionIndex, _ q: String) -> [String] { i.search(q, now: now).map(\.id) }

    @Test func tokens() {
        #expect(SearchText.tokens("Ёлка, git-diff v2! я") == ["елка", "git", "diff", "v2"])
        #expect(SearchText.tokens("и\u{306}од") == SearchText.tokens("йод"))
        #expect(SearchText.tokens(String(repeating: "a", count: 200)) == [])
    }

    @Test func moreMentionsAndShorterTextWin() {
        let i = Self.index(Self.doc("rare", "кот пёс мышь слон рысь волк"), Self.doc("often", "кот кот кот пёс мышь слон"),
                           Self.doc("none", "лиса"))
        #expect(Self.ids(i, "кот") == ["often", "rare"])
    }

    @Test func rareWordMatters() {
        let i = Self.index(Self.doc("a", "сборка сборка кварк"), Self.doc("b", "сборка сборка сборка"), Self.doc("c", "сборка тест"))
        #expect(Self.ids(i, "сборка кварк") == ["a"])
        #expect(Self.ids(i, "сборка нетслова") == [])
    }

    @Test func freshnessBreaksTies() {
        let i = Self.index(Self.doc("old", "кот пёс", daysAgo: 300), Self.doc("new", "кот пёс", daysAgo: 1))
        #expect(Self.ids(i, "кот") == ["new", "old"])
    }

    @Test func freshnessDoesNotBeatRelevance() {
        let filler = " " + String(repeating: "прочее ", count: 200)
        let i = Self.index(Self.doc("old", "кварк кварк кварк кварк", daysAgo: 300), Self.doc("new", "кварк" + filler))
        #expect(Self.ids(i, "кварк") == ["old", "new"])
    }

    @Test func prefixIsWeakerThanExact() {
        let i = Self.index(Self.doc("prefix", "сессиями пёс"), Self.doc("exact", "сессия пёс"), Self.doc("pre2", "сессия пёс", daysAgo: 1))
        #expect(Self.ids(i, "сесси").count == 3)
        #expect(Self.ids(i, "сессия") == ["exact", "pre2", "prefix"])
        let j = Self.index(Self.doc("prefix", "тесты пёс"), Self.doc("exact", "тест пёс"))
        #expect(Self.ids(j, "тест") == ["exact", "prefix"])
    }

    @Test func emptyQueryListsNewestFirst() {
        let i = Self.index(Self.doc("old", "а1", daysAgo: 5), Self.doc("new", "б1"))
        #expect(Self.ids(i, "  ") == ["new", "old"])
        #expect(Self.ids(i, "!!!") == [])
    }

    @Test func replaceRemoveAndCompact() {
        var i = Self.index(Self.doc("keep", "кот"))
        for n in 0..<300 { i.put(Self.doc("hot", "версия\(n)")) }
        #expect(i.count == 2)
        #expect(Self.ids(i, "версия298") == [])
        #expect(Self.ids(i, "версия299") == ["hot"])
        #expect(Self.ids(i, "кот") == ["keep"])
        i.remove(path: "hot")
        #expect(Self.ids(i, "версия299") == [])
    }

    // MARK: - Обновление по файлам

    @Test func refreshFollowsFiles() async throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try Self.write([Self.user("жираф"), "{битая"], "a", in: root)
        try Self.write([Self.user("тапир")], "b", in: root)
        let sub = root.appendingPathComponent("-p-app/a/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Self.user("субагент").write(to: sub.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)

        let lib = SessionLibrary(root: root)
        #expect(await lib.refresh() == 2)
        #expect(await lib.search("жираф").map(\.id) == ["a"])
        #expect(await lib.search("субагент").isEmpty)
        #expect(await lib.refresh() == 0)

        try Self.write([Self.user("жираф"), Self.assistant("окапи")], "a", in: root)
        #expect(await lib.refresh() == 1)
        #expect(await lib.search("окапи").map(\.id) == ["a"])

        try FileManager.default.removeItem(atPath: a)
        #expect(await lib.refresh() == 0)
        #expect(await lib.sessions().map(\.id) == ["b"])
    }

    @Test func indexingIsOffMainThread() async throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 0..<5 { try Self.write([Self.user("слово\(n)")], "s\(n)", in: root) }
        let lib = SessionLibrary(root: root)
        // Started from the main actor; progress comes from the indexing itself.
        let mains = await Task { @MainActor in
            let box = Flags()
            await lib.refresh { _, _ in box.add(pthread_main_np() != 0) }
            return box.values
        }.value
        #expect(mains == Array(repeating: false, count: 5))
    }

    private final class Flags: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Bool] = []
        func add(_ v: Bool) { lock.withLock { list.append(v) } }
        var values: [Bool] { lock.withLock { list } }
    }
}
