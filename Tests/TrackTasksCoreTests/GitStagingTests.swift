import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct GitStagingTests {
    let git = GitSandbox.git

    private func files(_ s: GitSandbox) throws -> [GitFile] { try GitStaging.status(s.dir, git: git).get() }
    private func commit(_ s: GitSandbox, _ pick: [String], lose: Bool = false) throws -> Result<String, GitRun.Failure> {
        let f = try files(s)
        return GitStaging.commit(s.dir, message: "m", shown: f, selected: Set(f.filter { pick.contains($0.path) }.map(\.id)), mayLose: lose, git: git)
    }
    private func ok(_ r: Result<String, GitRun.Failure>) -> Bool { if case .success = r { true } else { false } }
    /// Что попало в последний коммит.
    private func inCommit(_ s: GitSandbox) -> Set<String> {
        let o = git(["show", "--format=", "--name-only", "--no-renames", "-z", "HEAD"], s.dir, [:], nil)
        return Set(o.text.split(separator: "\0").map(String.init))
    }

    @Test func onlyChosenFiles() throws {
        let s = try GitSandbox()
        for n in ["a", "b", "gone"] { try s.write("1\n", n) }
        try s.commit("base")
        try s.write("2\n", "a")
        try s.write("2\n", "b")
        try FileManager.default.removeItem(at: s.dir.appendingPathComponent("gone"))
        // Имена, которые git принял бы за шаблон или обрезал.
        let odd = [" пробел в начале.txt", "*", "кириллица й.txt", ":(top)x"]
        for n in odd { try s.write("x\n", n) }
        try s.write("x\n", "other.txt")
        let all = try files(s)
        #expect(Set(all.map(\.path)) == Set(["a", "b", "gone", "other.txt"] + odd))
        #expect(GitStaging.defaultSelection(all, risky: ["other.txt"]).count == all.count - 1)
        #expect(ok(try commit(s, ["a", "gone"] + odd)))
        #expect(inCommit(s) == Set(["a", "gone"] + odd))
        #expect(Set(try files(s).map(\.path)) == ["b", "other.txt"])
    }

    @Test func partialStaging() throws {
        let s = try GitSandbox()
        try s.write("1\n", "f")
        try s.commit("base")
        try s.write("2\n", "f")
        s.run("add", "f")
        try s.write("3\n", "f")
        try s.write("x\n", "new")
        let f = try files(s)
        #expect(f.first { $0.path == "f" }?.kind == .partial)
        // Индекс не пуст: отмечено только то, что в нём.
        #expect(GitStaging.defaultSelection(f, risky: []) == [Data("f".utf8)])
        // Версия из индекса теряется только с подтверждением.
        #expect(!ok(try commit(s, ["new"])))
        #expect(s.run("show", ":f") == "2")
        #expect(ok(try commit(s, ["f"])))
        #expect(s.run("show", "HEAD:f") == "2" && s.read("f") == "3\n")
        #expect(inCommit(s) == ["f"])

        s.run("add", "f")
        try s.write("4\n", "f")
        #expect(ok(try commit(s, ["new"], lose: true)))
        #expect(inCommit(s) == ["new"])
        #expect(s.read("f") == "4\n" && s.run("show", "HEAD:f") == "2")
    }

    @Test func unstagedAndRenamed() throws {
        let s = try GitSandbox()
        try s.write("одно\nдва\nтри\nчетыре\n", "old name")
        try s.write("1\n", "keep")
        try s.commit("base")
        s.run("mv", "old name", "new name")
        try s.write("2\n", "keep")
        s.run("add", "keep")
        let f = try files(s)
        let r = try #require(f.first { $0.path == "new name" })
        #expect(r.oldPath == "old name" && r.kind == .staged)
        // Снятое с отметки уходит из индекса, обе стороны переименования вместе.
        #expect(ok(try commit(s, ["keep"])))
        #expect(inCommit(s) == ["keep"])
        #expect(s.read("new name") != nil && s.run("diff", "--cached", "--name-only").isEmpty)
        s.run("add", "-A")
        #expect(ok(try commit(s, ["new name"])))
        #expect(inCommit(s) == ["old name", "new name"])
        #expect(try files(s).isEmpty)
    }

    @Test func removedFromIndexIsOneRow() throws {
        let s = try GitSandbox()
        try s.commit("f")
        s.run("rm", "-q", "--cached", "f")
        let f = try files(s)
        #expect(f.count == 1 && f[0].kind == .partial)
        #expect(ok(try commit(s, ["f"])))
        #expect(inCommit(s) == ["f"] && s.read("f") == "f\n")
        #expect(try files(s).map(\.kind) == [.untracked])
    }

    @Test func noCommitsYet() throws {
        let s = try GitSandbox()
        try s.write("1\n", "a")
        try s.write("1\n", "b")
        s.run("add", "a")
        try s.write("2\n", "a")
        #expect(ok(try commit(s, ["b"], lose: true)))
        #expect(inCommit(s) == ["b"])
        #expect(s.read("a") == "2\n" && s.run("ls-files") == "b")
    }

    @Test func conflictsAndOperations() throws {
        let s = try GitSandbox()
        try s.commit("f")
        s.run("switch", "-q", "-c", "o")
        try s.write("o\n", "f")
        s.run("commit", "-q", "-am", "o")
        s.run("switch", "-q", "main")
        try s.write("m\n", "f")
        s.run("commit", "-q", "-am", "m")
        _ = git(["merge", "o"], s.dir, [:], nil)
        let f = try files(s)
        #expect(f.map(\.kind) == [.conflict])
        #expect(GitStaging.defaultSelection(f, risky: []).isEmpty)
        #expect(!ok(try commit(s, ["f"])))
    }

    @Test func changedListIsRefused() throws {
        let s = try GitSandbox()
        try s.commit("base")
        try s.write("1\n", "a")
        let shown = try files(s)
        let sel = Set(shown.map(\.id))
        // Появление постороннего файла не мешает, а чужой git add — мешает.
        try s.write("1\n", "tasks/x.md")
        s.run("add", "tasks")
        #expect(!ok(GitStaging.commit(s.dir, message: "m", shown: shown, selected: sel, git: git)))
        s.run("restore", "--staged", "tasks")
        #expect(ok(GitStaging.commit(s.dir, message: "m", shown: shown, selected: sel, git: git)))
        #expect(inCommit(s) == ["a"])
    }

    @Test func hookFailureIsReported() throws {
        let s = try GitSandbox()
        try s.commit("base")
        let hook = s.dir.appendingPathComponent(".git/hooks/pre-commit")
        try s.write("#!/bin/sh\necho нельзя >&2\nexit 1\n", ".git/hooks/pre-commit")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try s.write("1\n", "a")
        guard case .failure(let e) = try commit(s, ["a"]) else { Issue.record("хук не сработал"); return }
        #expect(e.message.contains("нельзя") && e.message.contains("Индекс уже изменён"))
        #expect(s.read("a") == "1\n")
    }

    @Test func draftDiffHasOnlyChosen() throws {
        let s = try GitSandbox()
        try s.write("1\n", "a")
        try s.write("1\n", "b")
        try s.commit("base")
        try s.write("выбран\n", "a")
        try s.write("лишний\n", "b")
        let d = GitStaging.diff(s.dir, files: try files(s).filter { $0.path == "a" }, git: git)
        #expect(d.contains("выбран") && !d.contains("лишний"))
    }
}
