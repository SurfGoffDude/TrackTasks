import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Доказательства критериев")
struct EvidenceTests {
    static let body = """
        Описание.

        - [ ] шаг

        ## Критерии готовности
        - [x] тесты
          - Доказательство: `swift test` — прошли
            - [ ] вывод, не пункт
            # вывод, не заголовок
            ещё строка
        - [x] README
        - [ ] ревью

        ## Заметки
        - 16.11 10:00 — старт
        """

    private func criteria(_ t: String) -> [MD.CheckItem] { MD.checklist(t, in: .criteria) }

    @Test func parsesAndDoesNotCountNestedText() {
        let c = criteria(Self.body)
        #expect(c.map(\.text) == ["тесты", "README", "ревью"])
        #expect(c.map(\.n) == [1, 2, 3])
        #expect(c[0].evidence == "`swift test` — прошли\n- [ ] вывод, не пункт\n# вывод, не заголовок\nещё строка")
        #expect(c[1].evidence.isEmpty)
        #expect(MD.progress(Self.body) == (2, 4))
        #expect(MD.checklist(Self.body).map(\.text) == ["шаг"])
        #expect(MD.notes(Self.body).count == 1)
        #expect(MD.withoutTasks(Self.body) == "Описание.")
        #expect(MD.toggleTask(Self.body, 3).contains("- [x] ревью"))
        #expect(criteria(MD.toggleTask(Self.body, 1))[0].evidence == c[0].evidence)
    }

    @Test func fences() {
        for open in ["  - Доказательство: вывод\n    ```\n    - [x] мусор", "  - Доказательство: ```\n    мусор"] {
            // Never closed.
            let t = "## Критерии готовности\n- [x] a\n\(open)\n- [ ] b\n\n## Вопросы\n1. Как?\n\n## Находки\n- x"
            #expect(criteria(t).map(\.text) == ["a", "b"], "\(open)")
            #expect(AgentQuestions.parse(t).count == 1)
            #expect(MD.progress(t) == (1, 2))
            // Closed inside.
            #expect(criteria(t.replacingOccurrences(of: "\n- [ ] b", with: "\n    ```\n- [ ] b")).map(\.text) == ["a", "b"])
        }
        // Output without indent: the closing line doesn't open a new fence.
        #expect(criteria("## Критерии готовности\n- [x] a\n  - Доказательство:\n    ```\nвывод\n    ```\n- [ ] b").map(\.text) == ["a", "b"])
        let code = "## Критерии готовности\n- [x] a\n```\n  - Доказательство: нет\n```\n- [ ] b"
        #expect(criteria(code).map(\.evidence) == ["", ""] && criteria(code).count == 2)
    }

    @Test func belongsToItsCriterion() {
        let t = "## Критерии готовности\n- [x] a\n  продолжение\n\n  - Доказательство: A\n\n    ещё\n  - [x] a1\n    - Доказательство: A1\n- [x] b\n- Доказательство: мимо\n- [x] c\n  * доказательство: …\r\n- [x] d\n\t- Доказательство: D1\n\t- Доказательство: D2"
        #expect(criteria(t).map(\.text) == ["a", "a1", "b", "c", "d"])
        #expect(criteria(t).map(\.evidence) == ["A\nещё", "A1", "", "", "D1\nD2"])
        // Only in the criteria.
        let plain = "- [x] a\n  - Доказательство: A\n    - [ ] вложенный"
        #expect(MD.checklist(plain).map(\.text) == ["a", "вложенный"])
        #expect(MD.checklist(plain).allSatisfy { $0.evidence.isEmpty })
    }

    @Test func oldTasks() {
        let old = "- [ ] a\n  - [x] a1\n\n## Критерии готовности\n- [x] b\n  - [ ] b1\n  - просто текст\n\n## Итог\nДоказательство: нет."
        #expect(criteria(old).map(\.text) == ["b", "b1"])
        #expect(MD.progress(old) == (2, 4))
        #expect(Evidence.masked(old) == old)
        #expect(Evidence.missing(criteria(old), asked: false).isEmpty)
        #expect(Evidence.missing(criteria(old), asked: true).map(\.text) == ["b"])
        #expect(Evidence.missing(criteria(Self.body), asked: false).map(\.text) == ["README"])
    }

    @Test func writingKeepsTheRest() {
        let added = Evidence.set(Self.body, 2, " README.md:46\n и пример ")
        #expect(criteria(added)[1].evidence == "README.md:46 и пример")
        #expect(Evidence.set(added, 2, "") == Self.body)
        #expect(Evidence.set(Self.body, 0, "x") == Self.body)
        #expect(Evidence.set(Self.body, 9, "x") == Self.body)
        let replaced = Evidence.set(Self.body, 1, "новое")
        #expect(criteria(replaced).map(\.evidence) == ["новое", "", ""])
        #expect(!replaced.contains("ещё строка") && replaced.contains("- [x] README"))
        let wrapped = "## Критерии готовности\n- [x] a\n  дальше\n- [ ] b"
        #expect(Evidence.set(wrapped, 0, "A") == "## Критерии готовности\n- [x] a\n  дальше\n  - Доказательство: A\n- [ ] b")

        let removed = MD.removeTask(Self.body, 1)
        #expect(criteria(removed).map(\.text) == ["README", "ревью"] && !removed.contains("вывод"))
        let last = MD.appendTask("## Критерии готовности\n- [x] a\n  - Доказательство: A\n    ещё\n\n## Итог", "b", in: .criteria)
        #expect(last == "## Критерии готовности\n- [x] a\n  - Доказательство: A\n    ещё\n- [ ] b\n\n## Итог")
    }

    @Test func codecRoundTrip() {
        let text = "---\ntitle: \"x\"\nstatus: todo\npriority: low\ncreated: 2026-11-24\ncompleted:\n---\n\n\(Self.body)\n"
        var t = Codec.task(from: text, url: URL(fileURLWithPath: "/tmp/20261124-000000-x.md"))
        t.status = .doing
        #expect(Codec.task(from: Codec.serialize(t, updating: text), url: t.url).body.trimmingCharacters(in: .newlines) == Self.body)
    }

    /// The agent ticks every item with evidence, the person ticks one of them or their neighbour.
    @Test func merge() {
        let base = "- [ ] a\n- [ ] b\n- [ ] c\n- [ ] d"
        let agent = "- [x] a\n  - Доказательство: A\n- [x] b\n  - Доказательство: B\n- [x] c\n  - Доказательство: C\n- [ ] d"
        for (o, n) in [("- [ ] b", "- [x] b"), ("- [ ] c", "- [x] c")] {
            #expect(TaskMerge.lines(base: base, mine: base.replacingOccurrences(of: o, with: n), current: agent) == agent)
        }
        let mine = base.replacingOccurrences(of: "- [ ] d", with: "- [x] d")
        #expect(TaskMerge.lines(base: base, mine: mine, current: agent) == agent.replacingOccurrences(of: "- [ ] d", with: "- [x] d"))
    }

    @Test func trackerCheckIsNotTheAgentsWords() {
        func check(_ note: String, failed: Bool = false, active: Bool = false, notRun: Bool = false, red: Bool = false) -> Evidence.Check {
            .of(note: note, failed: failed, active: active, notRun: notRun, mergeRed: red)
        }
        let ok = Evidence.passedMark + "swift test"
        #expect(check(ok) == .passed(ok))
        #expect(check(ok, active: true) == .working)
        #expect(check(ok, red: true) == .partial("Без свежего main · " + ok))
        #expect(check("Не проверено: x. " + ok) == .partial("Не проверено: x. " + ok))
        #expect(check("Не проверено: x") == .notRun("Не проверено: x"))
        #expect(check("Проверка не уложилась", failed: true) == .failed("Проверка не уложилась"))
        #expect(check("ждёт", failed: true, notRun: true) == .notRun("ждёт"))
        #expect(check("") == .notRun(""))
    }
}
