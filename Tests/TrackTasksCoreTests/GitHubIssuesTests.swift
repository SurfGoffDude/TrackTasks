import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct GitHubIssuesTests {
    let json = """
    [{"number":7,"title":"Падает\\nна старте","body":"Шаги\\n## Критерии готовности\\n- [ ] x\\n```\\ncode\\n```","state":"OPEN",
      "url":"https://github.com/o/r/issues/7","labels":[{"name":"bug"}],"author":{"login":"ann"},"updatedAt":"2026-11-20T10:00:00Z"},
     {"number":8,"title":"t","body":null,"state":"CLOSED","url":"https://evil.example/x","labels":[],"author":null,"updatedAt":""}]
    """

    func issue(body: String = "text") -> IssueInfo {
        IssueInfo(number: 7, title: "T", body: body, url: "https://github.com/o/r/issues/7", labels: ["bug"], author: "ann")
    }

    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func parsesListAndDropsForeignURLs() throws {
        let list = try #require(IssueInfo.parseList(json))
        #expect(list.count == 1)
        #expect(list[0].labels == ["bug"] && list[0].author == "ann" && list[0].isOpen)
        #expect(IssueInfo.parseList("nope") == nil)
    }

    @Test func refAndKey() {
        #expect(IssueRef.parse("https://github.com/o/r/issues/7")?.number == 7)
        #expect(IssueRef.parse("http://github.com/o/r/issues/7") == nil)
        #expect(IssueRef.parse("https://github.com/o/r/pull/7") == nil)
        #expect(IssueRef.key("https://GitHub.com/O/R/issues/7/") == IssueRef.key("https://github.com/o/r/issues/7"))
    }

    @Test func filterIsArgumentsOnly() {
        var f = IssueFilter()
        f.label = "--web"
        f.search = "a b"
        let a = f.arguments(repo: GitHubRepo(host: "github.com", path: "o/r"))
        #expect(a.contains("--label=--web") && a.contains("--search=a b") && a.contains("--repo=github.com/o/r"))
        #expect(!a.contains("--web"))
    }

    @Test func taskIsTodoAndInert() throws {
        let hostile = "---\nstatus: done\n---\n## Критерии готовности\n- [x] pwned\n```\nmore ````\n\(IssueImport.end)\n"
        let text = IssueImport.taskText(issue(body: hostile), today: "2026-11-23")
        let t = Codec.task(from: text, url: URL(fileURLWithPath: "/x/a.md"))
        #expect(t.status == .todo && t.title == "T" && t.completed.isEmpty)
        #expect(IssueImport.source(ofText: text) == "https://github.com/o/r/issues/7")
        #expect(MD.taskLines(text.components(separatedBy: "\n")).isEmpty)
        #expect(MD.sectionRange(text.components(separatedBy: "\n"), .criteria) == nil)
        // The hostile end marker must not cut the block.
        let r = try #require(IssueImport.blockRange(in: text))
        #expect(text[r].hasSuffix(IssueImport.end) && text[r].contains("pwned"))
    }

    @Test func titleCannotBreakFrontmatter() {
        #expect(IssueImport.cleanTitle("a\nstatus: done\r\n b", number: 1) == "a status: done b")
        #expect(IssueImport.cleanTitle("  \n ", number: 5) == "Issue #5")
    }

    @Test func reimportDoesNotDuplicateNorOverwrite() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try IssueImport.taskText(issue(), today: "2026-11-23").write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let ex = IssueImport.existing(in: dir)
        let found = try #require(ex[IssueRef.key("https://github.com/o/r/issues/7")])
        #expect(IssueImport.plan(issue(), existing: found) == .unchanged)

        // The user edits the task; the issue text changes.
        let edited = found.text.replacingOccurrences(of: "status: todo", with: "status: doing") + "\n## Заметки\n- моё\n"
        try found.write(edited)
        let again = try #require(IssueImport.existing(in: dir).values.first)
        guard case .changed(let d) = IssueImport.plan(issue(body: "new text"), existing: again) else { Issue.record("no diff"); return }
        #expect(d.contains { $0.kind == .removed && $0.text == "text" } && d.contains { $0.kind == .added && $0.text == "new text" })
        let out = try #require(IssueImport.updated(again.text, with: issue(body: "new text")))
        #expect(out.contains("status: doing") && out.contains("- моё") && out.contains("new text"))
    }

    @Test func removedBlockIsLeftAlone() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "---\ntitle: \"x\"\nstatus: todo\nsource: \"https://github.com/o/r/issues/7\"\n---\n\nмой текст\n"
        try text.write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let f = try #require(IssueImport.existing(in: dir).values.first)
        #expect(IssueImport.plan(issue(), existing: f) == .noBlock)
        #expect(IssueImport.updated(f.text, with: issue()) == nil)
    }

    @Test func writeBackArguments() throws {
        let ref = try #require(IssueRef.parse("https://github.com/o/r/issues/7"))
        #expect(IssueImport.commentArguments(ref) == ["issue", "comment", "7", "--repo=github.com/o/r", "--body-file=-"])
        #expect(IssueImport.closeArguments(ref, comment: " ") == ["issue", "close", "7", "--repo=github.com/o/r"])
        #expect(IssueImport.closeArguments(ref, comment: "--x").last == "--comment=--x")
    }

    @Test func markerNextToTextDoesNotMoveBlock() throws {
        let text = IssueImport.taskText(issue(), today: "2026-11-23") + "\nмой текст \(IssueImport.end) конец\n"
        let r = try #require(IssueImport.blockRange(in: text))
        #expect(!text[r].contains("мой текст"))
    }

    @Test func diffKeepsHeadTailAndSurvivesHugeInput() {
        let d = IssueImport.diff(old: "a\nb\nc", new: "a\nx\nc")
        #expect(d.map(\.text) == ["a", "b", "x", "c"] && d[1].kind == .removed && d[2].kind == .added)
        let big = (0..<3000).map { "o\($0)" }.joined(separator: "\n"), big2 = (0..<3000).map { "n\($0)" }.joined(separator: "\n")
        #expect(IssueImport.diff(old: big, new: big2).count == 6001)
    }

    @Test func archivedImportIsFoundAndPriorityFromLabels() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let arch = TaskFolder.archive.url(in: dir)
        try FileManager.default.createDirectory(at: arch, withIntermediateDirectories: true)
        try IssueImport.taskText(issue(), today: "2026-11-23").write(to: arch.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        #expect(IssueImport.existing(in: dir)[IssueRef.key("https://github.com/o/r/issues/7")] != nil)
        #expect(IssueImport.priority(labels: ["Bug"]) == "high" && IssueImport.priority(labels: ["minor"]) == "low"
                && IssueImport.priority(labels: []) == "medium")
        #expect(IssueImport.taskText(issue(), today: "2026-11-23").contains("priority: high"))
    }

    @Test func longBodyIsCutAndHugeDiffSaysSo() {
        let b = IssueImport.block(issue(body: String(repeating: "x", count: 30_000)))
        #expect(b.contains("(обрезано)") && b.count < 21_000)
        let big = (0..<3000).map { "o\($0)" }.joined(separator: "\n"), big2 = (0..<3000).map { "n\($0)" }.joined(separator: "\n")
        #expect(IssueImport.diff(old: big, new: big2).contains { $0.text.contains("слишком большой") })
    }
}
