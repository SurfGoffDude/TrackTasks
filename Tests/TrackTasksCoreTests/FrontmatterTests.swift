import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Frontmatter")
struct FrontmatterTests {
    @Test func quotedTitleWithEscapes() {
        let (f, _) = Frontmatter.parse("---\ntitle: \"Сказал \\\"да\\\" и C:\\\\path\"\n---\n")
        #expect(f["title"] == "Сказал \"да\" и C:\\path")
    }

    @Test func quoteUnquoteRoundTrip() {
        for s in ["plain", "with \"quotes\"", "back\\slash", "«ёлки»: двоеточие", ""] {
            #expect(Frontmatter.unquote(Frontmatter.quote(s)) == s)
        }
    }

    @Test func unquotedValueKeptAsIs() {
        #expect(Frontmatter.unquote("todo") == "todo")
        #expect(Frontmatter.unquote("\"") == "\"")
    }

    @Test func emptyCompletedWithAndWithoutSpace() {
        let a = Codec.task(from: "---\ntitle: x\ncompleted:\n---\n", url: URL(fileURLWithPath: "/t/a.md"))
        let b = Codec.task(from: "---\ntitle: x\ncompleted: \n---\n", url: URL(fileURLWithPath: "/t/b.md"))
        #expect(a.completed == "")
        #expect(b.completed == "")
    }

    @Test func commentAfterValueIsStripped() {
        let t = Codec.task(from: "---\nstatus: doing   # todo | doing | done\npriority: high # x\ncompleted:          # дата\n---\n",
                           url: URL(fileURLWithPath: "/t/a.md"))
        #expect(t.status == .doing)
        #expect(t.priority == .high)
        #expect(t.completed == "")
    }

    @Test func dependsList() {
        #expect(Frontmatter.list("[a.md, b.md]") == ["a.md", "b.md"])
        #expect(Frontmatter.list("[\"a.md\",  b.md ,]") == ["a.md", "b.md"])
        #expect(Frontmatter.list("a.md") == ["a.md"])
        #expect(Frontmatter.list("[]") == [])
        #expect(Frontmatter.list(nil) == [])
    }

    @Test func dependsInTask() {
        let t = Codec.task(from: "---\ntitle: x\ndepends: [20261115-140000-volna-c0.md, b.md]\n---\n",
                           url: URL(fileURLWithPath: "/t/x.md"))
        #expect(t.depends == ["20261115-140000-volna-c0.md", "b.md"])
    }

    @Test(arguments: [("s", "s"), ("M", "m"), ("l # большая", "l"), ("xl", ""), ("", ""), ("medium", "")])
    func sizeNormalization(raw: String, expected: String) {
        let t = Codec.task(from: "---\ntitle: x\nsize: \(raw)\n---\n", url: URL(fileURLWithPath: "/t/x.md"))
        #expect(t.size == expected)
    }

    @Test func unknownStatusAndPriorityFallBack() {
        let t = Codec.task(from: "---\nstatus: blocked\npriority: urgent\n---\n", url: URL(fileURLWithPath: "/t/x.md"))
        #expect(t.status == .todo)
        #expect(t.priority == .medium)
    }

    @Test func noFrontmatterTitleFromHeading() {
        let t = Codec.task(from: "# Заголовок\n\nтекст", url: URL(fileURLWithPath: "/t/file-name.md"))
        #expect(t.title == "Заголовок")
        #expect(t.body == "# Заголовок\n\nтекст")
        let u = Codec.task(from: "просто текст", url: URL(fileURLWithPath: "/t/file-name.md"))
        #expect(u.title == "file-name")
    }

    @Test func unclosedFrontmatterIsBody() {
        let text = "---\ntitle: x\nтекст без закрытия"
        let (f, body) = Frontmatter.parse(text)
        #expect(f.isEmpty)
        #expect(body == text)
    }

    @Test func crlfLineEndings() {
        let (f, body) = Frontmatter.parse("---\r\ntitle: \"A\"\r\nstatus: done\r\n---\r\nbody\r\n")
        #expect(f["title"] == "A")
        #expect(f["status"] == "done")
        #expect(body == "body\n")
    }

    @Test func keysAreCaseInsensitive() {
        let (f, _) = Frontmatter.parse("---\nTitle: X\n---\n")
        #expect(f["title"] == "X")
    }

    @Test func settingReplacesAddsRemoves() {
        let text = "---\ntitle: \"x\"\nstatus: todo\n---\n\nbody"
        let replaced = Frontmatter.setting("status", to: "done", in: text)
        #expect(replaced == "---\ntitle: \"x\"\nstatus: done\n---\n\nbody")
        let added = Frontmatter.setting("size", to: "s", in: text)
        #expect(added == "---\ntitle: \"x\"\nstatus: todo\nsize: s\n---\n\nbody")
        let removed = Frontmatter.setting("status", to: "", in: text)
        #expect(removed == "---\ntitle: \"x\"\n---\n\nbody")
    }

    @Test func settingCreatesFrontmatter() {
        let out = Frontmatter.setting("name", to: "P", in: "# About", defaults: ["status: active"])
        #expect(out == "---\nstatus: active\nname: P\n---\n\n# About")
    }

    @Test func slugTransliterates() {
        #expect(Codec.slug("Тесты парсера!") == "testy-parsera")
        #expect(Codec.slug("  --Hello,  World--  ") == "hello-world")
    }
}
