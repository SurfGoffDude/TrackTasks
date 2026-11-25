import Foundation
import Testing
@testable import TrackTasksCore

private func card(_ n: String, _ s: TaskStatus, _ p: Priority = .medium, title: String? = nil) -> BoardModel.Card {
    .init(id: "/p/\(n).md", project: "p", fileName: "\(n).md", title: title ?? n, priority: p, status: s, rev: "r")
}

@Suite("tt board: интерактивная доска")
struct CLIBoardTests {
    @Test func navigationAndTargets() {
        var m = BoardModel()
        m.load([card("a", .todo), card("b", .todo), card("c", .doing)])
        #expect(m.selected?.fileName == "a.md")
        m.navigate(.down); m.navigate(.down)
        #expect(m.selected?.fileName == "b.md")
        m.navigate(.right)
        #expect(m.selected?.fileName == "c.md")
        #expect(m.target(.move(1)) == .done)
        #expect(m.target(.move(-1)) == .todo)
        #expect(m.target(.set(.doing)) == nil)
        m.navigate(.right)
        #expect(m.selected == nil)           // empty column
        #expect(m.target(.move(1)) == nil)
    }

    @Test func selectionFollowsCardAfterReload() {
        var m = BoardModel()
        m.load([card("a", .todo), card("b", .todo)])
        m.navigate(.down)
        m.load([card("a", .todo), card("b", .doing)], keep: "/p/b.md")
        #expect(m.col == 1 && m.selected?.fileName == "b.md")
        m.load([])   // everything is gone: no crash, nothing selected
        #expect(m.selected == nil)
    }

    @Test func keys() {
        #expect(BoardModel.keys([0x1B, 0x5B, 0x41, 0x1B, 0x5B, 0x42]) == [.up, .down])
        #expect(BoardModel.keys(Array("jlHL3q".utf8)) == [.down, .right, .move(-1), .move(1), .set(.done), .quit])
        #expect(BoardModel.keys([0x03]) == [.quit])
        #expect(BoardModel.keys([0x1B]) == [.quit])
        #expect(BoardModel.keys([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x43]) == [.right])
        #expect(BoardModel.keys([0xFF, 0x00, 0x7A]) == [])
    }

    @Test func frameFitsAndIsClean() {
        var m = BoardModel()
        m.load((0..<30).map { card("t\($0)", .todo, title: "№\($0) длинное название задачи\u{1B}[31m") } + [card("d", .done)])
        for _ in 0..<25 { m.navigate(.down) }
        let f = m.frame(width: 60, height: 12, ansi: false)
        #expect(f.count == 12 - 3 + 3)
        #expect(f.allSatisfy { $0.count <= 60 })
        #expect(f.joined().contains("\u{1B}") == false)
        #expect(f.joined().contains("№25 "))      // scrolled to the cursor
    }

    @Test func fitCutsAndPads() {
        #expect(BoardModel.fit("abcdef", 4) == "abc…")
        #expect(BoardModel.fit("ab", 4) == "ab  ")
        #expect(BoardModel.fit("a\u{7}b", 3) == "a b")
    }

    /// Without a terminal the old text board: no escape sequences, even when only stdout is a TTY.
    @Test func plainOutputHasNoControlCharacters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("cat/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        try Data("---\ntitle: \"Альфа\"\nstatus: todo\npriority: high\ncreated: 2026-11-01\ncompleted:\n---\n\nтекст\n".utf8)
            .write(to: project.appendingPathComponent("tasks/20261101-100000-alpha.md"))
        for (stdout, stdin) in [(false, false), (true, false)] {
            var out = ""
            let cli = CLI(cwd: project, root: root, isTTY: stdout, stdinTTY: stdin, out: { out += $0 }, err: { _ in })
            #expect(cli.run(["board"]) == 0)
            #expect(out.contains("Альфа"))
            #expect(out.unicodeScalars.allSatisfy { $0 == "\n" || $0.value >= 0x20 })
        }
    }
}
