import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Комментарии и решения")
struct CommentsDecisionsTests {
    static let body = """
        Описание.

        - [ ] шаг

        ## Комментарии
        - 24.11.2026 14:30 — Артём: смотри [ ] тут
        - [ ] чекбокс в комментарии
        - 24.11.2026 15:00 — Claude: готово

        ## Критерии готовности
        - [ ] критерий

        ## Заметки
        - 24.11 10:00 — заметка
        """

    @Test func parsesComments() {
        let c = MD.comments(Self.body)
        #expect(c.count == 3)
        #expect(c[0] == MD.Comment(date: "24.11.2026 14:30", author: "Артём", text: "смотри [ ] тут"))
        #expect(c[2].author == "Claude")
    }

    @Test func checkboxesInCommentsAreNotSteps() {
        #expect(MD.checklist(Self.body).map(\.text) == ["шаг"])
        #expect(MD.checklist(Self.body, in: .criteria).map(\.text) == ["критерий"])
        #expect(MD.withoutTasks(Self.body) == "Описание.")
        #expect(MD.notes(Self.body).count == 1)
    }

    @Test func appendKeepsEverythingElseByteForByte() {
        let d = Date(timeIntervalSince1970: 1_795_000_000)
        let out = MD.appendComment(Self.body, author: "Я", "новый", date: d)
        #expect(MD.comments(out).count == 4)
        #expect(MD.comments(out).last?.text == "новый")
        let removed = MD.removeComment(out, 3)
        #expect(removed == Self.body)
    }

    @Test func appendCreatesSection() {
        let out = MD.appendComment("Просто.\n\n- [ ] шаг", author: "", "привет")
        #expect(out.contains("## Комментарии"))
        #expect(MD.comments(out).first?.author == "Пользователь")
        #expect(MD.checklist(out).map(\.text) == ["шаг"])
    }

    @Test func removeComment() {
        let out = MD.removeComment(Self.body, 1)
        #expect(MD.comments(out).count == 2)
        #expect(out.contains("чекбокс в комментарии") == false)
    }

    @Test func decisionRoundTripKeepsManualEdits() {
        let text = "# Выбор БД\n\nСтатус: предложено\n\nДлинный текст.\n```\nСтатус: принято\n```\n"
        let d = Decision.parse(text, fileName: "db.md")
        #expect(d.title == "Выбор БД" && d.status == .proposed)
        let out = Decision.settingStatus(text, .accepted)
        #expect(out == text.replacingOccurrences(of: "Статус: предложено", with: "Статус: принято"))
        let linked = Decision.linkingTask(out, "tasks/a.md")
        #expect(Decision.parse(linked, fileName: "db.md").tasks == ["a.md"])
        #expect(Decision.unlinkingTask(linked, "a.md") == out)
    }

    @Test func decisionLinks() {
        let a = Decision.parse(Decision.make(title: "A", tasks: ["t.md"]), fileName: "a.md")
        let b = Decision.parse(Decision.make(title: "B"), fileName: "b.md")
        #expect(Decision.linked(to: "t.md", body: "x", in: [a, b]).map(\.fileName) == ["a.md"])
        #expect(Decision.linked(to: "z.md", body: "см. docs/decisions/b.md", in: [a, b]).map(\.fileName) == ["b.md"])
    }

    @Test func slug() {
        #expect(Decision.slug("Выбор БД!") == "vybor-bd")
        #expect(Decision.slug("???") == "decision")
    }
    @Test func removeTakesContinuationAndPlainColonIsNotAuthor() {
        let t = "## Комментарии\n- 24.11.2026 10:00 — А: раз\n  продолжение\n- Note: foo\n"
        #expect(MD.comments(t)[1] == MD.Comment(date: "", author: "", text: "Note: foo"))
        #expect(MD.removeComment(t, 0) == "## Комментарии\n- Note: foo\n")
    }

    @Test func fencedPathDoesNotLink() {
        let a = Decision.parse(Decision.make(title: "B"), fileName: "b.md")
        #expect(Decision.linked(to: "z.md", body: "```\ndocs/decisions/b.md\n```", in: [a]).isEmpty)
    }
}
