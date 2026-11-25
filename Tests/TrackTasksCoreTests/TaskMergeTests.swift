import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Слияние правок задачи")
struct TaskMergeTests {
    @Test func lines() {
        let m = { TaskMerge.lines(base: $0, mine: $1, current: $2) }
        #expect(m("a\nb\nc", "A\nb\nc", "a\nb\nC") == "A\nb\nC")
        #expect(m("a", "a", "b") == "b")
        #expect(m("a", "b", "a") == "b")
        #expect(m("a", "b", "b") == "b")
        #expect(m("a\nb\nc", "a\nX\nc", "a\nY\nc") == nil)
        #expect(m("a\nb\nc", "a\nc", "a\nY\nc") == nil)
        // Ticks on neighbouring items, one of them with a new item after it.
        #expect(m("- [ ] a\n- [ ] b", "- [x] a\n- [ ] b", "- [ ] a\n- [x] b\n- [ ] c") == "- [x] a\n- [x] b\n- [ ] c")
        // Both sides add list items; the same item isn't doubled.
        #expect(m("- a", "- a\n- m", "- a\n- t") == "- a\n- t\n- m")
        #expect(m("- a\ny\nx", "- a\n- m\ny\nX", "- a\n- m\ny\nx") == "- a\n- m\ny\nX")
        // Prose at one place is for the person to sort out.
        #expect(m("a", "a\nm", "a\nt") == nil)
        #expect(m("", "m", "t") == nil)
    }

    @Test func notesStayInTheirSection() {
        let base = "Описание.\n\n- [ ] a\n- [ ] b\n\n## Заметки\n- старт"
        let m = { TaskMerge.lines(base: base, mine: $0, current: $1) }
        #expect(m(base + "\n- я", base + "\n- tt\n\n## Итог\nГотово") == base + "\n- tt\n- я\n\n## Итог\nГотово")
        #expect(m(base + "\n\n## Итог\nГотово", base + "\n- tt") == base + "\n- tt\n\n## Итог\nГотово")
        // The section was deleted: no place for the note.
        #expect(m(base + "\n- я", "Описание.\n\n- [ ] a\n- [ ] b") == nil)
    }

    @Test func lockHeldByAnotherIsAnErrorAfterTheTimeout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fd = open(dir.path, O_RDONLY)
        #expect(flock(fd, LOCK_EX) == 0)
        #expect(throws: TaskFile.Failure.self) { try TaskFile.locked(dir, timeout: 0.05) {} }
        close(fd)
        try TaskFile.locked(dir, timeout: 1) {}
    }

    @Test func fields() {
        var base = TaskItem(url: URL(fileURLWithPath: "/t/a.md"), title: "A", status: .todo, priority: .low, created: "", completed: "", body: "x")
        base.depends = ["1", "2"]
        var mine = base, current = base
        mine.depends = ["2", "3"]
        current.depends = ["1", "2", "4"]
        current.status = .done
        current.completed = "2026-11-01"
        mine.body = "x\n"
        let r = TaskMerge.merge(base: base, mine: mine, current: current)
        #expect(r.conflicts.isEmpty && r.item.depends == ["2", "4", "3"])
        #expect(r.item.status == .done && r.item.completed == "2026-11-01")
        mine.status = .doing
        let c = TaskMerge.merge(base: base, mine: mine, current: current)
        #expect(c.conflicts == ["статус"] && c.item.status == .doing)
    }
}
