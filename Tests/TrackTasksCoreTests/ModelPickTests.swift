import Testing
@testable import TrackTasksCore

@Suite("ModelPick.heuristic")
struct ModelPickTests {
    @Test func sizeDecidesWithoutHaiku() {
        #expect(ModelPick.heuristic(title: "Архитектура", body: "", size: "s") == .sonnet("оценка S"))
        #expect(ModelPick.heuristic(title: "Опечатка", body: "", size: "L") == .opus("оценка L"))
    }

    @Test func sizeIsTrimmedAndCaseInsensitive() {
        #expect(ModelPick.heuristic(title: "Фича", body: "", size: " s ") == .sonnet("оценка S"))
        #expect(ModelPick.heuristic(title: "Фича", body: "", size: "L\n") == .opus("оценка L"))
    }

    @Test func weakMarkerInTitleIsNotOpus() {
        let r = ModelPick.heuristic(title: "Исправить опечатку в тексте про безопасность", body: "Одна буква.", size: "")
        #expect(r == .sonnet("короткая задача") || r == .ask)
        if case .opus = r { Issue.record("слабый маркер в названии не должен давать opus") }
    }

    @Test func hardMarkerInTitleIsOpus() {
        guard case .opus = ModelPick.heuristic(title: "Миграция данных на v2", body: "коротко", size: "") else {
            Issue.record("ожидался opus"); return
        }
    }

    @Test func twoHardMarkersInBodyIsOpus() {
        let body = "Переделать архитектуру очереди и убрать гонки при конкурентном доступе."
        guard case .opus = ModelPick.heuristic(title: "Очередь", body: body, size: "m") else {
            Issue.record("ожидался opus"); return
        }
    }

    @Test func shortPlainTaskIsSonnet() {
        let body = "Поменять текст кнопки «Сохранить» на «Готово».\n\n- [ ] поменять строку\n- [ ] проверить"
        #expect(ModelPick.heuristic(title: "Текст кнопки", body: body, size: "") == .sonnet("короткая задача"))
    }

    @Test func singleMarkerShortTaskAsks() {
        #expect(ModelPick.heuristic(title: "Кнопка", body: "Поправить безопасность ввода.", size: "") == .ask)
    }

    @Test func longOrCodeTaskAsks() {
        let long = String(repeating: "Описание задачи. ", count: 60)
        #expect(ModelPick.heuristic(title: "Фича", body: long, size: "m") == .ask)
        #expect(ModelPick.heuristic(title: "Фича", body: "Сделать так:\n```\nlet x = 1\n```", size: "") == .ask)
        let many = (1...5).map { "- [ ] шаг \($0)" }.joined(separator: "\n")
        #expect(ModelPick.heuristic(title: "Фича", body: many, size: "") == .ask)
    }
}
