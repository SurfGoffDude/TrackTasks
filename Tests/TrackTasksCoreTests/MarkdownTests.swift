import Foundation
import Testing
@testable import TrackTasksCore

@Suite("MD")
struct MarkdownTests {
    static let body = """
        Описание, см. docs/x.md и https://example.com/a.

        - [ ] первый
        - [x] второй

        ```
        - [ ] в коде — не пункт
        ```

        ## Критерии готовности
        - [ ] тесты проходят

        ## Заметки
        - 16.11 10:00 — старт
        - 16.11 11:00 — находка
        """

    @Test func checklistBySection() {
        let plain = MD.checklist(Self.body)
        #expect(plain == [MD.CheckItem(n: 0, done: false, text: "первый"), MD.CheckItem(n: 1, done: true, text: "второй")])
        let criteria = MD.checklist(Self.body, in: .criteria)
        #expect(criteria == [MD.CheckItem(n: 2, done: false, text: "тесты проходят")])
        #expect(MD.checklist(Self.body, in: .notes).isEmpty)
    }

    @Test func taskLinesSkipCodeFences() {
        #expect(MD.taskLines(Self.body.components(separatedBy: "\n")).count == 3)
    }

    @Test func toggleTask() {
        let once = MD.toggleTask(Self.body, 0)
        #expect(once.contains("- [x] первый"))
        let twice = MD.toggleTask(MD.toggleTask(Self.body, 1), 1)
        #expect(twice == Self.body)
        #expect(MD.toggleTask(Self.body, 2).contains("- [x] тесты проходят"))
        #expect(MD.toggleTask(Self.body, 99) == Self.body)
    }

    @Test func removeTask() {
        let out = MD.removeTask(Self.body, 0)
        #expect(!out.contains("первый"))
        #expect(MD.checklist(out).count == 1)
    }

    @Test func notesParsed() {
        #expect(MD.notes(Self.body) == ["16.11 10:00 — старт", "16.11 11:00 — находка"])
    }

    static func date(_ h: Int, _ m: Int) -> Date {
        DateComponents(calendar: Calendar.current, year: 2026, month: 11, day: 16, hour: h, minute: m).date!
    }

    @Test func appendNoteAtEndOfNotes() {
        let out = MD.appendNote(Self.body, "итог\nв две строки", date: Self.date(14, 5))
        #expect(out.hasSuffix("- 16.11 11:00 — находка\n- 16.11 14:05 — итог в две строки"))
        #expect(MD.notes(out).count == 3)
    }

    @Test func appendNoteWhenNotesNotLast() {
        let text = "Текст\n\n## Заметки\n- 16.11 10:00 — a\n\n## Итог\nготово"
        let out = MD.appendNote(text, "b", date: Self.date(12, 0))
        #expect(out == "Текст\n\n## Заметки\n- 16.11 10:00 — a\n- 16.11 12:00 — b\n\n## Итог\nготово")
    }

    @Test func appendNoteCreatesSection() {
        let out = MD.appendNote("Текст\n", "первая", date: Self.date(9, 30))
        #expect(out == "Текст\n\n## Заметки\n\n- 16.11 09:30 — первая")
        #expect(MD.appendNote("Текст", "   ") == "Текст")
    }

    @Test func appendTaskPlainGoesBeforeSections() {
        let out = MD.appendTask(Self.body, "третий")
        #expect(MD.checklist(out).map(\.text) == ["первый", "второй", "третий"])
        let noList = MD.appendTask("Описание\n\n## Критерии готовности\n- [ ] c", "новый")
        #expect(noList == "Описание\n\n- [ ] новый\n\n## Критерии готовности\n- [ ] c")
    }

    @Test func appendTaskToCriteria() {
        let out = MD.appendTask(Self.body, "сборка", in: .criteria)
        #expect(MD.checklist(out, in: .criteria).map(\.text) == ["тесты проходят", "сборка"])
    }

    @Test func sectionHeadingVariants() {
        #expect(MD.Section.criteria.matches("Критерии готовности"))
        #expect(MD.Section.criteria.matches("Definition of Done"))
        #expect(MD.Section.notes.matches("Журнал"))
        #expect(!MD.Section.notes.matches("Итог"))
    }

    @Test func references() {
        let refs = MD.references("См. docs/x.md, `Sources/A/B.swift` и (https://example.com/a). Снова docs/x.md. v1.2 и a/b.")
        #expect(refs == ["docs/x.md", "Sources/A/B.swift", "https://example.com/a"])
    }

    @Test func withoutTasksKeepsDescriptionOnly() {
        let d = MD.withoutTasks(Self.body)
        #expect(d.hasPrefix("Описание"))
        #expect(!d.contains("первый"))
        #expect(!d.contains("Критерии"))
        #expect(!d.contains("Заметки"))
        #expect(d.contains("в коде — не пункт"))
    }

    @Test func descriptionHasNoQuestions() {
        let d = MD.withoutTasks("Описание.\n\n## Вопросы\nВведение.\n1. A?\n   - да\n\n### Детали\nтекст\n\n## Итог\nСделано.\n\n## Находки\n- раз")
        #expect(d == "Описание.\n\n## Итог\nСделано.\n\n## Находки\n- раз")
        // Nothing the card could show: the text stays in the description.
        #expect(MD.withoutTasks("Описание.\n\n## Вопросы\n```\nкод\n```").contains("код"))
        #expect(MD.withoutTasks("Описание.\n\n### Вопросы\n- A?").contains("A?"))
    }

    @Test func progressCountsAllCheckboxes() {
        let (done, total) = MD.progress(Self.body)
        #expect(done == 1)
        #expect(total == 3)
    }

    @Test func parseBlocks() {
        let blocks = MD.parse("# H\n\nпара\nграф\n\n1. one\n> q\n---\n| a | b |\n|---|---|\n| 1 | 2 |", hideH1: true)
        #expect(blocks == [.paragraph("пара\nграф"), .ordered(indent: 0, "1", "one"), .quote("q"), .rule,
                           .table(["a", "b"], [["1", "2"]])])
    }
}
