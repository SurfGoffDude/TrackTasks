import Foundation
import Testing
@testable import TrackTasksCore

/// Временный репозиторий: main + worktree на ветке tracktasks/job.
@Suite("Checkpoints")
struct CheckpointTests {
    static func run(_ args: [String], _ dir: URL, _ env: [String: String], _ input: Data?) -> Checkpoints.Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
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
        let root: URL, main: URL, wt: URL
        let site: Checkpoints.Site
        init(_ base: [String: String]) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ckpt-\(UUID().uuidString)")
            main = root.appendingPathComponent("main")
            wt = root.appendingPathComponent("wt")
            site = .init(folder: wt, branch: "tracktasks/job", links: ["node_modules"])
            try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
            try git(main, "init", "-q", "-b", "main")
            for (n, s) in base { try put(n, s, main) }
            try git(main, "add", "-A")
            try git(main, "commit", "-q", "-m", "base")
            try git(main, "worktree", "add", "-q", "-b", "tracktasks/job", wt.path)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult func git(_ d: URL, _ a: String...) throws -> String {
            let o = CheckpointTests.run(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + a, d, [:], nil)
            #expect(o.ok, "\(a): \(o.err)")
            return o.text
        }
        func put(_ n: String, _ s: String, _ dir: URL? = nil) throws {
            let u = (dir ?? wt).appendingPathComponent(n)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(s.utf8).write(to: u)
        }
        func rm(_ n: String) throws { try FileManager.default.removeItem(at: wt.appendingPathComponent(n)) }
        func read(_ n: String) -> String? { try? String(contentsOf: wt.appendingPathComponent(n), encoding: .utf8) }
        func commit() throws { try git(wt, "add", "-A"); try git(wt, "commit", "-q", "-m", "job") }
        func snap(_ label: String = "ход") throws -> Checkpoints.Checkpoint {
            try Checkpoints.create(site, .init(kind: .turn, label: label), git: CheckpointTests.run)
        }
        @discardableResult func restore(_ c: Checkpoints.Checkpoint) throws -> Checkpoints.Restored {
            try Checkpoints.restore(site, to: c, before: .init(kind: .rollback, label: "до"), git: CheckpointTests.run)
        }
        func list() throws -> [Checkpoints.Checkpoint] {
            try Checkpoints.list(branch: site.branch, in: main, git: CheckpointTests.run)
        }
        /// Ветки, HEAD и индекс worktree, вся основная папка.
        func fixed() throws -> [String] {
            let index = try git(wt, "rev-parse", "--path-format=absolute", "--git-path", "index").trimmingCharacters(in: .newlines)
            return [try git(wt, "symbolic-ref", "HEAD"), try git(wt, "rev-parse", "HEAD"), try git(main, "rev-parse", "HEAD"),
                    try git(main, "for-each-ref", "refs/heads"), try git(main, "status", "--porcelain", "-uall"),
                    try git(wt, "reflog"), try Data(contentsOf: URL(fileURLWithPath: index)).base64EncodedString()]
        }
        /// Все файлы worktree с содержимым.
        func files() throws -> [String: String] {
            var out: [String: String] = [:]
            for p in try FileManager.default.subpathsOfDirectory(atPath: wt.path) where p != ".git" {
                if let s = read(p) { out[p] = s }
            }
            return out
        }
    }

    @Test func restoresChangedNewAndDeletedAndBack() throws {
        let r = try Repo(["a.txt": "a\n", "dir/del.txt": "d\n", "keep.txt": "k\n"])
        try r.put("untracked.txt", "u\n")
        let c = try r.snap()
        let old = try r.files()
        try r.put("a.txt", "A\n")
        try r.put("new/deep/файл \"x\".txt", "n\n")
        try r.put("untracked.txt", "U\n")
        try r.rm("dir/del.txt")
        let new = try r.files(), fixed = try r.fixed()

        let back = try r.restore(c)
        #expect(try r.files() == old)
        #expect(!FileManager.default.fileExists(atPath: r.wt.appendingPathComponent("new").path))
        #expect(try r.fixed() == fixed)
        #expect(back.before.meta.kind == .rollback)

        try r.restore(back.before)
        #expect(try r.files() == new)
        #expect(try r.fixed() == fixed)
        #expect(try r.list().map(\.number) == [1, 2, 3])
    }

    /// Ход закоммичен трекером: ветка остаётся на коммите, откат виден как незакоммиченное.
    @Test func committedTurn() throws {
        let r = try Repo(["a.txt": "a\n", "del.txt": "d\n"])
        let c = try r.snap()
        let old = try r.files()
        try r.put("a.txt", "A\n")
        try r.put("new.txt", "n\n")
        try r.rm("del.txt")
        try r.commit()
        let fixed = try r.fixed()
        let back = try r.restore(c)
        #expect(!back.matchesHead)
        #expect(try r.files() == old)
        #expect(try r.fixed() == fixed)
        #expect(try r.restore(back.before).matchesHead)
        #expect(try r.fixed() == fixed)
        #expect(try r.git(r.wt, "status", "--porcelain").isEmpty)
    }

    @Test func snapshotLeavesEverything() throws {
        let r = try Repo(["a.txt": "a\n"])
        try r.put("staged.txt", "s\n")
        try r.git(r.wt, "add", "staged.txt")
        try r.put("a.txt", "A\n")
        let fixed = try r.fixed(), files = try r.files(), st = try r.git(r.wt, "status", "--porcelain")
        let c = try r.snap()
        #expect(try r.git(r.wt, "status", "--porcelain") == st)
        #expect(try r.files() == files)
        #expect(try r.git(r.main, "show", "\(c.oid):a.txt") == "A\n")
        #expect(try r.fixed()[0..<6] == fixed[0..<6])
    }

    /// Правка той же длины сразу после записи индекса: «racy git».
    @Test func sameSizeEdit() throws {
        for i in 0..<5 {
            let r = try Repo(["a.txt": "aaaa"])
            try r.put("a.txt", "bbb\(i)")
            let c = try r.snap()
            try r.put("a.txt", "ccc\(i)")
            let back = try r.restore(c)
            #expect(r.read("a.txt") == "bbb\(i)")
            #expect(try r.git(r.main, "show", "\(back.before.oid):a.txt") == "ccc\(i)")
        }
    }

    @Test func modesLinksAndBinary() throws {
        let r = try Repo(["run.sh": "x\n"])
        let bin = Data([0, 255, 13, 10, 0, 1])
        try bin.write(to: r.wt.appendingPathComponent("b.bin"))
        let fm = FileManager.default
        let link = r.wt.appendingPathComponent("link").path, sh = r.wt.appendingPathComponent("run.sh").path
        try fm.createSymbolicLink(atPath: link, withDestinationPath: "run.sh")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh)
        let c = try r.snap()
        try r.rm("link")
        try r.put("link", "file")
        try r.put("b.bin", "text")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sh)
        try r.restore(c)
        #expect(try fm.destinationOfSymbolicLink(atPath: link) == "run.sh")
        #expect(try Data(contentsOf: r.wt.appendingPathComponent("b.bin")) == bin)
        #expect(fm.isExecutableFile(atPath: sh))
    }

    @Test func fileBecomesFolderAndCaseRename() throws {
        let r = try Repo(["x": "file\n", "Readme.md": "r\n"])
        let c = try r.snap()
        try r.rm("x")
        try r.put("x/inner.txt", "i\n")
        try r.git(r.wt, "mv", "Readme.md", "README.md")
        let back = try r.restore(c)
        #expect(r.read("x") == "file\n")
        #expect(r.read("Readme.md") == "r\n")
        try r.restore(back.before)
        #expect(r.read("x/inner.txt") == "i\n")
        #expect(r.read("README.md") == "r\n")
    }

    @Test func ignoredFilesStay() throws {
        let r = try Repo([".gitignore": "build/\n.env\n", "a.txt": "a\n"])
        try r.put("build/out.o", "1")
        try r.put(".env", "SECRET")
        let c = try r.snap()
        #expect(try !r.git(r.main, "ls-tree", "-r", "--name-only", c.oid).contains(".env"))
        // Агент снял игнорирование: файлы лежали и до хода — откат их не удаляет.
        try r.put(".gitignore", "\n")
        try r.put("build/out.o", "2")
        try r.put("a.txt", "A\n")
        try r.restore(c)
        #expect(r.read(".gitignore") == "build/\n.env\n")
        #expect(r.read(".env") == "SECRET")
        #expect(r.read("build/out.o") == "2")
        #expect(r.read("a.txt") == "a\n")
    }

    /// Файл стал игнорироваться после снимка: откат вернёт его, но нынешнее содержимое не потеряется.
    @Test func newlyIgnoredIsSavedFirst() throws {
        let r = try Repo(["a.txt": "a\n"])
        try r.put("data.log", "old")
        let c = try r.snap()
        try r.put(".gitignore", "*.log\n")
        try r.put("data.log", "new")
        let back = try r.restore(c)
        #expect(r.read("data.log") == "old")
        #expect(r.read(".gitignore") == nil)
        try r.restore(back.before)
        #expect(r.read("data.log") == "new")
        #expect(r.read(".gitignore") == "*.log\n")
    }

    @Test func ignoredFolderInTheWayStopsRollback() throws {
        let r = try Repo(["a.txt": "a\n"])
        try r.put("x", "file")
        let c = try r.snap()
        try r.rm("x")
        try r.put(".gitignore", "x/\n")
        try r.put("x/cache", "c")
        let files = try r.files()
        #expect(throws: Checkpoints.Failure.self) { try r.restore(c) }
        #expect(try r.files() == files)
    }

    @Test func linksAndNestedReposAreNotTouched() throws {
        let r = try Repo(["a.txt": "a\n"])
        let fm = FileManager.default
        try r.put("dep.js", "d", r.root.appendingPathComponent("deps"))
        let link = r.wt.appendingPathComponent("node_modules").path
        try fm.createSymbolicLink(atPath: link, withDestinationPath: r.root.appendingPathComponent("deps").path)
        let c = try r.snap()
        #expect(try r.git(r.main, "ls-tree", "-r", "--name-only", c.oid) == "a.txt\n")
        // Пустой вложенный репозиторий обычный `git add` не принял бы.
        try r.put("nested/f.txt", "n\n")
        try r.git(r.wt.appendingPathComponent("nested"), "init", "-q")
        try r.put("a.txt", "A\n")
        try r.restore(c)
        #expect(r.read("a.txt") == "a\n")
        #expect(r.read("nested/f.txt") == "n\n")
        #expect(fm.fileExists(atPath: link + "/dep.js"))
    }

    @Test func mainFolderAndWrongBranchAreRefused() throws {
        let r = try Repo(["a.txt": "a\n"])
        let c = try r.snap()
        try r.put("a.txt", "MAIN\n", r.main)
        let main = Checkpoints.Site(folder: r.main, branch: "main")
        #expect(throws: Checkpoints.Failure.self) { try Checkpoints.create(main, .init(kind: .turn, label: ""), git: Self.run) }
        #expect(throws: Checkpoints.Failure.self) {
            try Checkpoints.restore(main, to: c, before: .init(kind: .rollback, label: ""), git: Self.run)
        }
        #expect(try String(contentsOf: r.main.appendingPathComponent("a.txt"), encoding: .utf8) == "MAIN\n")
        try r.git(r.wt, "checkout", "-q", "-b", "other")
        #expect(throws: Checkpoints.Failure.self) { try r.snap() }
    }

    @Test func unfinishedMergeIsRefused() throws {
        let r = try Repo(["a.txt": "a\n"])
        let c = try r.snap()
        try r.put("a.txt", "A\n")
        try r.commit()
        try r.git(r.main, "commit", "-q", "--allow-empty", "-m", "m")
        try r.put("a.txt", "M\n", r.main)
        try r.git(r.main, "commit", "-qam", "m2")
        #expect(!Self.run(["-c", "user.name=t", "-c", "user.email=t@t", "merge", "main"], r.wt, [:], nil).ok)
        let files = try r.files()
        _ = try r.snap("конфликт")
        #expect(throws: Checkpoints.Failure.self) { try r.restore(c) }
        #expect(try r.files() == files)
    }

    @Test func diffBetweenTurnsAndNow() throws {
        let r = try Repo(["a.txt": "a\n"])
        let c1 = try r.snap("1")
        try r.put("one.txt", "1\n")
        let c2 = try r.snap("2")
        try r.put("two.txt", "2\n")
        func files(_ from: String, _ to: String) -> [String] {
            let s = DiffSource(title: "", folder: r.wt, span: .init(from: from, to: to, title: ""))
            let secs = DiffCollector.collect(s, git: { a, d in
                let o = Self.run(a, d, [:], nil)
                return .init(ok: o.ok, out: o.text, err: o.err)
            })
            #expect(secs.count == 1)
            return secs[0].entries.map(\.file.path)
        }
        let now = try Checkpoints.currentTree(r.site, git: Self.run)
        #expect(files(c1.oid, c2.oid) == ["one.txt"])
        #expect(files(c2.oid, now) == ["two.txt"])
        #expect(files(c1.oid, now) == ["one.txt", "two.txt"])
        // Сравнение снимков не оставляет.
        #expect(try r.list().count == 2)
    }

    @Test func listKeepsMetaAndRemoveAllIsPerBranch() throws {
        let r = try Repo(["a.txt": "a\n"])
        let meta = Checkpoints.Meta(kind: .turn, label: "Ответ: «ё»\n\u{1}{", date: Date(timeIntervalSince1970: 1000), session: "s", point: "p")
        try Checkpoints.create(r.site, meta, git: Self.run)
        #expect(try r.list().map(\.meta) == [meta])
        let other = r.root.appendingPathComponent("wt2")
        try r.git(r.main, "worktree", "add", "-q", "-b", "tracktasks/job-2", other.path)
        let s2 = Checkpoints.Site(folder: other, branch: "tracktasks/job-2")
        try Checkpoints.create(s2, .init(kind: .turn, label: "2"), git: Self.run)
        #expect(try r.list().count == 1)
        Checkpoints.removeAll(branch: "", in: r.main, git: Self.run)
        Checkpoints.removeAll(branch: "tracktasks", in: r.main, git: Self.run)
        #expect(try r.list().count == 1)
        Checkpoints.removeAll(branch: r.site.branch, in: r.main, git: Self.run)
        #expect(try r.list().isEmpty)
        #expect(try Checkpoints.list(branch: s2.branch, in: r.main, git: Self.run).count == 1)
    }

    @Test func rewindPoint() throws {
        #expect(Checkpoints.Meta(kind: .turn, label: "").canRewind)
        #expect(!Checkpoints.Meta(kind: .turn, label: "", session: "s").canRewind)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ckpt-s-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("-p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
        {"type":"user","uuid":"u1","isSidechain":false}
        {"isSidechain":false,"type":"assistant","uuid":"a1","message":{}}
        {"isSidechain":true,"type":"assistant","uuid":"sub","message":{}}
        {"type":"user","uuid":"u2","isSidechain":false,"t":"\\"type\\":\\"assistant\\",\\"uuid\\":\\"x\\""}
        """.utf8).write(to: dir.appendingPathComponent("s.jsonl"))
        let path = try #require(SessionLog.file(session: "s", in: root))
        #expect(SessionLog.lastAssistant(path: path) == "a1")
        #expect(SessionLog.file(session: "none", in: root) == nil)
        #expect(ClaudeArgs.resume("s", fork: true, at: "a1") == ["--resume", "s", "--fork-session", "--resume-session-at", "a1"])
    }
}
