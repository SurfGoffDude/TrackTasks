import Foundation
import Testing
@testable import TrackTasksCore

/// Временный репозиторий: main и две ветки в worktree. `verify` — настоящая команда sh в worktree.
@Suite struct SafeMergeTests {
    final class Repo {
        let root: URL, main: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("safemerge-\(UUID().uuidString)")
            main = root.appendingPathComponent("main")
            try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
            try git(main, "init", "-q", "-b", "main")
            for (k, v) in ["user.name": "t", "user.email": "t@t", "commit.gpgsign": "false"] { try git(main, "config", k, v) }
            try put("base.txt", "base\n")
            try put("local.txt", "1\n")
            try commit(main, "base")
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult func git(_ d: URL, _ a: String...) throws -> String {
            let o = CheckpointTests.run(a, d, [:], nil)
            #expect(o.ok, "\(a): \(o.err)")
            return o.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func put(_ n: String, _ s: String, _ dir: URL? = nil) throws {
            try Data(s.utf8).write(to: (dir ?? main).appendingPathComponent(n))
        }
        func read(_ n: String) -> String? { try? String(contentsOf: main.appendingPathComponent(n), encoding: .utf8) }
        func commit(_ d: URL, _ m: String) throws {
            try git(d, "add", "-A")
            try git(d, "commit", "-q", "-m", m)
        }
        func branch(_ n: String, _ files: [String: String]) throws -> SafeMerge.Site {
            let wt = root.appendingPathComponent(n)
            try git(main, "worktree", "add", "-q", "-b", "tracktasks/\(n)", wt.path)
            for (f, s) in files { try put(f, s, wt) }
            try commit(wt, n)
            return .init(folder: wt, main: main, branch: "tracktasks/\(n)")
        }
        var head: String { (try? git(main, "rev-parse", "HEAD")) ?? "" }
        var refs: String { (try? git(main, "for-each-ref", "refs/tracktasks")) ?? "" }
        var status: String { CheckpointTests.run(["status", "--porcelain"], main, [:], nil).text }
    }

    static func sh(_ cmd: String, _ dir: URL) -> SafeMerge.VerifyResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = dir
        try? p.run()
        p.waitUntilExit()
        return .init(ok: p.terminationStatus == 0, output: "код \(p.terminationStatus)")
    }

    private func merge(_ s: SafeMerge.Site, _ cmd: String = "true", task: String = "", known: SafeMerge.Check? = nil, artifacts: [String] = [],
                       allowed: SafeMerge.Allowed = .files([]),
                       cancelled: @escaping () -> Bool = { false }, onPhase: @escaping (SafeMerge.Phase) -> Void = { _ in },
                       mayLand: @escaping () -> String? = { nil }, git: @escaping SafeMerge.Runner = CheckpointTests.run,
                       during: @escaping () -> Void = {}) -> SafeMerge.Report {
        SafeMerge.run(s, command: cmd, taskCommand: task, known: known, artifacts: artifacts, allowed: allowed, git: git,
                      hooks: .init(verify: { c in let r = Self.sh(c, s.folder); during(); return r },
                                   isCancelled: cancelled, onPhase: onPhase, mayLand: mayLand))
    }
    private func landed(_ r: SafeMerge.Report) -> Bool { if case .merged = r.outcome { true } else { false } }

    /// Проверка проекта, затем проверка задачи: красная любая останавливает слияние.
    @Test(arguments: [("false", "true", false), ("true", "false", true), ("false", "false", false)])
    func eitherCheckStops(_ c: (String, String, Bool)) throws {
        let r = try Repo(), a = try r.branch("a", ["a.txt": "a"]), before = r.head
        let m = merge(a, c.0, task: c.1)
        #expect(m.outcome == .red && r.head == before && m.check?.state == .red)
        #expect((m.check?.taskFailed == true) == c.2 && m.check?.failedCommand == (c.2 ? c.1 : c.0))
        #expect(m.check?.command == c.0 && m.check?.taskCommand == c.1)
    }

    @Test func taskCheckRunsAfterAndOnlyAdds() throws {
        let r = try Repo(), a = try r.branch("a", ["a.txt": "a"])
        // Комментарий и «|| true» одной команды не влияют на другую.
        #expect(merge(a, "touch p.log; false # x", task: "true || touch t.log").outcome == .red)
        #expect(!FileManager.default.fileExists(atPath: a.folder.appendingPathComponent("t.log").path))
        let m = merge(a, "touch p.log", task: "test -f p.log && touch t.log", artifacts: ["p.log"])
        #expect(landed(m) && m.check?.state == .passed && m.check?.taskCommand != nil)
        #expect(Set(m.artifacts) == ["p.log", "t.log"])
        // Пустая проверка проекта остаётся «не проверено».
        let b = try r.branch("b", ["b.txt": "b"])
        let n = merge(b, "", task: "test -f b.txt")
        #expect(landed(n) && n.check?.state == .unverified)
        let c = try r.branch("c", ["c.txt": "c"])
        #expect(merge(c, "", task: "false").outcome == .red)
    }

    @Test func oldCheckDoesNotCoverTheTaskOne() throws {
        let r = try Repo(), a = try r.branch("a", ["a.txt": "a"])
        let stopped = merge(a, "true", mayLand: { "стоп" })
        let data = try JSONEncoder().encode(try #require(stopped.check))
        #expect(!String(decoding: data, as: UTF8.self).contains("task"))
        let old = try JSONDecoder().decode(SafeMerge.Check.self, from: data)
        #expect(old.covers(old.branchCommit, old.mainCommit, "main", "true", ""))
        #expect(merge(a, "true", task: "false", known: old).outcome == .red)
    }

    /// Чисто сливаются, но вместе проверка падает: вторая не попадает в main.
    @Test func brokenTogetherStaysOut() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"]), b = try r.branch("b", ["b.txt": "b"])
        let cmd = "! { test -f a.txt && test -f b.txt; }"
        #expect(Self.sh(cmd, a.folder).ok && Self.sh(cmd, b.folder).ok)
        #expect(landed(merge(a, cmd)))
        let before = r.head
        let m = merge(b, cmd)
        #expect(m.outcome == .red)
        #expect(m.check?.state == .red && m.check?.output.isEmpty == false)
        #expect(m.mergedMain == before)
        #expect(r.head == before && r.read("b.txt") == nil && r.status.isEmpty)
        #expect(r.refs.isEmpty)
    }

    @Test func treeIsExactlyTheCheckedOne() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        try r.put("m.txt", "m")
        try r.commit(r.main, "m")
        let m0 = r.head
        let m = merge(a)
        #expect(landed(m))
        let v = try #require(m.check?.branchCommit)
        #expect(try r.git(r.main, "rev-parse", "HEAD^{tree}") == r.git(r.main, "rev-parse", "\(v)^{tree}"))
        #expect(try r.git(r.main, "rev-parse", "HEAD^1") == m0)
        #expect(try r.git(r.main, "rev-parse", "HEAD^2") == v)
        #expect(r.read("a.txt") == "a" && r.read("m.txt") == "m")
        #expect(r.status.isEmpty)
    }

    @Test func movedMainIsCheckedAgain() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        var runs = 0
        let m = merge(a, during: {
            runs += 1
            if runs == 1 { try? r.put("new.txt", "n"); try? r.commit(r.main, "сдвиг") }
        })
        #expect(landed(m) && runs == 2)
        #expect(r.read("new.txt") == "n" && r.read("a.txt") == "a")
    }

    /// Новый main ломает проверку: повтор её ловит.
    @Test func movedMainThatBreaksIsNotMerged() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        let m = merge(a, "! test -f bad.txt", during: {
            if r.read("bad.txt") == nil { try? r.put("bad.txt", "x"); try? r.commit(r.main, "bad") }
        })
        #expect(m.outcome == .red)
        #expect(r.read("a.txt") == nil)
    }

    @Test func movingMainStopsAfterTwoRepeats() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        var runs = 0
        let m = merge(a, during: {
            runs += 1
            try? r.put("n\(runs).txt", "n")
            try? r.commit(r.main, "сдвиг \(runs)")
        })
        #expect(m.outcome == .moved && runs == 3)
        #expect(r.read("a.txt") == nil)
    }

    /// main сдвинулся уже после сверки: отказывает сам git.
    @Test func moveBetweenTheCheckAndFastForward() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        var runs = 0, moved = false
        let m = merge(a, git: { args, dir, env, input in
            if args.contains("--ff-only"), !moved {
                moved = true
                try? r.put("late.txt", "l")
                try? r.commit(r.main, "поздно")
            }
            return CheckpointTests.run(args, dir, env, input)
        }, during: { runs += 1 })
        #expect(landed(m) && runs == 2)
        #expect(r.read("late.txt") == "l")
    }

    @Test func switchedBranchStops() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        let m = merge(a, during: { _ = try? r.git(r.main, "switch", "-q", "-c", "other") })
        guard case .failed(let t) = m.outcome else { Issue.record("\(m.outcome)"); return }
        #expect(t.contains("переключили"))
        #expect(r.read("a.txt") == nil)
    }

    @Test func rewrittenMainStops() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        try r.put("m.txt", "m")
        try r.commit(r.main, "m")
        let m = merge(a, during: { _ = try? r.git(r.main, "commit", "-q", "--amend", "-m", "другое") })
        guard case .failed(let t) = m.outcome else { Issue.record("\(m.outcome)"); return }
        #expect(t.contains("переписана"))
    }

    @Test func verifyThatChangesCode() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        let m = merge(a, "echo x >> base.txt")
        guard case .failed = m.outcome else { Issue.record("\(m.outcome)"); return }
        #expect(m.check == nil && r.read("a.txt") == nil)
    }

    @Test func artifactsDontBlock() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        let red = merge(a, "touch out.log; false")
        #expect(red.outcome == .red && red.check?.artifacts == ["out.log"] && red.artifacts == ["out.log"])
        let m = merge(a, "touch out.log", known: red.check, artifacts: red.artifacts)
        #expect(landed(m) && m.artifacts == ["out.log"])
        #expect(r.read("out.log") == nil)
    }

    /// Остановка во время verify: следы сборки не теряются, чужой файл по-прежнему мешает.
    @Test func artifactsSurviveCancel() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        var stop = false
        let m = merge(a, "touch out.log", cancelled: { stop }, during: { stop = true })
        #expect(m.outcome == .cancelled && m.check == nil && m.artifacts == ["out.log"])
        guard case .failed = merge(a).outcome else { Issue.record("слито"); return }
        #expect(SafeMerge.uncommitted(a, git: CheckpointTests.run) == ["out.log"])
        #expect(SafeMerge.uncommitted(a, ignoring: m.artifacts, git: CheckpointTests.run).isEmpty)
        try r.put("mine.txt", "m", a.folder)
        guard case .failed(let t) = merge(a, artifacts: m.artifacts).outcome else { Issue.record("слито"); return }
        #expect(t.contains("mine.txt") && !t.contains("out.log"))
        try FileManager.default.removeItem(at: a.folder.appendingPathComponent("mine.txt"))
        #expect(landed(merge(a, artifacts: m.artifacts)))
    }

    /// Проверено не то, что в ветке: запись проверки сброшена, следы сборки остались.
    @Test func artifactsSurviveStaleCheck() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        let m = merge(a, "touch out.log; echo x >> base.txt")
        guard case .failed = m.outcome else { Issue.record("\(m.outcome)"); return }
        #expect(m.check == nil && m.artifacts == ["out.log"])
        try r.git(a.folder, "checkout", "-q", "base.txt")
        #expect(landed(merge(a, artifacts: m.artifacts)))
    }

    /// Файл стал отслеживаемым — из списка выбывает, его правка блокирует слияние.
    @Test func trackedFileIsNotAnArtifact() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a", "out.log": "1"])
        try r.put("out.log", "2", a.folder)
        let m = merge(a, artifacts: ["out.log", "gone.log"])
        guard case .failed(let t) = m.outcome else { Issue.record("слито"); return }
        #expect(t.contains("out.log") && m.artifacts.isEmpty)
    }

    /// «Слить все»: средняя красная, первая и третья в main.
    @Test func batchGoesPastTheRedOne() throws {
        let r = try Repo()
        let sites = try ["a", "b", "c"].map { try r.branch($0, ["\($0).txt": $0]) }
        let ids = sites.map { _ in UUID() }
        var batch = MergeBatch(ids)
        while let id = batch.next() {
            let s = sites[ids.firstIndex(of: id)!]
            let m = merge(s, "! { test -f a.txt && test -f b.txt; }")
            batch.record(s.branch, skipped: landed(m) ? nil : "\(m.outcome)")
        }
        #expect(batch.merged == 2 && batch.skipped == [.init(title: "tracktasks/b", reason: "red")])
        #expect(r.read("a.txt") == "a" && r.read("b.txt") == nil && r.read("c.txt") == "c")
    }

    @Test func uncommittedWorktreeCodeBlocks() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        try r.put("forgotten.txt", "f", a.folder)
        guard case .failed(let t) = merge(a).outcome else { Issue.record("слито"); return }
        #expect(t.contains("forgotten.txt"))
    }

    @Test func conflictIsAborted() throws {
        let r = try Repo()
        let a = try r.branch("a", ["base.txt": "ветка\n"])
        try r.put("base.txt", "main\n")
        try r.commit(r.main, "main")
        let before = r.head
        #expect(merge(a).outcome == .conflict(["base.txt"]))
        #expect(r.head == before)
        #expect(!CheckpointTests.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], a.folder, [:], nil).ok)
        #expect(try r.git(a.folder, "status", "--porcelain").isEmpty)
    }

    @Test func timeoutIsNotMerged() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        let m = SafeMerge.run(a, command: "x", git: CheckpointTests.run, hooks: .init(verify: { _ in .init(ok: false, timedOut: true) }))
        #expect(m.outcome == .timedOut && m.check?.state == .timedOut && r.read("a.txt") == nil)
    }

    @Test func emptyVerifyIsMarked() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        let m = merge(a, "")
        #expect(landed(m) && m.check?.state == .unverified)
    }

    @Test func cancelLeavesMain() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        var stop = false
        #expect(merge(a, cancelled: { stop }, during: { stop = true }).outcome == .cancelled)
        #expect(r.read("a.txt") == nil && r.refs.isEmpty)
        #expect(landed(merge(a)))
    }

    @Test func lastWordBeforeLanding() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        let m = merge(a, mayLand: { "идёт ответ" })
        #expect(m.outcome == .failed("идёт ответ") && r.read("a.txt") == nil)
    }

    // MARK: Незакоммиченные правки основной папки

    @Test func unrelatedEditsSurvive() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        try r.put("local.txt", "правка\n")
        try r.put("untracked.txt", "u")
        #expect(landed(merge(a)))
        #expect(r.read("local.txt") == "правка\n" && r.read("untracked.txt") == "u" && r.read("a.txt") == "a")
    }

    @Test func overlapAsksThenKeepsEdits() throws {
        let r = try Repo()
        let a = try r.branch("a", ["base.txt": "ветка\n"])
        try r.put("base.txt", "моё\n")
        #expect(SafeMerge.precheck(a, allowed: .files([]), git: CheckpointTests.run) == .overlap(["base.txt"]))
        let before = r.head
        var runs = 0
        let asked = merge(a, during: { runs += 1 })
        #expect(asked.outcome == .overlap(["base.txt"]) && r.head == before && r.read("base.txt") == "моё\n")
        // «Слить всё равно» не гоняет ту же проверку ещё раз.
        let m = merge(a, known: asked.check, allowed: .files(["base.txt"]), during: { runs += 1 })
        #expect(runs == 1)
        guard case .merged(_, let note, let markers) = m.outcome else { Issue.record("\(m.outcome)"); return }
        #expect(markers && note.contains("git stash"))
        #expect(try r.git(r.main, "show", "stash@{0}:base.txt") == "моё")
        #expect(r.read("base.txt")?.contains("моё") == true)
    }

    @Test func compatibleOverlapIsRestored() throws {
        let r = try Repo()
        let lines = (1...20).map { "\($0)\n" }
        try r.put("long.txt", lines.joined())
        try r.commit(r.main, "long")
        let a = try r.branch("a", ["long.txt": (["первая\n"] + lines.dropFirst()).joined()])
        try r.put("long.txt", (lines.dropLast() + ["последняя\n"]).joined())
        #expect(landed(merge(a, allowed: .any)))
        let t = r.read("long.txt") ?? ""
        #expect(t.hasPrefix("первая") && t.hasSuffix("последняя\n"))
        #expect(try r.git(r.main, "stash", "list").isEmpty)
    }

    @Test func editsThatAppearDuringVerify() throws {
        let r = try Repo()
        let a = try r.branch("a", ["base.txt": "ветка\n"])
        let before = r.head
        let m = merge(a, during: { try? r.put("base.txt", "моё\n") })
        #expect(m.outcome == .overlap(["base.txt"]) && r.head == before && r.read("base.txt") == "моё\n")
    }

    /// Слияние сорвалось после stash: правки вернулись.
    @Test func editsComeBackWhenFastForwardFails() throws {
        let r = try Repo()
        let a = try r.branch("a", ["base.txt": "ветка\n"])
        try r.put("base.txt", "моё\n")
        let before = r.head
        var n = 0
        let m = merge(a, allowed: .any, git: { args, dir, env, input in
            if args.contains("--ff-only") {
                n += 1
                if n == 2 { return .init(status: 1, out: Data(), err: "сбой") }
            }
            return CheckpointTests.run(args, dir, env, input)
        })
        guard case .failed = m.outcome else { Issue.record("\(m.outcome)"); return }
        #expect(r.head == before && r.read("base.txt") == "моё\n")
        #expect(try r.git(r.main, "stash", "list").isEmpty)
    }

    // MARK: Перезапуск

    @Test func nothingToRecover() throws {
        let r = try Repo()
        #expect(SafeMerge.recover(try r.branch("a", ["a.txt": "a"]), git: CheckpointTests.run) == nil)
    }

    /// Процесс умер посреди вливания main в worktree.
    @Test func recoverDuringPrepare() throws {
        let r = try Repo()
        let a = try r.branch("a", ["base.txt": "ветка\n"])
        try r.put("base.txt", "main\n")
        try r.commit(r.main, "main")
        try r.git(r.main, "update-ref", "refs/tracktasks/merge-start/\(a.branch)", "HEAD")
        _ = CheckpointTests.run(["merge", "main"], a.folder, [:], nil)
        #expect(SafeMerge.recover(a, git: CheckpointTests.run) == .interrupted(stash: nil))
        #expect(try r.git(a.folder, "status", "--porcelain").isEmpty)
        #expect(r.refs.isEmpty)
    }

    /// Слито, потом в основной папке переключили ветку: не «основная ветка не тронута».
    @Test func recoverAfterSwitch() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        let c = try r.git(r.main, "commit-tree", "-p", "HEAD", "-p", a.branch, "-m", "c", "\(a.branch)^{tree}")
        try r.git(r.main, "branch", "other")
        try r.git(r.main, "update-ref", "refs/tracktasks/merge-land/\(a.branch)", c)
        try r.git(r.main, "merge", "-q", "--ff-only", c)
        try r.git(r.main, "switch", "-q", "other")
        #expect(SafeMerge.recover(a, git: CheckpointTests.run) == .landedElsewhere(["main"], stash: nil))
        #expect(r.refs.isEmpty && FileManager.default.fileExists(atPath: a.folder.path))
        // Вернулись на main: «Слить» только убирает worktree, нового коммита нет.
        try r.git(r.main, "switch", "-q", "main")
        #expect(landed(merge(a)) && r.head == c)
    }

    /// Коммит готов, но main ещё не сдвинут; потом — сдвинут; правки остались в stash.
    @Test func recoverDuringLanding() throws {
        let r = try Repo()
        let a = try r.branch("a", ["a.txt": "a"])
        let c = try r.git(r.main, "commit-tree", "-p", "HEAD", "-p", a.branch, "-m", "c", "\(a.branch)^{tree}")
        func die() throws {
            try r.git(r.main, "update-ref", "refs/tracktasks/merge-start/\(a.branch)", "main~0")
            try r.git(r.main, "update-ref", "refs/tracktasks/merge-land/\(a.branch)", c)
        }
        try die()
        #expect(SafeMerge.recover(a, git: CheckpointTests.run) == .interrupted(stash: nil))
        try die()
        try r.put("local.txt", "правка\n")
        let label = "TrackTasks: правки перед слиянием \(a.branch)"
        try r.git(r.main, "stash", "push", "-q", "-m", label)
        try r.git(r.main, "merge", "-q", "--ff-only", c)
        #expect(SafeMerge.recover(a, git: CheckpointTests.run) == .landed(stash: label))
        #expect(try r.git(r.main, "stash", "list").contains(label))
        #expect(r.refs.isEmpty)
    }
}
