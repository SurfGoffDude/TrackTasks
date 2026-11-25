import Foundation
import Testing
@testable import TrackTasksCore

@Suite("BoardExport")
struct BoardExportTests {
    func task(_ file: String, _ title: String, _ st: TaskStatus, _ p: Priority = .medium,
              created: String = "2026-11-01", completed: String = "") -> TaskItem {
        TaskItem(url: URL(fileURLWithPath: "/p/tasks/\(file)"), title: title, status: st, priority: p,
                 created: created, completed: completed, body: "")
    }

    @Test func escapesSpecials() {
        #expect(BoardExport.escape("a*b_c [x](y) `z` | #1") == "a\\*b\\_c \\[x\\](y) \\`z\\` \\| \\#1")
        #expect(BoardExport.escape("- пункт") == "\\- пункт")
        #expect(BoardExport.escape("1. шаг") == "1\\. шаг")
        #expect(BoardExport.escape("a\nb") == "a b")
    }

    @Test func orderIsStable() {
        let a = task("a.md", "A", .todo, .low)
        let b = task("b.md", "B", .todo, .high)
        let c = task("c.md", "C", .todo, .high, created: "2026-10-01")
        let d = task("d.md", "D", .done, completed: "2026-11-20")
        let x = BoardExport.markdown(name: "P", tasks: [a, b, c, d])
        #expect(x == BoardExport.markdown(name: "P", tasks: [d, c, b, a]))
        let ia = x.range(of: "] A")!.lowerBound, ib = x.range(of: "] B")!.lowerBound, ic = x.range(of: "] C")!.lowerBound
        #expect(ic < ib && ib < ia)
        #expect(x.contains("всего 4, в работе 0, к выполнению 3, готово 1 (25%)"))
        #expect(x.contains("- [x] D — средний, завершена 2026-11-20"))
    }

    @Test func titleIsEscapedInOutput() {
        let x = BoardExport.markdown(name: "My_App", tasks: [task("a.md", "Fix *bold* [link]", .doing)])
        #expect(x.hasPrefix("# My\\_App — доска"))
        #expect(x.contains("- [ ] Fix \\*bold\\* \\[link\\] — "))
    }

    @Test func doneNewestFirstAndSummaryLines() {
        let old = task("a.md", "Old", .done, completed: "2026-11-01")
        let new = task("b.md", "New", .done, completed: "2026-11-20")
        let hi = task("c.md", "Hi", .todo, .high)
        let x = BoardExport.markdown(name: "P", tasks: [old, new, hi], archive: [old])
        #expect(x.range(of: "] New")!.lowerBound < x.range(of: "] Old")!.lowerBound)
        #expect(x.contains("\n\nВ архиве: 1\n\nВысокий приоритет в открытых: 1\n"))
        #expect(BoardExport.escape("1) шаг") == "1\\) шаг")
    }

    @Test func emptyBoard() {
        let x = BoardExport.markdown(name: "P", tasks: [])
        #expect(x.contains("всего 0") && x.contains("(0%)") && !x.contains("##"))
    }
}
