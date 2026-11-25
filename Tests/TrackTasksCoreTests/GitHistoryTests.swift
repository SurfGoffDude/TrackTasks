import Foundation
import Testing
@testable import TrackTasksCore

/// Временный репозиторий, который не зависит от настроек пользователя.
final class GitSandbox: @unchecked Sendable {
    let root: URL
    let dir: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-git-\(UUID().uuidString)").resolvingSymlinksInPath()
        dir = root.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        run("init", "-q", "-b", "main")
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    nonisolated(unsafe) static let git: GitRun.Runner = { args, dir, env, input in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        var e = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                 "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
                 "GIT_TERMINAL_PROMPT": "0", "GIT_EDITOR": "true"]
        e.merge(env) { $1 }
        p.environment = e
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        do { try p.run() } catch { return .init(status: -1, out: Data(), err: "\(error)") }
        if let input { try? inp.fileHandleForWriting.write(contentsOf: input) }
        try? inp.fileHandleForWriting.close()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        let er = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return .init(status: p.terminationStatus, out: d, err: String(decoding: er, as: UTF8.self))
    }
    nonisolated(unsafe) static let network: GitRun.Network = { git($0, $1, [:], nil) }

    @discardableResult func run(_ args: String..., at d: URL? = nil) -> String {
        let o = Self.git(args, d ?? dir, [:], nil)
        #expect(o.ok, "\(args): \(o.err)")
        return o.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func write(_ s: String, _ name: String, at d: URL? = nil) throws {
        let u = (d ?? dir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: u)
    }
    func read(_ name: String, at d: URL? = nil) -> String? {
        try? String(contentsOf: (d ?? dir).appendingPathComponent(name), encoding: .utf8)
    }
    func commit(_ name: String, at d: URL? = nil) throws {
        try write(name + "\n", name, at: d)
        run("add", "-A", at: d)
        run("commit", "-q", "-m", name, at: d)
    }
    /// Remote `origin` — пустой bare-репозиторий.
    func addRemote() -> URL {
        let bare = root.appendingPathComponent("remote.git")
        _ = Self.git(["init", "-q", "--bare", "-b", "main", bare.path], dir, [:], nil)
        run("remote", "add", "origin", bare.path)
        return bare
    }
}

@Suite struct GitHistoryTests {
    /// Рёбра, как их видно на картинке: линия из коммита вниз по дорожке до коммита, в который она приходит.
    static func drawn(_ p: GitHistory.Page) -> (edges: Set<String>, hanging: Set<String>) {
        var edges = Set<String>(), hanging = Set<String>()
        for (i, row) in p.rows.enumerated() {
            for e in row.outgoing {
                var end: Int?
                for j in p.rows.indices.dropFirst(i + 1) {
                    if p.rows[j].incoming.contains(e.lane) { end = j; break }
                    // До конца линия не прерывается.
                    #expect(p.rows[j].passing.contains(e.lane))
                }
                if let end { edges.insert(p.commits[i].id + " " + p.commits[end].id) }
                else { hanging.insert(p.commits[i].id + " " + e.parent) }
            }
            // В одной дорожке — одна линия.
            #expect(Set(row.passing).isDisjoint(with: row.incoming + [row.column]))
            #expect(Set(row.passing + row.incoming).count == row.passing.count + row.incoming.count)
        }
        return (edges, hanging)
    }
    static func real(_ s: GitSandbox) -> Set<String> {
        Set(s.run("rev-list", "--parents", "--branches", "--remotes", "--tags", "HEAD").split(separator: "\n").flatMap { l in
            let w = l.split(separator: " ")
            return w.dropFirst().map { "\(w[0]) \($0)" }
        })
    }

    private func branchy() throws -> GitSandbox {
        let s = try GitSandbox()
        try s.commit("1")
        for b in ["a", "b", "c"] {
            s.run("switch", "-q", "-c", b, "main")
            try s.commit(b + "1")
            try s.commit(b + "2")
        }
        s.run("switch", "-q", "main")
        try s.commit("2")
        s.run("merge", "-q", "--no-ff", "-m", "слияние", "a")
        try s.commit("3")
        s.run("merge", "-q", "--no-ff", "-m", "octopus", "b", "c")
        s.run("switch", "-q", "--orphan", "second")
        try s.commit("root2")
        s.run("switch", "-q", "main")
        s.run("merge", "-q", "--allow-unrelated-histories", "-m", "два корня", "second")
        s.run("switch", "-q", "-c", "open", "a")
        try s.commit("open")
        s.run("tag", "v1", "main")
        s.run("switch", "-q", "main")
        return s
    }

    @Test func graphMatchesGit() throws {
        let s = try branchy()
        let p = GitHistory.load(s.dir, git: GitSandbox.git)
        #expect(p.error == nil && !p.more && p.commits.count == p.rows.count)
        let d = Self.drawn(p)
        #expect(d.edges == Self.real(s))
        #expect(d.hanging.isEmpty)
        let merge = try #require(p.commits.first { $0.subject == "слияние" })
        #expect(merge.isMerge && merge.author == "t")
        #expect(p.commits.contains { $0.parents.count == 3 })
        #expect(p.commits.filter { $0.parents.isEmpty }.count == 2)
        let head = try #require(p.commits.first { $0.subject == "два корня" })
        #expect(Set(head.labels.map(\.name)) == ["HEAD", "main", "v1"])
    }

    @Test func pageCutsLeaveLinesHanging() throws {
        let s = try branchy()
        let all = Self.real(s)
        let total = GitHistory.load(s.dir, git: GitSandbox.git).commits.count
        for n in 1..<total {
            let p = GitHistory.load(s.dir, limit: n, git: GitSandbox.git)
            #expect(p.more && p.commits.count == n)
            let d = Self.drawn(p)
            let ids = Set(p.commits.map(\.id))
            #expect(d.edges.union(d.hanging) == all.filter { ids.contains(String($0.split(separator: " ")[0])) })
        }
        #expect(!GitHistory.load(s.dir, limit: total, git: GitSandbox.git).more)
    }

    @Test func checkpointsAreHidden() throws {
        let s = try GitSandbox()
        try s.commit("1")
        let tree = s.run("rev-parse", "HEAD^{tree}")
        let snap = s.run("commit-tree", tree, "-m", "снимок")
        s.run("update-ref", "refs/tracktasks/checkpoints/x/1", snap)
        #expect(GitHistory.load(s.dir, git: GitSandbox.git).commits.map(\.subject) == ["1"])
    }

    @Test func emptyShallowAndDetached() throws {
        let s = try GitSandbox()
        let empty = GitHistory.load(s.dir, git: GitSandbox.git)
        #expect(empty.error == nil && empty.commits.isEmpty)
        try s.commit("1")
        try s.commit("2")
        let clone = s.root.appendingPathComponent("shallow")
        s.run("clone", "-q", "--depth", "1", "file://" + s.dir.path, clone.path)
        let p = GitHistory.load(clone, git: GitSandbox.git)
        #expect(p.error == nil && p.commits.map(\.subject) == ["2"] && Self.drawn(p).hanging.isEmpty)
        s.run("switch", "-q", "--detach")
        try s.commit("loose")
        #expect(GitHistory.load(s.dir, git: GitSandbox.git).commits.map(\.subject) == ["loose", "2", "1"])
    }

    @Test func commitDiff() throws {
        let s = try GitSandbox()
        try s.commit("1")
        s.run("switch", "-q", "-c", "a")
        try s.commit("a")
        s.run("switch", "-q", "main")
        try s.commit("2")
        s.run("merge", "-q", "--no-ff", "-m", "m", "a")
        func files(_ subject: String) throws -> [String] {
            let c = try #require(GitHistory.load(s.dir, git: GitSandbox.git).commits.first { $0.subject == subject })
            let base = try #require(GitHistory.base(of: c, in: s.dir, git: GitSandbox.git))
            let sec = DiffCollector.collect(DiffSource(title: "", folder: s.dir, span: .init(from: base, to: c.id, title: "")), git: {
                let o = GitSandbox.git($0, $1, [:], nil)
                return .init(ok: o.ok, out: o.text, err: o.err)
            })
            #expect(sec.compactMap(\.error).isEmpty)
            return sec.flatMap(\.entries).map(\.file.path)
        }
        #expect(try files("1") == ["1"])
        #expect(try files("2") == ["2"])
        #expect(try files("m") == ["a"])
    }
}
