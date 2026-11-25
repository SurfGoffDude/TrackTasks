import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Codec round-trip")
struct RoundTripTests {
    static let sample = """
        ---
        title: "Очередь: учитывать \\"depends\\""
        status: todo
        priority: high
        created: 2026-11-16
        completed:
        size: m
        depends: [20261116-150000-testy-parsera.md, b.md]
        ---

        Описание.

        - [ ] пункт
        - [x] сделано

        ## Критерии готовности
        - [ ] проверка

        ## Заметки
        - 16.11 15:00 — запись

        """

    @Test func newFormatFileUnchanged() {
        let t = Codec.task(from: Self.sample, url: URL(fileURLWithPath: "/p/tasks/x.md"))
        #expect(t.title == "Очередь: учитывать \"depends\"")
        #expect(Codec.serialize(t) == Self.sample)
    }

    @Test func parentField() {
        let url = URL(fileURLWithPath: "/p/tasks/x.md")
        let text = Self.sample.replacingOccurrences(of: "depends: [", with: "parent: 20261116-140000-a.md\ndepends: [")
        var t = Codec.task(from: text, url: url)
        #expect(t.parent == "20261116-140000-a.md")
        #expect(Codec.serialize(t) == text)
        t.status = .doing
        #expect(Codec.serialize(t, updating: text) == text.replacingOccurrences(of: "status: todo", with: "status: doing"))
        t = Codec.task(from: Self.sample, url: url)
        #expect(t.parent.isEmpty)
        #expect(Codec.serialize(t, updating: Self.sample) == Self.sample)
    }

    @Test func automationField() {
        let url = URL(fileURLWithPath: "/p/tasks/x.md")
        let text = Self.sample.replacingOccurrences(of: "depends: [", with: "automation: 20261124-090000-a.md\ndepends: [")
        var t = Codec.task(from: text, url: url)
        #expect(t.automation == "20261124-090000-a.md")
        #expect(Codec.serialize(t) == text)
        t.status = .doing
        #expect(Codec.serialize(t, updating: text) == text.replacingOccurrences(of: "status: todo", with: "status: doing"))
    }

    @Test func doneTaskUnchanged() {
        let text = "---\ntitle: \"x\"\nstatus: done\npriority: low\ncreated: 2026-01-01\ncompleted: 2026-01-02\n---\n\nbody\n"
        #expect(Codec.serialize(Codec.task(from: text, url: URL(fileURLWithPath: "/t/x.md"))) == text)
    }

    @Test func serializeOmitsEmptyOptionalFields() {
        let t = TaskItem(url: URL(fileURLWithPath: "/t/x.md"), title: "x", status: .todo, priority: .medium,
                         created: "2026-11-16", completed: "", body: "b")
        let s = Codec.serialize(t)
        #expect(!s.contains("size:"))
        #expect(!s.contains("depends:"))
        #expect(s.contains("\ncompleted:\n"))
    }

    @Test func itemSurvivesSerializeParse() {
        let t = TaskItem(url: URL(fileURLWithPath: "/t/20261116-120000-x.md"), title: "Сложный \"title\" \\ с: двоеточием",
                         status: .doing, priority: .low, created: "2026-11-16", completed: "",
                         body: "строка\n\n- [ ] пункт", depends: ["a.md", "b.md"], size: "l")
        let back = Codec.task(from: Codec.serialize(t), url: t.url)
        #expect(back == t)
    }

    /// Every task of this project survives parse → serialize. Trailing spaces are ignored
    /// (older app builds wrote `completed: `; the serializer now writes bare `completed:`).
    @Test(.enabled(if: hasOwnTasks)) func allProjectTasksUnchanged() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tasks")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        #expect(!files.isEmpty)
        func norm(_ s: String) -> String {
            s.components(separatedBy: "\n").map { line in
                var l = Substring(line)
                while l.last == " " || l.last == "\t" { l.removeLast() }
                return String(l)
            }.joined(separator: "\n")
        }
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let out = Codec.serialize(Codec.task(from: text, url: url))
            #expect(norm(out) == norm(text), "round-trip diff in \(url.lastPathComponent)")
        }
    }
}

@Suite("Comments and unknown fields")
struct CommentPreserveTests {
    static let text = """
        ---
        title: "x"
        status: todo        # todo | doing | done
        priority: medium
        created: 2026-11-16
        completed:          # дата
        tags: [a, b]
        depends: [a.md] # после a
        ---

        body

        """

    @Test func statusChangeTouchesOnlyStatusAndCompleted() {
        var t = Codec.task(from: Self.text, url: URL(fileURLWithPath: "/t/x.md"))
        t.status = .done
        t.completed = "2026-11-16"
        let out = Codec.serialize(t, updating: Self.text)
        let a = Self.text.components(separatedBy: "\n"), b = out.components(separatedBy: "\n")
        #expect(a.count == b.count)
        let changed = zip(a, b).filter { $0 != $1 }.map { $1 }
        #expect(changed == ["status: done # todo | doing | done", "completed: 2026-11-16 # дата"])
        #expect(out.contains("tags: [a, b]"))
    }

    @Test func unchangedTaskIsIdentical() {
        let t = Codec.task(from: Self.text, url: URL(fileURLWithPath: "/t/x.md"))
        #expect(Codec.serialize(t, updating: Self.text) == Self.text)
    }

    @Test func dependsCommentStripped() {
        let t = Codec.task(from: Self.text, url: URL(fileURLWithPath: "/t/x.md"))
        #expect(t.depends == ["a.md"])
        #expect(Frontmatter.word("2026-11-16 # x") == "2026-11-16")
    }
}
