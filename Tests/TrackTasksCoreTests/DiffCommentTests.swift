import XCTest
@testable import TrackTasksCore

final class DiffCommentTests: XCTestCase {
    private func file(_ lines: [DiffLine], path: String = "a.swift") -> DiffFile {
        var f = DiffFile(oldPath: path, newPath: path)
        f.hunks = [DiffHunk(oldStart: 1, oldCount: 3, newStart: 1, newCount: 3, lines: lines)]
        return f
    }
    private let base = [
        DiffLine(kind: .context, text: "one", oldNumber: 1, newNumber: 1),
        DiffLine(kind: .removed, text: "two", oldNumber: 2),
        DiffLine(kind: .added, text: "TWO", newNumber: 2),
        DiffLine(kind: .context, text: "three", oldNumber: 3, newNumber: 3),
    ]

    func testSnippetSides() {
        let f = file(base)
        XCTAssertEqual(DiffComment.snippet(of: f, side: .new, start: 1, end: 3), ["one", "TWO", "three"])
        XCTAssertEqual(DiffComment.snippet(of: f, side: .old, start: 1, end: 3), ["one", "two", "three"])
        XCTAssertEqual(DiffComment.snippet(of: f, side: .new, start: 9, end: 9), [])
    }

    func testMakeNeedsLines() {
        XCTAssertNil(DiffComment.make(file: file(base), side: .new, start: 50, end: 51, text: "x"))
        let c = DiffComment.make(file: file(base), side: .new, start: 3, end: 2, text: "x")
        XCTAssertEqual(c?.lines, "2–3")
    }

    func testAnchor() {
        XCTAssertEqual(DiffComments.anchor(base.map { .line($0) })?.side, .new)
        XCTAssertEqual(DiffComments.anchor(base.map { .line($0) })?.start, 1)
        let onlyRemoved = DiffComments.anchor([.line(base[1])])
        XCTAssertEqual(onlyRemoved?.side, .old)
        XCTAssertEqual(onlyRemoved?.end, 2)
        XCTAssertNil(DiffComments.anchor([.hunk("@@")]))
        let pair = DiffComments.anchor([.pair(left: base[1], right: base[2])])
        XCTAssertEqual(pair?.side, .new)
    }

    func testOutdated() {
        let f = file(base)
        let c = DiffComment.make(file: f, side: .new, start: 2, end: 3, text: "t")!
        XCTAssertFalse(c.isOutdated(in: f))
        XCTAssertTrue(c.isOutdated(in: nil))
        var changed = base
        changed[2].text = "TWO!"
        XCTAssertTrue(c.isOutdated(in: file(changed)))
        // Другая строка файла не делает комментарий устаревшим.
        var other = base
        other[0].text = "uno"
        XCTAssertFalse(c.isOutdated(in: file(other)))
    }

    func testFormat() {
        let f = file(base)
        let a = DiffComment.make(file: f, side: .new, start: 2, end: 3, text: "Почему так?")!
        let b = DiffComment.make(file: f, side: .old, start: 2, end: 2, text: "Верни")!
        let empty = DiffComment.make(file: f, side: .new, start: 1, end: 1, text: "  ")!
        let msg = DiffComments.format([a, b, empty], outdated: [b.id])
        XCTAssertTrue(msg.contains("(2)"))
        XCTAssertTrue(msg.contains("1. a.swift:2–3\n```\nTWO\nthree\n```\nКомментарий: Почему так?"))
        XCTAssertTrue(msg.contains("2. a.swift:2 (старая версия, удалённые строки) — строки с тех пор изменились"))
        XCTAssertFalse(msg.contains("3."))
        XCTAssertEqual(DiffComments.format([empty]), "")
    }

    func testFenceGrowsAroundBackticks() {
        let l = [DiffLine(kind: .added, text: "```", newNumber: 1)]
        let c = DiffComment.make(file: file(l), side: .new, start: 1, end: 1, text: "t")!
        XCTAssertTrue(DiffComments.format([c]).contains("````\n```\n````"))
    }

    func testMarksAndCodable() throws {
        let f = file(base)
        let a = DiffComment.make(file: f, side: .new, start: 2, end: 3, text: "t")!
        let m = DiffComments.marks([a], outdated: [a.id])
        XCTAssertEqual(m["new:2"], true)
        XCTAssertEqual(m["new:3"], true)
        XCTAssertNil(m["new:1"])
        let back = try JSONDecoder().decode([DiffComment].self, from: JSONEncoder().encode([a]))
        XCTAssertEqual(back, [a])
    }

    func testFileNameStable() {
        XCTAssertEqual(DiffComments.fileName(forKey: "x"), DiffComments.fileName(forKey: "x"))
        XCTAssertNotEqual(DiffComments.fileName(forKey: "x"), DiffComments.fileName(forKey: "y"))
    }

    // MARK: Сдвиг строк

    /// Файл, у которого в diff видны все строки: новая сторона либо (`side: .old`) целиком удалённая.
    private func whole(_ text: [String], _ side: DiffComment.Side = .new, from: Int = 1, path: String = "a.swift") -> DiffFile {
        file(text.enumerated().map { i, t in
            side == .new ? DiffLine(kind: .added, text: t, newNumber: from + i) : DiffLine(kind: .removed, text: t, oldNumber: from + i)
        }, path: path)
    }
    private let code = ["func a() {", "    first()", "    return nil", "}", "", "func b() {", "    second()", "    return nil", "}"]
    private func comment(_ text: [String], _ start: Int, _ end: Int? = nil, _ side: DiffComment.Side = .new) -> DiffComment {
        DiffComment.make(file: whole(text, side), side: side, start: start, end: end ?? start, text: "t")!
    }

    func testInsertAndDeleteAbove() {
        let c = comment(code, 6, 7)
        XCTAssertEqual(c.moved(in: whole(["import A", ""] + code))?.lines, "8–9")
        XCTAssertEqual(c.moved(in: whole(Array(code.dropFirst(2))))?.lines, "4–5")
        // Прямо над местом.
        XCTAssertEqual(c.moved(in: whole(Array(code[..<5]) + ["// b"] + code[5...]))?.lines, "7–8")
        XCTAssertEqual(c.start, 6)
    }

    func testDeletedSide() {
        let c = comment(code, 7, 7, .old)
        XCTAssertEqual(c.moved(in: whole(["x"] + code, .old))?.lines, "8")
        // Другая сторона не подходит.
        XCTAssertNil(c.moved(in: whole(code)))
    }

    func testRealDiffSidesAndCRLF() {
        func diff(_ up: String, _ n: Int) -> DiffFile {
            let up = up.isEmpty ? "" : "+" + up + "\r\n"
            return DiffParser.parse("diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1,3 +1,\(n) @@\n"
                + up + " one\r\n-old line\r\n+new line\r\n two\r\n").files[0]
        }
        let f = diff("", 3)
        let c = DiffComment.make(file: f, side: .new, start: 2, end: 2, text: "t")!
        XCTAssertEqual(c.snippet, ["new line"])
        XCTAssertEqual(c.before, ["one"])
        XCTAssertEqual(c.moved(in: diff("zero", 4))?.lines, "3")
        // Удалённая строка вставкой в новую версию не сдвигается.
        let o = DiffComment.make(file: f, side: .old, start: 2, end: 2, text: "t")!
        XCTAssertEqual(o.moved(in: diff("zero", 4))?.lines, "2")
        // CRLF → LF.
        XCTAssertEqual(c.moved(in: whole(["zero", "one", "new line", "two"]))?.lines, "3")
        XCTAssertEqual(comment(code, 7).moved(in: whole((["x"] + code).map { $0 + "\r" }))?.lines, "8")
    }

    func testSameTextDifferentNeighbours() {
        let c = comment(code, 8)
        XCTAssertEqual(c.moved(in: whole(["x"] + code))?.lines, "9")
        // Место удалено, похожая строка осталась.
        XCTAssertEqual(c.locate(in: whole(["y"] + code[..<6])), .ambiguous)
        // На старом номере оказалась похожая строка.
        let shifted = ["1", "2", "3", "4", "5"] + code
        XCTAssertEqual(shifted[7], code[7])
        XCTAssertEqual(c.moved(in: whole(shifted))?.lines, "13")
    }

    func testAmbiguousIsNotGuessed() {
        let block = ["a()", "b()", "c()", "X", "d()", "e()", "f()"]
        let c = comment(block + block, 4)
        // Пока выше ничего не менялось, место известно точно.
        XCTAssertEqual(c.moved(in: whole(block + block))?.lines, "4")
        XCTAssertEqual(c.moved(in: whole(block + block + ["end"]))?.lines, "4")
        XCTAssertEqual(c.locate(in: whole(["x"] + block + block)), .ambiguous)
        // Один из двух одинаковых кусков исчез: который — неизвестно.
        XCTAssertEqual(c.locate(in: whole(["x"] + block)), .ambiguous)
        XCTAssertEqual(c.locate(in: whole(block)), .found(4))
        // Копия появилась потом.
        let one = comment(block, 4)
        XCTAssertNil(one.moved(in: whole(["x"] + block + block)))
        // Без контекста одинаковые строки не различить.
        XCTAssertEqual(DiffComment(path: "a.swift", side: .new, start: 8, end: 8, snippet: ["    return nil"], text: "t")
            .locate(in: whole(code)), .ambiguous)
    }

    func testChangedLineIsMissing() {
        var changed = ["x"] + code
        changed[7] = "    other()"
        XCTAssertEqual(comment(code, 7).locate(in: whole(changed)), .missing)
        // Вставка внутрь диапазона.
        XCTAssertNil(comment(code, 6, 7).moved(in: whole(Array(code[..<6]) + ["    new()"] + code[6...])))
    }

    func testTruncatedFileNeedsNeighbours() {
        var f = whole(["x", "func b() {", "    someVeryLongDistinctiveCall()"])
        let c = comment(["    someVeryLongDistinctiveCall()", "zzz"], 1)
        XCTAssertEqual(c.moved(in: f)?.lines, "3")
        f.truncated = true
        XCTAssertNil(c.moved(in: f))
    }

    func testOldDraftFile() throws {
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","path":"a.swift","side":"new","start":7,"end":7,
          "snippet":["    second()"],"text":"t","created":"2026-11-23T10:00:00Z"}]
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let c = try d.decode([DiffComment].self, from: Data(json.utf8))[0]
        XCTAssertNil(c.before)
        XCTAssertNil(c.head)
        XCTAssertEqual(c.moved(in: whole(code))?.lines, "7")
        XCTAssertEqual(c.moved(in: whole(["x"] + code))?.lines, "8")
        XCTAssertTrue(c.isOutdated(in: whole(Array(code.prefix(5)))))
    }

    func testPlaces() {
        func section(_ kind: DiffSection.Kind, _ f: DiffFile) -> DiffSection {
            DiffSection(kind: kind, entries: [.init(id: "\(kind)", file: f, untracked: false, fingerprint: "")])
        }
        let branch = section(.branch, whole(["x"] + code)), working = section(.working, whole(["x", "y"] + code))
        var c = DiffComment.make(file: whole(code), side: .new, start: 7, end: 7, text: "Зачем?", section: .working)!
        let p = DiffComments.places([c], in: [branch, working])[c.id]
        XCTAssertEqual(p?.entries, ["working"])
        XCTAssertEqual(p?.comment.lines, "9")
        XCTAssertTrue(DiffComments.format([p!.comment]).contains("a.swift:9\n"))
        XCTAssertEqual(DiffComments.marks([p!.comment], outdated: []), ["new:9": false])
        // Закоммитили.
        XCTAssertEqual(DiffComments.places([c], in: [branch, section(.working, whole(["z"]))])[c.id]?.entries, ["branch"])
        XCTAssertTrue(DiffComments.places([c], in: []).isEmpty)
        // Раздел неизвестен, места разные.
        c.section = nil
        XCTAssertTrue(DiffComments.places([c], in: [branch, working]).isEmpty)
        XCTAssertEqual(DiffComments.places([c], in: [branch])[c.id]?.comment.lines, "8")
    }
}
