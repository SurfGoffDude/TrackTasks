import Foundation
import Testing
@testable import TrackTasksCore

@Suite("verify задачи")
struct TaskVerifyTests {
    static func file(_ lines: String) -> String { "---\ntitle: \"T\"\nstatus: todo\npriority: low\ncreated: 2026-11-01\ncompleted:\n\(lines)\n---\n\nТело\n" }
    static func v(_ lines: String) -> TaskVerify { TaskVerify.parse(file(lines)) }
    static func bad(_ lines: String) -> Bool { if case .invalid = v(lines) { true } else { false } }

    @Test func parse() {
        #expect(Self.v("size: m") == .none)
        #expect(Self.v("verify:") == .none)
        #expect(Self.v("verify: \"\"") == .none)
        #expect(Self.v("verify: npm test # свой") == .command("npm test"))
        #expect(Self.v("verify: grep \"a # b\" x#y") == .command("grep \"a # b\" x#y"))
        #expect(Self.v("verify: \"echo \\\"a\\\" # \\\\n\" # c") == .command("echo \"a\" # \\n"))
        #expect(Self.v("verify: 'it''s'") == .command("it's"))
        #expect(Self.v("Verify : true") == .command("true"))
        #expect(TaskVerify.parse(Self.file("verify: a b").replacingOccurrences(of: "\n", with: "\r\n")) == .command("a b"))
        #expect(TaskVerify.parse("без frontmatter\nverify: x\n") == .none)
    }

    @Test(arguments: ["verify: a\nverify: b", "verify: a\nVERIFY: a", "verify: |", "verify: >\n  x", "verify:\n  - a", "verify: \"a", "verify: \"a\" b",
                      "verify: echo \"a", "verify: a\u{202E}b", "verify: a\u{200B}", "verify: a\tb", "verify: a\u{A0}b", "verify: a\rb", "verify: a\u{FE0F}"])
    func unclearIsRefusedNotMissing(_ lines: String) {
        #expect(Self.bad(lines))
        #expect(TaskLint.fileProblems(text: Self.file(lines), fileName: "20261101-100000-a.md").contains { $0.kind == .field("verify") })
    }

    @Test func roundTrip() {
        let url = URL(fileURLWithPath: "/p/tasks/20261101-100000-a.md")
        for cmd in ["npm test", "a \"b # c\" 'd' \\n \\\\", "# x", "'a' && 'b'"] {
            var t = Codec.task(from: Self.file("size: m"), url: url)
            t.verify = cmd
            #expect(Codec.task(from: Codec.serialize(t), url: url).verify == cmd)
            let text = Codec.serialize(t, updating: Self.file("size: m # c\nx: y"))
            #expect(Codec.task(from: text, url: url).verify == cmd && text.contains("size: m # c\nx: y"))
            t = Codec.task(from: text, url: url)
            t.status = .doing
            #expect(Codec.serialize(t, updating: text) == text.replacingOccurrences(of: "status: todo", with: "status: doing"))
            t.verify = ""
            #expect(!Codec.serialize(t, updating: text).contains("verify"))
        }
        // An untouched field stays as written, a wrong one too.
        for lines in ["verify: a b  # c", "Verify: x", "verify: a\nverify: b"] {
            var t = Codec.task(from: Self.file(lines), url: url)
            t.title = "Новое"
            #expect(Codec.serialize(t, updating: Self.file(lines)).contains(lines))
        }
        #expect(TaskVerify.parse(TaskVerify.setting("z", in: Self.file("Verify: x\nverify: a\nverify: b"))) == .command("z"))
        #expect(!TaskVerify.setting("", in: Self.file("Verify: x\nverify: a # c")).lowercased().contains("verify"))
    }

    @Test func mergeConflict() {
        let base = Codec.task(from: Self.file("verify: a"), url: URL(fileURLWithPath: "/p/tasks/a.md"))
        var mine = base, now = base
        now.verify = "b"
        #expect(TaskMerge.merge(base: base, mine: mine, current: now).item.verify == "b")
        mine.verify = "c"
        #expect(TaskMerge.merge(base: base, mine: mine, current: now).conflicts == ["проверка"])
    }

    @Test func notWithRepos() {
        let p = TaskLint.fileProblems(text: Self.file("verify: a\nrepos: [x/y]"), fileName: "20261101-100000-a.md")
        #expect(p.contains { $0.kind == .field("verify") })
        #expect(!TaskLint.fileProblems(text: Self.file("verify: a"), fileName: "20261101-100000-a.md").contains { $0.kind == .field("verify") })
    }

    @Test func decisions() {
        func d(_ now: TaskVerify?, _ queued: String? = nil, _ approved: String? = nil) -> TaskVerify.Decision { TaskVerify.decide(now, queued: queued, approved: approved) }
        func none(_ x: TaskVerify.Decision) -> Bool { if case .none = x { true } else { false } }
        #expect(none(d(TaskVerify.none)) && none(d(nil)) && none(d(TaskVerify.none, "")))
        #expect(d(.command("a")).refusal?.ask == "a")
        #expect(d(.command("a"), "a").refusal?.ask == "a")
        #expect(d(.command("a"), "a", "a").command == "a")
        #expect(d(.command("b"), "a", "a").refusal?.ask == "b")
        // Equal for String, not for a shell.
        #expect(d(.command("e\u{301}"), nil, "\u{E9}").refusal != nil)
        // Removal is a change too.
        #expect(d(TaskVerify.none, "a").refusal?.ask == "")
        #expect(d(TaskVerify.none, "a", "a").refusal?.ask == "")
        #expect(none(d(TaskVerify.none, "a", "")))
        #expect(d(.command("a"), "a", "").refusal?.ask == "a")
        #expect(d(nil, "a", "a").refusal != nil && d(nil, "a").refusal?.ask == nil)
        #expect(d(.invalid("x", raw: "y"), "a", "a").refusal?.ask == nil && d(.invalid("x", raw: "y")).refusal != nil)
    }

    @Test func approvalsArePerProjectAndFile() throws {
        var a = TaskVerifyApprovals()
        let p = URL(fileURLWithPath: "/tmp"), q = URL(fileURLWithPath: "/usr")
        a.approve("x", p, "a.md")
        #expect(a.approved(p, "a.md") == "x" && a.approved(p, "b.md") == nil && a.approved(q, "a.md") == nil)
        #expect(a.approved(URL(fileURLWithPath: "/private/tmp"), "a.md") == "x")
        #expect(try JSONDecoder().decode(TaskVerifyApprovals.self, from: JSONEncoder().encode(a)) == a)
    }

    @Test func fileIsFoundInTheArchive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-tv-\(UUID().uuidString)/tasks")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let f = dir.appendingPathComponent("a.md"), arch = dir.appendingPathComponent("archive/a.md")
        try FileManager.default.createDirectory(at: arch.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(TaskVerify.load(taskAt: f) == nil)
        try Self.file("verify: a").write(to: arch, atomically: true, encoding: .utf8)
        #expect(TaskVerify.load(taskAt: f) == .command("a"))
        try Data([0xFF, 0xFE, 0xFF]).write(to: f)
        if case .invalid? = TaskVerify.load(taskAt: f) {} else { Issue.record("битый файл") }
    }
}
