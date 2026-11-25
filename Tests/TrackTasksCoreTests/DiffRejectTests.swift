import Foundation
import Testing
@testable import TrackTasksCore

/// Временный репозиторий: main + worktree на ветке job.
@Suite("DiffReject")
struct DiffRejectTests {
    static func run(_ args: [String], _ dir: URL, _ input: Data?) -> DiffReject.Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch { return .init(status: -1, out: Data()) }
        if let input { inp.fileHandleForWriting.write(input); try? inp.fileHandleForWriting.close() }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return .init(status: p.terminationStatus, out: d, err: String(decoding: e, as: UTF8.self))
    }

    final class Repo {
        let main: URL, wt: URL
        var src: DiffSource
        init(_ base: [String: Data]) throws {
            main = FileManager.default.temporaryDirectory.appendingPathComponent("reject-\(UUID().uuidString)")
            wt = main.appendingPathExtension("wt")
            src = DiffSource(title: "", folder: wt)
            try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
            try git(main, "init", "-q", "-b", "main")
            for (n, d) in base { try write(d, n, main) }
            try git(main, "add", "-A")
            try git(main, "commit", "-q", "-m", "base")
            let b = try git(main, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
            try git(main, "worktree", "add", "-q", "-b", "job", wt.path, b)
            src = DiffSource(title: "", folder: wt, branch: .init(main: main, base: b, name: "job"))
        }
        deinit { for u in [main, wt] { try? FileManager.default.removeItem(at: u) } }

        @discardableResult func git(_ d: URL, _ a: String...) throws -> String {
            let o = DiffRejectTests.run(a, d, nil)
            #expect(o.ok, "\(a): \(o.err)")
            return o.text
        }
        func write(_ d: Data, _ n: String, _ dir: URL) throws {
            let u = dir.appendingPathComponent(n)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: u)
        }
        func put(_ n: String, _ s: String) throws { try write(Data(s.utf8), n, wt) }
        func read(_ n: String) -> Data? { try? Data(contentsOf: wt.appendingPathComponent(n)) }
        func commit() throws { try git(wt, "add", "-A"); try git(wt, "commit", "-q", "-m", "job") }
        func entries(_ k: DiffSection.Kind) -> [DiffSection.Entry] {
            DiffCollector.collect(src, git: { a, d in
                let o = DiffRejectTests.run(a, d, nil)
                return .init(ok: o.ok, out: o.text, err: o.err)
            }).first { $0.kind == k }!.entries
        }
        func entry(_ k: DiffSection.Kind, _ path: String) throws -> DiffSection.Entry {
            try #require(entries(k).first { $0.file.path == path })
        }
        func reject(_ k: DiffSection.Kind, _ e: DiffSection.Entry, _ hunk: Int? = nil) throws {
            try DiffReject.reject(src, k, e, hunk: hunk, git: DiffRejectTests.run)
        }
        func undo() throws { try DiffReject.undoLast(src, git: DiffRejectTests.run) }
        /// Всё, что не должно меняться при ошибке.
        func snapshot(_ files: String...) throws -> [String] {
            [try git(wt, "rev-parse", "HEAD"), try git(wt, "status", "--porcelain", "-uall"), try git(wt, "diff", "HEAD"),
             try mainState()] + files.map { read($0)?.base64EncodedString() ?? "-" }
        }
        func mainState() throws -> String {
            try git(main, "rev-parse", "HEAD") + git(main, "status", "--porcelain", "-uall") + git(main, "branch", "--show-current")
        }
    }

    func lines(_ r: ClosedRange<Int>, _ change: [Int: String] = [:]) -> String {
        r.map { (change[$0] ?? "l\($0)") + "\n" }.joined()
    }
    /// Тела кусков: номера строк соседних кусков после отклонения сдвигаются.
    func bodies(_ f: DiffFile) -> [[String]] { f.hunks.map { $0.lines.map { "\($0.kind)" + $0.text } } }

    @Test(arguments: [DiffSection.Kind.branch, .working])
    func onlyChosenHunk(kind: DiffSection.Kind) throws {
        let r = try Repo(["a.txt": Data(lines(1...60).utf8), "b.txt": Data("b\n".utf8)])
        try r.put("a.txt", lines(1...60, [5: "A\nA2\nA3", 30: "B", 55: "C"]))
        try r.put("b.txt", "B\n")
        if kind == .branch { try r.commit() }
        let main = try r.mainState(), before = r.entries(kind)
        let e = try r.entry(kind, "a.txt")
        #expect(e.file.hunks.count == 3)

        try r.reject(kind, e, 1)
        #expect(r.read("a.txt") == Data(lines(1...60, [5: "A\nA2\nA3", 55: "C"]).utf8))
        let after = try r.entry(kind, "a.txt")
        #expect(bodies(after.file) == [bodies(e.file)[0], bodies(e.file)[2]])
        #expect(try r.entry(kind, "b.txt").file == before.first { $0.file.path == "b.txt" }!.file)
        #expect(try r.git(r.wt, "status", "--porcelain").isEmpty == (kind == .branch))
        #expect(try r.mainState() == main)

        #expect(DiffReject.last(r.src, git: Self.run)?.label == "a.txt · кусок 2")
        try r.undo()
        #expect(r.entries(kind).map(\.fingerprint) == before.map(\.fingerprint))
        #expect(DiffReject.last(r.src, git: Self.run) == nil)
        #expect(throws: DiffReject.Failure.self) { try r.undo() }
        #expect(try r.mainState() == main)
    }

    /// Одинаковые блоки: сдвиг от первого куска не должен увести патч в соседний блок.
    @Test func repeatedBlocks() throws {
        let block = "{\n x\n x\n x\n old\n x\n x\n x\n}\n"
        let base = String(repeating: block, count: 8)
        let r = try Repo(["a.txt": Data(base.utf8)])
        let new = block.replacingOccurrences(of: "old", with: "new")
        let head = "{\n" + (1...9).map { "i\($0)\n" }.joined() // ровно один блок: сдвиг 9 строк
        func text(_ blocks: [String]) -> String { head + blocks.joined().dropFirst(2) }
        try r.put("a.txt", text(Array(repeating: new, count: 8)))
        try r.commit()
        let e = try r.entry(.branch, "a.txt")
        let target = try #require(e.file.hunks.indices.first { i in
            i > 1 && e.file.hunks[i].lines.filter { $0.kind != .context }.count == 2 })
        let row = try #require(e.file.hunks[target].lines.first { $0.kind == .added }?.newNumber)
        try r.reject(.branch, e, target)
        var want = text(Array(repeating: new, count: 8)).components(separatedBy: "\n")
        want[row - 1] = " old"
        #expect(r.read("a.txt") == Data(want.joined(separator: "\n").utf8))
        try r.undo()
        #expect(r.read("a.txt") == Data(text(Array(repeating: new, count: 8)).utf8))
    }

    @Test func pureInsertAndDelete() throws {
        let r = try Repo(["a.txt": Data(lines(1...40).utf8)])
        try r.put("a.txt", "top\n" + lines(1...19) + lines(21...40) + "end")
        try r.commit()
        for (i, want) in [(0, lines(1...19) + lines(21...40) + "end"), (1, "top\n" + lines(1...40) + "end"),
                          (2, "top\n" + lines(1...19) + lines(21...40))] {
            try r.reject(.branch, r.entry(.branch, "a.txt"), i)
            #expect(r.read("a.txt") == Data(want.utf8))
            try r.undo()
        }
    }

    @Test(arguments: [DiffSection.Kind.branch, .working])
    func wholeFiles(kind: DiffSection.Kind) throws {
        let bin = Data([0, 1, 2, 255, 0]), cp = Data([0xCF, 0xF0, 0x0D, 0x0A, 0xE8, 0x0A])
        let r = try Repo(["gone.txt": Data("x\n".utf8), "img.bin": bin, "cp.txt": cp, "run.sh": Data("e\n".utf8),
                          "old имя.txt": Data(lines(1...30).utf8)])
        try FileManager.default.removeItem(at: r.wt.appendingPathComponent("gone.txt"))
        try r.write(Data([0, 9, 9]), "img.bin", r.wt)
        try r.write(cp + Data([0xFF, 0x0A]), "cp.txt", r.wt)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: r.wt.appendingPathComponent("run.sh").path)
        try r.put("папка/new \"q\".txt", "n")
        try r.put("empty.txt", "")
        try r.git(r.wt, "mv", "old имя.txt", "новое имя.txt")
        try r.put("новое имя.txt", lines(1...30, [15: "X"]))
        try r.git(r.wt, "add", "-A")
        if kind == .branch { try r.commit() }
        let main = try r.mainState()
        let all = r.entries(kind).map(\.file.path).sorted()
        #expect(all.count == 7)
        for path in all {
            try r.reject(kind, r.entry(kind, path))
            #expect(r.entries(kind).map(\.file.path).sorted() == all.filter { $0 != path }, "\(path)")
            try r.undo()
            if kind == .branch { #expect(r.entries(kind).map(\.file.path).sorted() == all, "\(path)") }
            else {
                try r.git(r.wt, "add", "-A") // после отмены git add / git mv не восстанавливаются, содержимое — да
                #expect(r.entries(kind).map(\.file.path).sorted() == all, "\(path)")
            }
        }
        // Кусок переименованного файла не отменяет переименование.
        try r.reject(kind, r.entry(kind, "новое имя.txt"), 0)
        #expect(try r.entry(kind, "новое имя.txt").file.status == .renamed)
        #expect(r.read("новое имя.txt") == Data(lines(1...30).utf8))
        #expect(try r.mainState() == main)
    }

    @Test func untracked() throws {
        let r = try Repo(["a": Data("a\n".utf8)])
        try r.put("dir/новый.txt", "x\ny")
        try r.put("-dash", "d\n")
        try r.put("empty", "")
        for p in ["dir/новый.txt", "-dash", "empty"] {
            let e = try r.entry(.working, p), data = r.read(p)
            #expect(e.untracked)
            try r.reject(.working, e, 0)
            #expect(r.read(p) == nil)
            try r.undo()
            #expect(r.read(p) == data)
        }
        // Чужой файл в индексе не попадает в коммит отклонения.
        try r.put("a", "A\n")
        try r.git(r.wt, "commit", "-q", "-am", "job")
        try r.git(r.wt, "add", "empty")
        try r.reject(.branch, r.entry(.branch, "a"), 0)
        #expect(try r.git(r.wt, "status", "--porcelain").contains("A  empty"))
    }

    @Test func failuresChangeNothing() throws {
        let r = try Repo(["a.txt": Data(lines(1...40).utf8)])
        try r.put("a.txt", lines(1...40, [5: "A", 30: "B"]))
        try r.commit()
        let e = try r.entry(.branch, "a.txt")
        try r.reject(.branch, e, 0)
        func fails(_ text: String, _ body: () throws -> Void) throws {
            let before = try r.snapshot("a.txt"), undo = DiffReject.last(r.src, git: Self.run)?.patch
            let err = #expect(throws: DiffReject.Failure.self) { try body() }
            #expect(err?.message.contains(text) == true, "\(err?.message ?? "")")
            #expect(try r.snapshot("a.txt") == before)
            #expect(DiffReject.last(r.src, git: Self.run)?.patch == undo)
        }
        // Показанное устарело.
        try fails("изменился") { try r.reject(.branch, e, 1) }
        // Патч не подходит к worktree (файл поменялся между diff и применением).
        let fresh = try r.entry(.branch, "a.txt")
        try fails("не применяется") {
            try DiffReject.reject(r.src, .branch, fresh, hunk: 0) { a, d, i in
                a.first == "apply" ? Self.run(a, d, i.map { Data(String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "+B", with: "+Z").utf8) }) : Self.run(a, d, i)
            }
        }
        // Коммит не удался — правка возвращена.
        try fails("закоммитить") {
            try DiffReject.reject(r.src, .branch, fresh, hunk: 0) { a, d, i in
                a.contains("commit") ? .init(status: 1, out: Data(), err: "нет") : Self.run(a, d, i)
            }
        }
        try fails("закоммитить") {
            try DiffReject.undoLast(r.src) { a, d, i in
                a.contains("commit") ? .init(status: 1, out: Data(), err: "нет") : Self.run(a, d, i)
            }
        }
        // Незакоммиченное в том же файле.
        try r.put("a.txt", lines(1...40, [20: "dirty", 30: "B"]))
        try fails("незакоммиченные") { try r.reject(.branch, fresh, 0) }
        try fails("изменился после") { try r.undo() }
        // Основная папка.
        try fails("worktree") {
            try DiffReject.reject(DiffSource(title: "", folder: r.main), .working, fresh, git: Self.run)
        }
        var other = r.src
        other.branch?.name = "other"
        try fails("other") { try DiffReject.reject(other, .branch, fresh, git: Self.run) }
    }
}
