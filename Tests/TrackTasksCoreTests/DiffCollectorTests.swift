import Foundation
import Testing
@testable import TrackTasksCore

@Suite("DiffCollector")
struct DiffCollectorTests {
    static func git(_ args: [String], _ dir: URL) -> DiffCollector.Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .init(ok: false, out: "") }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return .init(ok: p.terminationStatus == 0, out: String(decoding: d, as: UTF8.self))
    }

    func repo() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        #expect(Self.git(["init", "-q", "-b", "main"], u).ok)
        return u
    }
    func write(_ s: String, _ name: String, _ dir: URL) throws {
        let u = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: u)
    }
    func commit(_ dir: URL) { _ = Self.git(["add", "-A"], dir); #expect(Self.git(["commit", "-q", "-m", "x"], dir).ok) }

    /// «+ − путь», как в `git diff --numstat`.
    func stat(_ e: [DiffSection.Entry]) -> [String] {
        e.map { "\($0.file.additions)\t\($0.file.deletions)\t\($0.file.path)" }.sorted()
    }
    func numstat(_ args: [String], _ dir: URL) -> [String] {
        Self.git(["diff", "--numstat"] + args, dir).out.split(separator: "\n").map(String.init).sorted()
    }

    @Test func mainFolderMatchesGit() throws {
        let d = try repo()
        defer { try? FileManager.default.removeItem(at: d) }
        // Настройка пользователя не должна ломать разбор.
        _ = Self.git(["config", "diff.noprefix", "true"], d)
        _ = Self.git(["config", "color.ui", "always"], d)
        try write("a\nb\nc\n", "a.txt", d)
        try write("x\n", "gone.txt", d)
        commit(d)
        try write("a\nB\nc\nd", "a.txt", d)
        try FileManager.default.removeItem(at: d.appendingPathComponent("gone.txt"))
        try write("staged\n", "staged.txt", d)
        _ = Self.git(["add", "staged.txt"], d)
        try write("один\nдва", "новая папка/файл.txt", d)
        try write("", "empty.txt", d)
        try write("ignored", "skip.log", d)
        try write("*.log\n", ".gitignore", d)

        let s = DiffCollector.collect(DiffSource(title: "", folder: d), git: Self.git)
        #expect(s.count == 1 && s[0].error == nil)
        #expect(stat(s[0].entries.filter { !$0.untracked }) == numstat(["HEAD"], d))
        let new = s[0].entries.filter(\.untracked).map(\.file)
        #expect(Set(new.map(\.path)) == [".gitignore", "empty.txt", "новая папка/файл.txt"])

        // Неотслеживаемый файл — так же, как его показывает git.
        for f in new where !f.hunks.isEmpty {
            let o = Self.git(["diff", "--no-index", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--", "/dev/null", f.path], d)
            let g = DiffParser.parse(o.out).files[0]
            #expect(g.hunks == f.hunks && g.additions == f.additions && g.newMode == f.newMode && g.path == f.path)
        }
    }

    @Test func worktreeMatchesGit() throws {
        let d = try repo()
        let w = d.appendingPathExtension("wt")
        defer { for u in [d, w] { try? FileManager.default.removeItem(at: u) } }
        try write("a\n", "a.txt", d)
        commit(d)
        let base = Self.git(["rev-parse", "HEAD"], d).out.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Self.git(["worktree", "add", "-q", "-b", "job", w.path, base], d).ok)
        try write("a\nb\n", "a.txt", w)
        commit(w)
        // main ушёл вперёд и грязный — в diff job этого быть не должно.
        try write("main\n", "main.txt", d)
        commit(d)
        try write("dirty\n", "a.txt", d)
        try write("a\nb\nc\n", "a.txt", w)
        try write("new\n", "new.txt", w)
        try FileManager.default.createSymbolicLink(at: w.appendingPathComponent("node_modules"), withDestinationURL: d)
        try FileManager.default.createSymbolicLink(at: w.appendingPathComponent("link"), withDestinationURL: d)

        for b in [base, ""] {
            let src = DiffSource(title: "", folder: w, branch: .init(main: d, base: b, name: "job"))
            let s = DiffCollector.collect(src, skipUntracked: ["node_modules"], git: Self.git)
            #expect(s.map(\.kind) == [.branch, .working])
            #expect(stat(s[0].entries) == numstat(["\(base)..job"], d))
            #expect(stat(s[1].entries.filter { !$0.untracked }) == numstat(["HEAD"], w))
            #expect(Set(s[1].entries.filter(\.untracked).map(\.file.path)) == ["new.txt", "link"])
            #expect(s[1].entries.first { $0.file.path == "link" }?.file.newMode == "120000")
        }
    }

    @Test func noCommitsAndNotARepo() throws {
        let d = try repo()
        defer { try? FileManager.default.removeItem(at: d) }
        try write("a\n", "a.txt", d)
        _ = Self.git(["add", "a.txt"], d)
        let s = DiffCollector.collect(DiffSource(title: "", folder: d), git: Self.git)
        #expect(s[0].error == nil && s[0].entries.map(\.file.path) == ["a.txt"])
        let missing = DiffCollector.collect(DiffSource(title: "", folder: d.appendingPathComponent("нет")), git: Self.git)
        #expect(missing[0].error != nil)
    }

    @Test func binaryUntracked() throws {
        let d = try repo()
        defer { try? FileManager.default.removeItem(at: d) }
        try Data([1, 0, 2]).write(to: d.appendingPathComponent("b.bin"))
        try Data([0x61, 0xFF, 0x0A]).write(to: d.appendingPathComponent("latin.txt"))
        let s = DiffCollector.collect(DiffSource(title: "", folder: d), git: Self.git)
        #expect(s[0].entries.first { $0.file.path == "b.bin" }?.file.isBinary == true)
        #expect(s[0].entries.first { $0.file.path == "latin.txt" }?.file.additions == 1)
    }

    @Test func fingerprintFollowsContent() {
        func f(_ t: String) -> DiffFile {
            var f = DiffFile(oldPath: "a", newPath: "a")
            f.hunks = [DiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 1, lines: [DiffLine(kind: .added, text: t)])]
            return f
        }
        #expect(DiffCollector.fingerprint(f("x")) == DiffCollector.fingerprint(f("x")))
        #expect(DiffCollector.fingerprint(f("x")) != DiffCollector.fingerprint(f("y")))
    }

    @Test func tenThousandLinesNotTruncated() throws {
        let body = (1...10_000).map { "+line \($0)" }.joined(separator: "\n")
        let text = "diff --git a/x b/x\nnew file mode 100644\nindex 0..1\n--- /dev/null\n+++ b/x\n@@ -0,0 +1,10000 @@\n\(body)\n"
        let s = DiffCollector.collect(DiffSource(title: "", folder: URL(fileURLWithPath: "/"))) { a, _ in
            .init(ok: true, out: a.contains("--no-color") ? text : "")
        }
        let f = try #require(s[0].entries.first?.file)
        #expect(!f.truncated && f.index == "0..1")
        #expect(DiffRows.unified(f).rows.count == 10_001)
        #expect(DiffRows.split(f).rows.count == 10_001)
    }
}

@Suite("DiffRows")
struct DiffRowsTests {
    func l(_ k: DiffLine.Kind, _ t: String) -> DiffLine { DiffLine(kind: k, text: t) }
    func split(_ lines: [DiffLine]) -> [DiffRow] {
        var f = DiffFile(newPath: "a")
        f.hunks = [DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: lines)]
        return Array(DiffRows.split(f).rows.dropFirst())
    }

    @Test func pairsReplacements() {
        let c = l(.context, "c"), r1 = l(.removed, "1"), r2 = l(.removed, "2"), a = l(.added, "3")
        #expect(split([c, r1, r2, a, c, a]) == [
            .pair(left: c, right: c), .pair(left: r1, right: a), .pair(left: r2, right: nil),
            .pair(left: c, right: c), .pair(left: nil, right: a),
        ])
    }

    @Test func noNewlineStaysOnItsSide() {
        let r = l(.removed, "1"), a = l(.added, "1"), n = l(.noNewline, "No newline")
        #expect(split([r, n, a]) == [.pair(left: r, right: a), .pair(left: n, right: nil)])
        #expect(split([r, a, n]) == [.pair(left: r, right: a), .pair(left: nil, right: n)])
    }

    @Test func longLinesAndCR() {
        #expect(split([l(.added, "x\r")]) == [.pair(left: nil, right: l(.added, "x"))])
        guard case .pair(_, let r?) = split([l(.added, String(repeating: "x", count: 5_000))])[0] else { Issue.record(); return }
        #expect(r.text.count == DiffRows.maxText + 1)
        #expect(DiffRows.width("\ta\t") == 8)
    }
}
