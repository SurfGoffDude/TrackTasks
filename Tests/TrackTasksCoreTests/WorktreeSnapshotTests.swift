import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct WorktreeSnapshotTests {
    typealias S = WorktreeSnapshot
    let git: S.Runner = CheckpointTests.run
    func repo(_ more: [String: String] = [:]) throws -> CheckpointTests.Repo {
        try .init(["a.txt": "a\n", "b.txt": "b\n", "run.sh": "#!/bin/sh\n", ".gitignore": "*.log\nnode_modules/\n"].merging(more) { $1 })
    }
    func remove(_ r: CheckpointTests.Repo) throws {
        try r.git(r.main, "worktree", "remove", "--force", r.wt.path)
        Checkpoints.removeAll(branch: r.site.branch, in: r.main, git: git)
        try r.git(r.main, "branch", "-D", r.site.branch)
        try r.git(r.main, "reflog", "expire", "--expire=now", "--all")
        try r.git(r.main, "gc", "-q", "--prune=now")
    }

    @Test func roundTrip() throws {
        let r = try repo()
        try r.put("c.txt", "коммит\n")
        try r.commit()
        // staged, then changed again
        try r.put("a.txt", "staged\n")
        try r.git(r.wt, "add", "a.txt")
        try r.put("a.txt", "рабочая\n")
        try r.rm("b.txt")
        try r.put("папка/новый файл.txt", "новый\n")
        try r.put("x.log", "log")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: r.wt.appendingPathComponent("run.sh").path)
        try FileManager.default.createSymbolicLink(atPath: r.wt.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        // The tracker's link: not ignored as a link, still not kept.
        try FileManager.default.createSymbolicLink(atPath: r.wt.appendingPathComponent("node_modules").path, withDestinationPath: "/tmp")
        try r.snap()
        #expect(try S.ignored(r.site, git: git) == ["x.log"])
        let un = try S.uncommitted(r.site, git: git)
        #expect(Set(un) == ["a.txt", "b.txt", "link", "run.sh", "папка/новый файл.txt"])
        let x = try S.create(r.site, id: "id", number: 1, git: git)
        #expect(try S.matches(r.site, x, git: git))
        let before = try r.git(r.wt, "status", "--porcelain").split(separator: "\n").filter { !$0.contains("node_modules") }
        try remove(r)
        #expect(try Checkpoints.list(branch: r.site.branch, in: r.main, git: git).isEmpty)

        let to = r.root.appendingPathComponent("back")
        try S.restore(x, main: r.main, to: to, branch: "back", git: git)
        func read(_ n: String) -> String? { try? String(contentsOf: to.appendingPathComponent(n), encoding: .utf8) }
        #expect(read("a.txt") == "рабочая\n" && read("b.txt") == nil && read("c.txt") == "коммит\n" && read("папка/новый файл.txt") == "новый\n")
        #expect(try r.git(to, "show", ":a.txt").contains("staged"))
        #expect(FileManager.default.isExecutableFile(atPath: to.appendingPathComponent("run.sh").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: to.appendingPathComponent("link").path) == "a.txt")
        #expect(!S.exists(to.appendingPathComponent("node_modules")) && !S.exists(to.appendingPathComponent("x.log")))
        #expect(try r.git(to, "status", "--porcelain").split(separator: "\n") == before)
        #expect(try r.git(to, "log", "-1", "--format=%s").hasPrefix("job"))
        try S.delete(x, in: r.main, git: git)
        #expect(!git(["rev-parse", "-q", "--verify", x.ref], r.main, [:], nil).ok)
        try S.delete(x, in: r.main, git: git)
    }

    @Test func overwritesNothing() throws {
        let r = try repo()
        let x = try S.create(r.site, id: "id", number: 1, git: git)
        let to = r.root.appendingPathComponent("busy")
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        try r.put("mine", "моё", to)
        #expect(throws: S.Failure.self) { try S.restore(x, main: r.main, to: to, branch: "free", git: git) }
        #expect(try String(contentsOf: to.appendingPathComponent("mine"), encoding: .utf8) == "моё")
        let free = r.root.appendingPathComponent("free")
        #expect(throws: S.Failure.self) { try S.restore(x, main: r.main, to: free, branch: r.site.branch, git: git) }
        #expect(!S.exists(free) && S.exists(r.wt))
        // A failure in the middle leaves nothing.
        struct E: Error {}
        #expect(throws: E.self) { try S.restore(x, main: r.main, to: free, branch: "free", git: git) { throw E() } }
        #expect(!S.exists(free))
        #expect(try !S.branchExists("free", in: r.main, git: git))
    }

    @Test func noticesChanges() throws {
        let r = try repo()
        try r.put("a.txt", "1\n")
        let x = try S.create(r.site, id: "id", number: 1, git: git)
        try r.git(r.wt, "add", "a.txt")
        #expect(try !S.matches(r.site, x, git: git))
        try r.git(r.wt, "reset", "-q")
        #expect(try S.matches(r.site, x, git: git))
        try r.put("new", "1")
        #expect(try !S.matches(r.site, x, git: git))
        try r.rm("new")
        try r.commit()
        #expect(try !S.matches(r.site, x, git: git))
    }

    private func refuses(_ r: CheckpointTests.Repo) {
        #expect(throws: S.Failure.self) { try S.create(r.site, id: "id", number: 1, git: git) }
        #expect(!git(["rev-parse", "-q", "--verify", S.prefix + "id/1"], r.main, [:], nil).ok)
    }
    @Test func refusesConflicts() throws {
        let r = try repo()
        try r.put("a.txt", "w\n"); try r.commit()
        try r.put("a.txt", "m\n", r.main)
        try r.git(r.main, "commit", "-qam", "m")
        _ = git(["-c", "user.name=t", "-c", "user.email=t@t", "merge", "main"], r.wt, [:], nil)
        refuses(r)
    }
    @Test func refusesNested() throws {
        let r = try repo()
        try r.git(r.wt, "init", "-q", "sub")
        refuses(r)
    }
    @Test func refusesHidden() throws {
        for flag in ["--skip-worktree", "--assume-unchanged"] {
            let r = try repo()
            try r.git(r.wt, "update-index", flag, "a.txt")
            refuses(r)
        }
    }
    @Test func refusesSpecial() throws {
        let r = try repo()
        #expect(mkfifo(r.wt.appendingPathComponent("pipe").path, 0o600) == 0)
        refuses(r)
        // In an ignored folder it is lost with the rest.
        let o = try repo()
        try o.put("node_modules/x", "1")
        #expect(mkfifo(o.wt.appendingPathComponent("node_modules/pipe").path, 0o600) == 0)
        _ = try S.create(o.site, id: "id", number: 1, git: git)
    }
    @Test func refusesDetached() throws {
        let r = try repo()
        try r.git(r.wt, "checkout", "-q", "--detach")
        refuses(r)
    }
    @Test func refusesUnreadable() throws {
        let r = try repo()
        try r.put("secret", "x")
        let p = r.wt.appendingPathComponent("secret").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: p)
        refuses(r)
    }
    /// A snapshot that can't be read back isn't one.
    @Test func verifiesObjects() throws {
        let r = try repo()
        try r.put("only.txt", "только в снимке\n")
        let x = try S.create(r.site, id: "id", number: 1, git: git)
        let blob = try r.git(r.main, "rev-parse", "\(x.oid):only.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(at: r.main.appendingPathComponent(".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))"))
        #expect(throws: S.Failure.self) { try S.verify(x, in: r.main, git: git) }
    }
}
