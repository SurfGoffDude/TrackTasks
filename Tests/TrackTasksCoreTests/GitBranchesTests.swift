import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct GitBranchesTests {
    let git = GitSandbox.git

    /// main: f=1, only.txt; other: f=2, new.txt, без only.txt.
    private func two() throws -> GitSandbox {
        let s = try GitSandbox()
        try s.write("1\n", "f")
        try s.write("x\n", "same")
        try s.write("*.log\n", ".gitignore")
        try s.commit("only.txt")
        s.run("switch", "-q", "-c", "other")
        try s.write("2\n", "f")
        s.run("rm", "-q", "only.txt")
        try s.write("ветка\n", "new.txt")
        try s.write("ветка\n", "keep.log")
        s.run("add", "-f", "keep.log")
        try s.commit("o")
        s.run("switch", "-q", "main")
        return s
    }
    private func go(_ s: GitSandbox, _ ref: String = "refs/heads/other", _ ok: Set<String> = []) -> GitBranches.SwitchResult {
        GitBranches.switchTo(ref, in: s.dir, confirmed: ok, git: git)
    }
    private func current(_ s: GitSandbox) -> String { s.run("branch", "--show-current") }

    @Test func cleanSwitch() throws {
        let s = try two()
        #expect(go(s) == .done)
        #expect(current(s) == "other")
        #expect(go(s) == .failed("Эта ветка уже открыта"))
    }

    @Test func dirtyAsksAndKeepsEdits() throws {
        let s = try two()
        try s.write("моё\n", "same")
        try s.write("новое\n", "mine.txt")
        #expect(go(s) == .ask(["mine.txt", "same"]))
        #expect(current(s) == "main")
        // Подтверждено не всё, что сейчас грязно.
        #expect(go(s, "refs/heads/other", ["same"]) == .ask(["mine.txt", "same"]))
        s.run("add", "same")
        #expect(go(s, "refs/heads/other", ["same", "mine.txt"]) == .done)
        #expect(s.read("same") == "моё\n" && s.read("mine.txt") == "новое\n")
        #expect(s.run("diff", "--cached", "--name-only") == "same")
    }

    @Test(arguments: ["f", "only.txt", "new.txt", "keep.log"])
    func conflictingEditsStopTheSwitch(_ name: String) throws {
        for staged in [false, true] {
            let s = try two()
            try s.write("моё\n", name)
            if staged { s.run("add", "-f", name) }
            guard case .failed = go(s, "refs/heads/other", [name]) else { Issue.record("\(name) staged=\(staged)"); continue }
            #expect(current(s) == "main")
            #expect(s.read(name) == "моё\n")
        }
    }

    @Test func otherWorktreeAndOperation() throws {
        let s = try two()
        let wt = s.root.appendingPathComponent("wt")
        s.run("worktree", "add", "-q", wt.path, "other")
        let b = try #require(GitBranches.load(s.dir, git: git).branches.first { $0.name == "other" })
        #expect(b.worktree?.hasSuffix("/wt") == true)
        guard case .failed(let why) = go(s) else { Issue.record("переключилось"); return }
        #expect(why.contains("другой папке"))
        s.run("worktree", "remove", wt.path)
        _ = git(["merge", "--no-ff", "--no-commit", "other"], s.dir, [:], nil)
        #expect(GitBranches.load(s.dir, git: git).operation == "merge")
        guard case .failed = go(s) else { Issue.record("переключилось"); return }
    }

    @Test func detachedCommitsAreNotLeftBehind() throws {
        let s = try two()
        s.run("switch", "-q", "--detach")
        #expect(GitBranches.load(s.dir, git: git).branch == nil)
        try s.commit("loose")
        guard case .failed(let why) = go(s) else { Issue.record("переключилось"); return }
        #expect(why.contains("без ветки"))
        s.run("switch", "-q", "-c", "saved")
        #expect(go(s) == .done)
    }

    @Test func emptyRepository() throws {
        let s = try GitSandbox()
        let st = GitBranches.load(s.dir, git: git)
        #expect(st.error == nil && st.unborn && st.branch == "main" && st.branches.isEmpty)
    }

    @Test func remoteBranch() throws {
        let s = try two()
        _ = s.addRemote()
        s.run("push", "-q", "origin", "main", "other")
        s.run("branch", "-q", "-D", "other")
        s.run("remote", "set-head", "origin", "main")
        let st = GitBranches.load(s.dir, git: git)
        #expect(st.branches.filter { $0.remote == "origin" }.map(\.localName) == ["main", "other"])
        guard case .failed = go(s, "refs/remotes/origin/main") else { Issue.record("локальная уже есть"); return }
        #expect(go(s, "refs/remotes/origin/other") == .done)
        let b = try #require(GitBranches.load(s.dir, git: git).branches.first { $0.isCurrent })
        #expect(b.name == "other" && b.upstream == "origin/other")
    }

    @Test func trackParsing() {
        #expect(GitBranches.track("ahead 2, behind 3") == (2, 3, false))
        #expect(GitBranches.track("behind 1") == (0, 1, false))
        #expect(GitBranches.track("gone") == (0, 0, true))
        #expect(GitBranches.track("") == (0, 0, false))
    }

    // MARK: Pull и push

    /// Две копии одного remote; в `other` можно сделать чужой коммит.
    private func shared() throws -> (GitSandbox, other: URL, bare: URL) {
        let s = try GitSandbox()
        try s.write("*.log\n", ".gitignore")
        try s.commit("1")
        let bare = s.addRemote()
        s.run("push", "-q", "-u", "origin", "main")
        let other = s.root.appendingPathComponent("other")
        s.run("clone", "-q", bare.path, other.path)
        return (s, other, bare)
    }
    private func pull(_ s: GitSandbox) throws -> Result<String, GitRun.Failure> {
        let src = try GitBranches.pullSource(s.dir, git: git).get()
        try GitBranches.fetch(s.dir, remote: src.remote, git: git, network: GitSandbox.network).get()
        return GitBranches.fastForward(s.dir, branch: src.branch, git: git)
    }
    private func ok(_ r: Result<String, GitRun.Failure>) -> Bool { if case .success = r { true } else { false } }

    @Test func pullFastForwards() throws {
        let (s, other, _) = try shared()
        #expect(try pull(s).get() == "Новых коммитов нет")
        try s.commit("2", at: other)
        s.run("push", "-q", at: other)
        try s.write("моё\n", "1")
        // Настройки ветки не превращают pull во что-то другое.
        s.run("config", "branch.main.mergeoptions", "--squash")
        #expect(try pull(s).get() == "Подтянуто коммитов: 1")
        #expect(s.read("2") == "2\n" && s.read("1") == "моё\n")
        #expect(s.run("rev-parse", "HEAD") == s.run("rev-parse", "HEAD", at: other))
    }

    @Test func pullKeepsLocalFiles() throws {
        for name in ["keep.log", "new.txt", "1"] {
            let (s, other, _) = try shared()
            try s.write("чужое\n", name, at: other)
            s.run("add", "-f", name, at: other)
            s.run("commit", "-q", "-m", "x", at: other)
            s.run("push", "-q", at: other)
            try s.write("моё\n", name)
            let head = s.run("rev-parse", "HEAD")
            #expect(try !ok(pull(s)))
            #expect(s.read(name) == "моё\n")
            #expect(s.run("rev-parse", "HEAD") == head)
            #expect(s.run("stash", "list").isEmpty)
        }
    }

    @Test func divergedIsRefusedBothWays() throws {
        let (s, other, bare) = try shared()
        try s.commit("theirs", at: other)
        s.run("push", "-q", at: other)
        try s.commit("mine")
        let theirs = s.run("rev-parse", "main", at: bare), mine = s.run("rev-parse", "HEAD")
        guard case .failure(let e) = try pull(s) else { Issue.record("подтянулось"); return }
        #expect(e.message.contains("разошлись"))
        #expect(s.run("rev-parse", "HEAD") == mine)
        // Настройки пользователя, которые делают обычный push принудительным.
        s.run("config", "remote.origin.push", "+refs/heads/*:refs/heads/*")
        s.run("config", "push.default", "matching")
        let plan = try GitBranches.pushPlan(s.dir, git: git).get()
        #expect(!ok(GitBranches.push(plan, in: s.dir, git: git, network: GitSandbox.network)))
        #expect(s.run("rev-parse", "main", at: bare) == theirs)
    }

    @Test func mirrorsAreRefused() throws {
        let (s, _, bare) = try shared()
        s.run("config", "remote.origin.mirror", "true")
        guard case .failure = GitBranches.pushPlan(s.dir, git: git) else { Issue.record("план для зеркала"); return }
        s.run("config", "remote.origin.fetch", "+refs/*:refs/*")
        guard case .failure = GitBranches.fetch(s.dir, git: git, network: GitSandbox.network) else { Issue.record("fetch зеркала"); return }
        #expect(!s.run("rev-parse", "main", at: bare).isEmpty)
    }

    @Test func pushPlans() throws {
        let (s, _, bare) = try shared()
        try s.commit("2")
        let p = try GitBranches.pushPlan(s.dir, git: git).get()
        #expect(p.title == "main → origin/main" && p.commits == 1 && !p.setUpstream)
        // Пока окно было открыто, появился ещё коммит.
        try s.commit("3")
        #expect(!ok(GitBranches.push(p, in: s.dir, git: git, network: GitSandbox.network)))
        #expect(ok(GitBranches.push(p, in: s.dir, exact: false, git: git, network: GitSandbox.network)))
        #expect(s.run("rev-parse", "main", at: bare) == s.run("rev-parse", "HEAD"))

        s.run("switch", "-q", "-c", "topic")
        try s.commit("t")
        let t = try GitBranches.pushPlan(s.dir, git: git).get()
        #expect(t.setUpstream && t.target == "topic" && t.commits == 1)
        #expect(ok(GitBranches.push(t, in: s.dir, git: git, network: GitSandbox.network)))
        #expect(s.run("rev-parse", "--abbrev-ref", "@{u}") == "origin/topic")

        s.run("switch", "-q", "--detach")
        guard case .failure = GitBranches.pushPlan(s.dir, git: git) else { Issue.record("detached"); return }
    }

    @Test func pushGoesToTheUpstreamName() throws {
        let (s, _, bare) = try shared()
        s.run("switch", "-q", "-c", "local", "--track", "origin/main")
        try s.commit("2")
        let p = try GitBranches.pushPlan(s.dir, git: git).get()
        #expect(p.title == "local → origin/main")
        #expect(ok(GitBranches.push(p, in: s.dir, git: git, network: GitSandbox.network)))
        #expect(s.run("for-each-ref", "--format=%(refname)", at: bare) == "refs/heads/main")
    }
}
