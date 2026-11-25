import Foundation
import Testing
@testable import TrackTasksCore

@Suite("DiffParser")
struct DiffParserTests {
    @Test func modifiedFileNumbersLines() {
        let d = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        index 111..222 100644
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -3,4 +3,5 @@ func foo() {
         keep1
        -old
        +new1
        +new2
         keep2

        """
        let r = DiffParser.parse(d)
        #expect(r.files.count == 1)
        let f = r.files[0]
        #expect(f.path == "Sources/A.swift")
        #expect(f.status == .modified)
        #expect(f.additions == 2 && f.deletions == 1)
        let h = f.hunks[0]
        #expect(h.section == "func foo() {")
        #expect(h.oldStart == 3 && h.newStart == 3 && h.newCount == 5)
        #expect(h.lines.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(h.lines[0].oldNumber == 3 && h.lines[0].newNumber == 3)
        #expect(h.lines[1].oldNumber == 4 && h.lines[1].newNumber == nil)
        #expect(h.lines[2].oldNumber == nil && h.lines[2].newNumber == 4)
        #expect(h.lines[3].newNumber == 5)
        #expect(h.lines[4].oldNumber == 5 && h.lines[4].newNumber == 6)
    }

    @Test func addedAndDeleted() {
        let d = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..e69de29
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +a
        +b
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        index e69de29..0000000
        --- a/old.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone

        """
        let r = DiffParser.parse(d)
        #expect(r.files.count == 2)
        #expect(r.files[0].status == .added)
        #expect(r.files[0].oldPath == nil && r.files[0].path == "new.txt")
        #expect(r.files[0].hunks[0].lines.map(\.newNumber) == [1, 2])
        #expect(r.files[1].status == .deleted)
        #expect(r.files[1].newPath == nil && r.files[1].path == "old.txt")
        #expect(r.files[1].hunks[0].lines[0].oldNumber == 1)
    }

    @Test func renameWithAndWithoutChanges() {
        let d = """
        diff --git a/a.txt b/b.txt
        similarity index 100%
        rename from a.txt
        rename to b.txt
        diff --git a/c.txt b/d.txt
        similarity index 80%
        rename from c.txt
        rename to d.txt
        index 1..2 100644
        --- a/c.txt
        +++ b/d.txt
        @@ -1 +1 @@
        -x
        +y

        """
        let r = DiffParser.parse(d)
        #expect(r.files.count == 2)
        #expect(r.files[0].status == .renamed)
        #expect(r.files[0].oldPath == "a.txt" && r.files[0].newPath == "b.txt")
        #expect(r.files[0].similarity == 100 && r.files[0].hunks.isEmpty)
        #expect(r.files[1].similarity == 80 && r.files[1].hunks.count == 1)
        #expect(r.files[1].path == "d.txt")
    }

    @Test func binaryFile() {
        let d = """
        diff --git a/img.png b/img.png
        index 1..2 100644
        Binary files a/img.png and b/img.png differ
        diff --git a/n.txt b/n.txt
        --- a/n.txt
        +++ b/n.txt
        @@ -1 +1 @@
        -a
        +b

        """
        let r = DiffParser.parse(d)
        #expect(r.files.count == 2)
        #expect(r.files[0].isBinary && r.files[0].hunks.isEmpty)
        #expect(r.files[0].path == "img.png")
        #expect(!r.files[1].isBinary && r.files[1].hunks.count == 1)
    }

    @Test func modeChange() {
        let d = """
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755

        """
        let f = DiffParser.parse(d).files[0]
        #expect(f.modeChanged && f.oldMode == "100644" && f.newMode == "100755")
        #expect(f.status == .modified && f.hunks.isEmpty)
    }

    @Test func noNewlineAtEnd() {
        let d = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1 +1 @@
        -a
        \\ No newline at end of file
        +b
        \\ No newline at end of file

        """
        let h = DiffParser.parse(d).files[0].hunks[0]
        #expect(h.lines.map(\.kind) == [.removed, .noNewline, .added, .noNewline])
        #expect(h.lines[1].text == "No newline at end of file")
        #expect(h.lines[2].newNumber == 1)
    }

    @Test func pathWithSpaces() {
        let d = """
        diff --git a/my dir/my file.txt b/my dir/my file.txt
        index 1..2 100644
        --- a/my dir/my file.txt\t
        +++ b/my dir/my file.txt\t
        @@ -1 +1 @@
        -a
        +b

        """
        let f = DiffParser.parse(d).files[0]
        #expect(f.oldPath == "my dir/my file.txt" && f.newPath == "my dir/my file.txt")
    }

    @Test func spacesOnlyInHeaderBinary() {
        let d = """
        diff --git a/my dir/x y.bin b/my dir/x y.bin
        Binary files a/my dir/x y.bin and b/my dir/x y.bin differ

        """
        #expect(DiffParser.parse(d).files[0].path == "my dir/x y.bin")
    }

    @Test func cyrillicQuotedPath() {
        // core.quotePath: "док/файл.txt" → восьмеричные эскейпы UTF-8
        let q = "\"\\320\\264\\320\\276\\320\\272/\\321\\204.txt\""
        let d = """
        diff --git a/док/ф.txt b/док/ф.txt
        --- a/док/ф.txt
        +++ b/док/ф.txt
        @@ -1 +1 @@
        -a
        +b
        diff --git \"a/\\320\\264\\320\\276\\320\\272/\\321\\204.txt\" \"b/\\320\\264\\320\\276\\320\\272/\\321\\204.txt\"
        Binary files \"a/\\320\\264\\320\\276\\320\\272/\\321\\204.txt\" and \"b/\\320\\264\\320\\276\\320\\272/\\321\\204.txt\" differ

        """
        _ = q
        let r = DiffParser.parse(d)
        #expect(r.files[0].path == "док/ф.txt")
        #expect(r.files[1].path == "док/ф.txt")
        #expect(r.files[1].oldPath == "док/ф.txt")
    }

    @Test func quotedPathWithQuoteAndRename() {
        let d = """
        diff --git "a/we\\"ird name.txt" "b/new \\"x\\".txt"
        similarity index 100%
        rename from "we\\"ird name.txt"
        rename to "new \\"x\\".txt"

        """
        let f = DiffParser.parse(d).files[0]
        #expect(f.oldPath == "we\"ird name.txt")
        #expect(f.newPath == "new \"x\".txt")
    }

    @Test func quotedPathInHeaderOnly() {
        let d = "diff --git \"a/t\\tab.txt\" \"b/t\\tab.txt\"\nBinary files differ\n"
        #expect(DiffParser.parse(d).files[0].path == "t\tab.txt")
    }

    @Test func contentLookingLikeHeadersIsNotMisparsed() {
        let d = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +1,2 @@
        --- x
        +++ y
        -diff --git a/zzz b/zzz
        +@@ -1 +1 @@

        """
        let r = DiffParser.parse(d)
        #expect(r.files.count == 1)
        #expect(r.files[0].hunks.count == 1)
        #expect(r.files[0].hunks[0].lines.count == 4)
        #expect(r.files[0].additions == 2 && r.files[0].deletions == 2)
    }

    @Test func crlfContent() {
        let d = "diff --git a/w.txt b/w.txt\n--- a/w.txt\n+++ b/w.txt\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+c\r\n"
        let h = DiffParser.parse(d).files[0].hunks[0]
        #expect(h.lines.map(\.kind) == [.context, .removed, .added])
        #expect(h.lines[1].text == "b\r" && h.lines[2].newNumber == 2)
    }

    @Test func pathContainingSpaceB() {
        let d = "diff --git a/x b/y b/x b/y\nBinary files differ\n"
        #expect(DiffParser.parse(d).files[0].path == "x b/y")
    }

    @Test func emptyAndGarbageInput() {
        #expect(DiffParser.parse("").files.isEmpty)
        #expect(DiffParser.parse("hello\nworld\n").files.isEmpty)
    }

    @Test func multipleHunks() {
        let d = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +1,2 @@
         a
        -b
        +B
        @@ -10 +10,2 @@ ctx
         x
        +y

        """
        let h = DiffParser.parse(d).files[0].hunks
        #expect(h.count == 2)
        #expect(h[1].oldStart == 10 && h[1].lines[1].newNumber == 11)
    }

    @Test func perFileLimitTruncates() {
        var d = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -0,0 +1,100 @@\n"
        for i in 0..<100 { d += "+l\(i)\n" }
        let r = DiffParser.parse(d, limits: .init(maxLinesPerFile: 10))
        #expect(r.truncated)
        #expect(r.files[0].truncated)
        #expect(r.files[0].hunks[0].lines.count == 10)
        #expect(r.files[0].additions == 100)
    }

    @Test func fileCountLimit() {
        var d = ""
        for i in 0..<5 { d += "diff --git a/f\(i) b/f\(i)\nBinary files differ\n" }
        let r = DiffParser.parse(d, limits: .init(maxFiles: 3))
        #expect(r.files.count == 3 && r.skippedFiles == 2 && r.truncated)
    }

    @Test func totalLimitStopsKeepingHunks() {
        var d = ""
        for i in 0..<3 {
            d += "diff --git a/f\(i) b/f\(i)\n--- a/f\(i)\n+++ b/f\(i)\n@@ -0,0 +1,10 @@\n"
            for j in 0..<10 { d += "+\(j)\n" }
        }
        let r = DiffParser.parse(d, limits: .init(maxTotalLines: 15))
        #expect(r.files.count == 3 && r.truncated)
        #expect(r.files.map { $0.hunks.reduce(0) { $0 + $1.lines.count } } == [10, 5, 0])
    }

    @Test func tenThousandLinesIsFast() {
        var d = "diff --git a/big.txt b/big.txt\n--- a/big.txt\n+++ b/big.txt\n@@ -1,5000 +1,5000 @@\n"
        for i in 0..<5000 { d += "-old line number \(i) with some text\n" }
        d.removeLast(0)
        // 5000 удалённых + 5000 добавленных в одном куске
        d = "diff --git a/big.txt b/big.txt\n--- a/big.txt\n+++ b/big.txt\n@@ -1,5000 +1,5000 @@\n"
        for i in 0..<5000 { d += "-old line number \(i) with some text\n" }
        for i in 0..<5000 { d += "+new line number \(i) with some text\n" }
        let start = ContinuousClock.now
        let r = DiffParser.parse(d, limits: .unlimited)
        let elapsed = ContinuousClock.now - start
        #expect(r.files[0].hunks[0].lines.count == 10_000)
        #expect(elapsed < .milliseconds(200))
    }
}
