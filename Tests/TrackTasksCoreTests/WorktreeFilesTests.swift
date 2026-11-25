import Testing
import Foundation
@testable import TrackTasksCore

@Suite("WorktreeFiles")
struct WorktreeFilesTests {
    typealias G = DiffCollectorTests
    let git: WorktreeFiles.Git = { a, d in let r = G.git(a, d); return (r.ok, r.out) }

    func project(_ about: String? = nil, include: String? = nil) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("wf-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: u.appendingPathComponent("conf"), withIntermediateDirectories: true)
        try fm.createDirectory(at: u.appendingPathComponent("cache"), withIntermediateDirectories: true)
        #expect(G.git(["init", "-q", "-b", "main"], u).ok)
        try "*.secret\ncache/\n.env\n".write(to: u.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "code\n".write(to: u.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "tracked\n".write(to: u.appendingPathComponent("conf/tracked.secret"), atomically: true, encoding: .utf8)
        try "k\n".write(to: u.appendingPathComponent("conf/db.secret"), atomically: true, encoding: .utf8)
        try "c\n".write(to: u.appendingPathComponent("cache/x"), atomically: true, encoding: .utf8)
        try "E=1\n".write(to: u.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        if let about { try about.write(to: u.appendingPathComponent("about.md"), atomically: true, encoding: .utf8) }
        if let include { try include.write(to: u.appendingPathComponent(".worktreeinclude"), atomically: true, encoding: .utf8) }
        #expect(G.git(["add", "-f", "conf/tracked.secret"], u).ok)
        #expect(G.git(["add", ".gitignore", "a.txt"], u).ok)
        #expect(G.git(["commit", "-q", "-m", "i"], u).ok)
        return u
    }

    func worktree(_ main: URL) throws -> URL {
        let wt = FileManager.default.temporaryDirectory.appendingPathComponent("wfw-\(UUID().uuidString)")
        #expect(G.git(WorktreeGit.add(branch: "tracktasks/x", path: wt.path, base: "HEAD"), main).ok)
        return wt
    }

    @Test func copyAndShare() throws {
        let p = try project("---\nname: x\nshared: [cache]\n---\n", include: "# c\n*.secret\n")
        let wt = try worktree(p)
        defer { for u in [p, wt] { try? FileManager.default.removeItem(at: u) } }
        let plan = WorktreeFiles.plan(project: p, git: git)
        #expect(plan.shares == ["cache"])
        #expect(plan.copies == ["conf/db.secret"])
        let m = WorktreeFiles.apply(plan, from: p, to: wt)
        WorktreeFiles.write(m, to: wt)
        #expect(try String(contentsOf: wt.appendingPathComponent("conf/db.secret"), encoding: .utf8) == "k\n")
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: wt.appendingPathComponent("cache").path)
        #expect(link == p.appendingPathComponent("cache").path)
        #expect(WorktreeFiles.links(of: wt).contains("cache"))
        #expect(WorktreeFiles.links(of: wt).contains("conf/db.secret"))
        // The tracked file is not a copy: git already put it there.
        #expect(!plan.copies.contains("conf/tracked.secret"))
    }

    @Test func missingTrackedAndOutside() throws {
        let p = try project("---\nshared: [nope, conf/tracked.secret, ../x, /etc/passwd, plain.txt]\n---\n",
                            include: "!neg\n../up\nmissing.env\nconf/tracked.secret\n")
        defer { try? FileManager.default.removeItem(at: p) }
        try "x\n".write(to: p.appendingPathComponent("plain.txt"), atomically: true, encoding: .utf8)
        let plan = WorktreeFiles.plan(project: p, git: git)
        #expect(plan.shares.isEmpty && plan.copies.isEmpty)
        let text = plan.warnings.joined(separator: "\n")
        for part in ["нет такого файла", "отслеживается git", "«..» в пути", "абсолютный путь", "не игнорируется git", "отрицание"] {
            #expect(text.contains(part), "\(part)")
        }
    }

    @Test func symlinkOutsideRefused() throws {
        let p = try project("---\nshared: [out]\n---\n", include: "link.secret\n")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("wfo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { for u in [p, outside] { try? FileManager.default.removeItem(at: u) } }
        try FileManager.default.createSymbolicLink(at: p.appendingPathComponent("out"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: p.appendingPathComponent("link.secret"), withDestinationURL: outside)
        try "out\n".appendLine(to: p.appendingPathComponent(".gitignore"))
        let plan = WorktreeFiles.plan(project: p, git: git)
        #expect(plan.shares.isEmpty && plan.copies.isEmpty)
        #expect(plan.warnings.joined().contains("за пределы проекта"))
    }

    @Test func withoutSettingsNothingChanges() throws {
        let p = try project()
        let wt = try worktree(p)
        defer { for u in [p, wt] { try? FileManager.default.removeItem(at: u) } }
        let plan = WorktreeFiles.plan(project: p, git: git)
        #expect(plan.isEmpty)
        #expect(WorktreeFiles.links(of: wt) == WorktreeFiles.builtin)
        #expect(WorktreeFiles.manifest(of: wt) == nil)
    }

    @Test func preparedFilesStayOutOfCommitAndMerge() throws {
        let p = try project("---\nshared: [cache]\n---\n", include: "*.secret\n")
        let wt = try worktree(p)
        defer { for u in [p, wt] { try? FileManager.default.removeItem(at: u) } }
        let m = WorktreeFiles.apply(WorktreeFiles.plan(project: p, git: git), from: p, to: wt)
        WorktreeFiles.write(m, to: wt)
        try "agent\n".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        // git exits 1 when an excluded path is ignored, but still stages the rest (commitAll ignores the code too).
        _ = G.git(WorktreeGit.stage(excluding: WorktreeFiles.links(of: wt)), wt)
        #expect(G.git(["commit", "-q", "-m", "job"], wt).ok)
        #expect(G.git(["show", "--name-only", "--format=", "tracktasks/x"], p).out == "a.txt\n")
        // The main folder takes the branch without a clash with its own ignored copies.
        #expect(G.git(["merge", "--ff-only", "tracktasks/x"], p).ok)
        #expect(try String(contentsOf: p.appendingPathComponent("conf/db.secret"), encoding: .utf8) == "k\n")
        #expect(G.git(["status", "--porcelain"], p).out == "?? .worktreeinclude\n?? about.md\n")
    }
}

private extension String {
    func appendLine(to url: URL) throws {
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (old + self).write(to: url, atomically: true, encoding: .utf8)
    }
}
