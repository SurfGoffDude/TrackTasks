import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// Cleanup of real worktrees in a temporary projects root.
@MainActor @Suite(.serialized) struct JobQueueCleanupTests {
    let base: URL, root: URL, app: URL, api: URL, wts: URL
    let store: URL
    let fm = FileManager.default
    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tt-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        base = URL(fileURLWithPath: TaskRepos.canonical(tmp))
        root = base.appendingPathComponent("Projects")
        app = root.appendingPathComponent("app")
        api = root.appendingPathComponent("api")
        wts = base.appendingPathComponent("worktrees")
        store = base.appendingPathComponent("queue.json")
        for d in [app, api] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            git("init", "-q", "-b", "main", at: d)
            for (k, v) in ["user.name": "t", "user.email": "t@t", "commit.gpgsign": "false"] { git("config", k, v, at: d) }
            try write("1\n", d, "f.txt")
            try write("gone\n", d, "g.txt")
            try write("*.log\n", d, ".gitignore")
            git("add", "-A", at: d)
            git("commit", "-q", "-m", "base", at: d)
        }
    }
    @discardableResult private func git(_ args: String..., at dir: URL) -> String {
        let r = Worktrees.git(args, in: dir)
        #expect(r.ok, "\(args): \(r.err)")
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func write(_ text: String, _ dir: URL, _ name: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private func read(_ dir: URL, _ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    private func wait(_ until: () -> Bool) async throws {
        for _ in 0..<200 where !until() { try await Task.sleep(for: .milliseconds(50)) }
        try #require(until())
    }
    private func queue(now: Date = Date()) -> JobQueue {
        let r = root
        return JobQueue(storeURL: store, agents: AgentRegistry([FakeAgent()]), profiles: { AgentProfiles(custom: [], defaultID: "") },
                        dangerMode: { DangerMode() }, projectsRoot: { r }, worktreesRoot: wts, now: { now }, recordSpend: { _, _, _, _ in })
    }
    /// A finished task with worktrees, nothing committed.
    private func task(_ q: JobQueue, repos: [String] = []) throws -> Job {
        let j = Job(kind: .runTask, title: "Задача", projectID: nil, projectName: "app", cwd: app, prompt: "", systemPrompt: "")
        j.state = .done
        j.finishedAt = Date()
        let made = try JobQueue.makeGroup(cwd: app, title: "t", id: j.id, repos: repos, expected: repos.map { _ in URL(fileURLWithPath: TaskRepos.canonical(api)) },
                                          projectsRoot: root, worktrees: wts).get()
        j.worktree = made[0].info
        j.baseCommit = made[0].base
        for m in made.dropFirst() { _ = j.addPart(main: m.info.main, worktree: m.info, base: m.base) }
        q.jobs.append(j)
        return j
    }
    private func group(_ q: JobQueue) async throws -> CleanupGroup { try #require(await q.cleanupGroups().first) }
    private func facts(_ q: JobQueue) async throws -> CleanupItem { try #require(await q.cleanupItems(settings: .init(maxAgeDays: 1)).first) }
    private func edit(_ w: URL) throws {
        try write("правка\n", w, "f.txt")
        try fm.removeItem(at: w.appendingPathComponent("g.txt"))
        try write("новый\n", w, "n.txt")
        try write("log\n", w, "x.log")
    }
    private func edited(_ w: URL) -> Bool { read(w, "f.txt") == "правка\n" && read(w, "g.txt") == nil && read(w, "n.txt") == "новый\n" }
    private func refs(_ d: URL) -> String { git("for-each-ref", "--format=%(refname)", "refs/tracktasks", at: d) }
    private func why(_ q: JobQueue) async throws -> String? { await q.cleanUp(try group(q)) }
    /// Nothing happened to any worktree of the task.
    private func intact(_ j: Job, _ paths: [URL]) {
        #expect(j.members.compactMap(\.worktree).map(\.path) == paths && !j.worktreeBusy)
        for (m, p) in zip(j.members, paths) {
            #expect(edited(p))
            #expect(read(p, "x.log") == "log\n")
            #expect(git("branch", "--show-current", at: p) == m.worktree?.branch)
            #expect(!git("worktree", "list", "--porcelain", at: m.cwd).contains("locked"))
            #expect(refs(m.cwd).isEmpty)
        }
        #expect(try! fm.contentsOfDirectory(atPath: paths[0].deletingLastPathComponent().path).count == 1)
    }

    @Test func removesAndRestores() async throws {
        let q = queue(), j = try task(q)
        let w = try #require(j.worktree)
        try edit(w.path)
        try Checkpoints.create(.init(folder: w.path, branch: w.branch), .init(kind: .turn, label: "ход"), git: DiffLoader.runEnv)
        let p = try #require(await q.cleanupPreview(group(q)).first)
        #expect(Set(p.uncommitted) == ["f.txt", "g.txt", "n.txt"] && p.ignored == ["x.log"])
        do { let w = try await why(q); #expect(w == nil) }
        #expect(j.worktree == nil && !j.worktreeBusy && !fm.fileExists(atPath: w.path.path))
        #expect(git("branch", "--list", "tracktasks/*", at: app).isEmpty && git("worktree", "list", at: app).split(separator: "\n").count == 1)
        let r = try #require(q.snapshots.list().items.first)
        #expect(r.stage == .done && r.parts[0].ignored == ["x.log"])
        // Checkpoints are gone, the snapshot isn't.
        #expect(refs(app) == r.parts[0].snapshot.ref)

        git("branch", w.branch, at: app)
        let back = try #require(try await q.restoreWorktrees(r).get().first)
        #expect(edited(back.path) && read(back.path, "x.log") == nil && back.branch != w.branch && back.path != w.path)
        let orphans = await q.orphanWorktrees()
        #expect(q.pinnedWorktrees == [back.path.path] && orphans.map(\.branch) == [back.branch])
        #expect(try await facts(q).verdict == .keep("закреплён"))
        let again = try await q.restoreWorktrees(r).get()
        #expect(again[0].path != back.path && edited(back.path))

        try q.snapshots.delete(r)
        #expect(q.snapshots.list().items.isEmpty && refs(app).isEmpty)
        #expect(JobQueue.loadPins(q.pinsURL)?.count == 2)
    }

    @Test func missingFolderIsForgottenAndTheBranchStays() async throws {
        let q = queue(), j = try task(q)
        let w = try #require(j.worktree)
        #expect(await q.forgetMissing(try group(q)) != nil && j.worktree != nil)
        try fm.removeItem(at: w.path)
        let g = try await group(q)
        #expect(await q.damagedState(g)?.damage == .folderGone)
        j.state = .running
        #expect(await q.forgetMissing(g) != nil && j.worktree != nil)
        j.state = .done
        #expect(await q.forgetMissing(g) == nil && j.worktree == nil)
        git("rev-parse", "--verify", "refs/heads/\(w.branch)", at: app)
        #expect(await q.cleanupGroups().isEmpty)
    }

    @Test func orphanWithoutARepository() async throws {
        let q = queue(), j = try task(q)
        let w = try #require(j.worktree)
        // Repository alive: the usual removal only.
        #expect(await q.damagedState(try group(q)) == nil)
        #expect(await q.trashOrphan(try group(q)) != nil)
        try fm.moveItem(at: app, to: base.appendingPathComponent("moved"))
        // Its task protects it, so does a pin.
        #expect(await q.damagedState(try group(q))?.damage == .mainGone)
        #expect(await q.trashOrphan(try group(q)) == "У папки есть задача")
        q.jobs = []
        q.pin([w.path.path], true)
        #expect(await q.trashOrphan(try group(q)) == "Закреплён")
        #expect(fm.fileExists(atPath: w.path.path))
    }

    /// A queue of a test must not put worktrees among the real ones.
    @Test func ownStoreOwnWorktrees() {
        let q = JobQueue(storeURL: store, agents: AgentRegistry([FakeAgent()]), dangerMode: { DangerMode() }, recordSpend: { _, _, _, _ in })
        #expect(q.worktreesRoot.path == wts.path)
    }

    @Test func eachProtection() async throws {
        let q = queue(), j = try task(q)
        let w = try #require(j.worktree)
        func blocked(_ p: WorktreeCleanup.Protection, known: Bool = true, _ what: Comment = "") async throws {
            let b = WorktreeCleanup.blocks(try await facts(q).state)
            #expect(b == [.init(protection: p, known: known)], "\(p.rawValue) \(what) got \(b)")
            #expect(await q.cleanUp(try group(q)) != nil)
            #expect(fm.fileExists(atPath: w.path.path))
        }
        #expect(WorktreeCleanup.blocks(try await facts(q).state).isEmpty)
        j.state = .running; try await blocked(.working); j.state = .done
        j.state = .pending; try await blocked(.waiting); j.state = .done
        j.replyDraft = "текст"; try await blocked(.waiting, "черновик"); j.replyDraft = ""
        j.questions = JobQuestions(open: [.init(text: "?")]); try await blocked(.waiting, "вопрос"); j.questions = nil
        let child = Job(kind: .review, title: "r", projectID: nil, projectName: "app", cwd: app, prompt: "", systemPrompt: "")
        child.parentID = j.id
        child.state = .running
        q.jobs.append(child); try await blocked(.working, "ревью"); q.jobs.removeAll { $0 === child }
        j.worktreeBusy = true; try await blocked(.busy); j.worktreeBusy = false
        q.gitBusy = [app.path]; try await blocked(.busy, "git"); q.gitBusy = []
        j.rolledBack = "№1"; try await blocked(.rollback); j.rolledBack = ""
        q.pin([w.path.path], true); try await blocked(.pinned); q.pin([w.path.path], false)
        q.pinnedWorktrees = nil; try await blocked(.pinned, known: false); q.pinnedWorktrees = []
        let remote = RemoteRun(server: RemoteServer(host: "h"), id: "run", work: "w", project: "p")
        j.remote = remote; try await blocked(.remote); j.remote = nil

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        p.currentDirectoryURL = w.path
        try p.run()
        try await blocked(.terminal)
        p.terminate()
        p.waitUntilExit()

        git("update-ref", "refs/tracktasks/merge-start/\(w.branch)", "HEAD", at: app)
        try await blocked(.unfinished)
        git("update-ref", "-d", "refs/tracktasks/merge-start/\(w.branch)", at: app)

        try write("2\n", w.path, "f.txt")
        git("commit", "-qam", "работа", at: w.path)
        try await blocked(.unmerged)
        git("checkout", "-q", "--detach", at: w.path)
        let detached = WorktreeCleanup.blocks(try await facts(q).state).map(\.protection)
        #expect(detached.contains(.offBranch))
        git("checkout", "-q", w.branch, at: w.path)
        // Confirmed by the person: the commits are in the snapshot.
        #expect(await q.cleanUp(try group(q), overriding: [.unmerged]) == nil)
        let back = try await q.restoreWorktrees(try #require(q.snapshots.list().items.first)).get()
        #expect(git("log", "-1", "--format=%s", at: back[0].path) == "работа")
    }

    @Test func serverProtects() async throws {
        let q = queue(), j = try task(q)
        let w = try #require(j.worktree)
        DevServers.shared.start([RunCommand(name: "s", command: "sleep 60")], in: w.path, main: app)
        #expect(WorktreeCleanup.blocks(try await facts(q).state).contains(.init(protection: .server, known: true)))
        DevServers.stopAndWait(folder: w.path)
        try await wait { !DevServers.shared.isRunning(in: w.path) }
        #expect(WorktreeCleanup.blocks(try await facts(q).state).isEmpty)
    }

    @Test func openPRProtects() async throws {
        let q = queue(), j = try task(q, repos: ["api"])
        let pr = PullRequest(number: 1, url: "u")
        j.parts[0].pullRequest = PullRequestLink(pr: pr, remote: "origin", pushedOid: "x")
        #expect(WorktreeCleanup.blocks(try await facts(q).state) == [.init(protection: .openPR, known: true)])
    }

    /// A branch without a task that is on a remote may have a PR.
    @Test func orphans() async throws {
        let late = Date().addingTimeInterval(86400 * 3)
        let q = queue(now: late), j = try task(q)
        let w = try #require(j.worktree)
        q.jobs = []
        #expect(try await facts(q).verdict.removes)
        git("update-ref", "refs/remotes/origin/\(w.branch)", "HEAD", at: app)
        #expect(WorktreeCleanup.blocks(try await facts(q).state) == [.init(protection: .openPR, known: false)])
        git("update-ref", "-d", "refs/remotes/origin/\(w.branch)", at: app)
        q.busyOrphans = [w.id]
        #expect(WorktreeCleanup.blocks(try await facts(q).state) == [.init(protection: .busy, known: true)])
        q.busyOrphans = []
        #expect(await q.runCleanup(.init()).isEmpty)
        #expect(await q.runCleanup(.init(maxAgeDays: 1)) == [w.branch])
        #expect(!fm.fileExists(atPath: w.path.path))
        // Just made: somebody may be about to take it.
        let fresh = queue(), k = try task(fresh)
        fresh.jobs = []
        #expect(WorktreeCleanup.blocks(try await facts(fresh).state).map(\.protection) == [.busy])
        #expect(k.worktree != nil)
    }

    @Test func unreadableQueueKeepsAll() async throws {
        try write("не json", base, "queue.json")
        let late = Date().addingTimeInterval(86400 * 3)
        let q = queue(now: late), j = try task(q)
        #expect(!q.queueRead)
        #expect(await q.runCleanup(.init(maxAgeDays: 1)).isEmpty)
        // Also after a restart: the damaged copy still lies there.
        let next = queue(now: late)
        next.jobs = []
        #expect(next.queueRead)
        #expect(await next.runCleanup(.init(maxAgeDays: 1)).isEmpty)
        #expect(fm.fileExists(atPath: try #require(j.worktree).path.path))
    }

    @Test func groupIsRemovedAndRestoredWhole() async throws {
        let q = queue(), j = try task(q, repos: ["api"])
        let paths = j.members.compactMap { $0.worktree?.path }
        for p in paths { try edit(p) }
        do { let w = try await why(q); #expect(w == nil) }
        #expect(paths.count == 2 && !j.hasWorktree && !paths.contains { fm.fileExists(atPath: $0.path) })
        let r = try #require(q.snapshots.list().items.first)
        // One repository can't be restored: none is.
        git("update-ref", "-d", r.parts[1].snapshot.ref, at: api)
        #expect(throws: (any Error).self) { try q.snapshots.restore(r, root: wts) }
        #expect(Worktrees.scan(root: wts).isEmpty && git("branch", "--list", "tracktasks/*", at: app).isEmpty)
        git("update-ref", r.parts[1].snapshot.ref, r.parts[1].snapshot.oid, at: api)
        let back = try await q.restoreWorktrees(r).get()
        #expect(back.count == 2 && back.allSatisfy { edited($0.path) })
        #expect(await q.cleanupGroups().count == 1)
    }

    @Test func protectionOfOneKeepsTheGroup() async throws {
        let q = queue(), j = try task(q, repos: ["api"])
        let paths = j.members.compactMap { $0.worktree?.path }
        git("commit", "-q", "--allow-empty", "-m", "x", at: paths[1])
        #expect(await q.cleanUp(try group(q)) == "есть неслитые коммиты")
        #expect(paths.allSatisfy { fm.fileExists(atPath: $0.path) } && j.members.allSatisfy { $0.worktree != nil })
    }

    @Test func failedSnapshotKeepsTheGroup() async throws {
        let q = queue(), j = try task(q, repos: ["api"])
        let paths = j.members.compactMap { $0.worktree?.path }
        for p in paths { try edit(p) }
        git("update-index", "--skip-worktree", "f.txt", at: paths[1])
        let why = await q.cleanUp(try group(q))
        #expect(why?.contains("Снимок не сделан") == true, "\(why ?? "")")
        intact(j, paths)
        #expect(q.snapshots.list().items.isEmpty)
    }

    @Test(arguments: [RemovedWorktrees.Stage.prepared, .moved, .removed]) func failedManifestKeepsTheGroup(_ stage: RemovedWorktrees.Stage) async throws {
        let q = queue(), j = try task(q, repos: ["api"])
        let paths = j.members.compactMap { $0.worktree?.path }
        for p in paths { try edit(p) }
        q.snapshots.saveFailure = { $0.stage == stage ? CocoaError(.fileWriteOutOfSpace) : nil }
        #expect(await q.cleanUp(try group(q)) != nil)
        q.snapshots.saveFailure = nil
        intact(j, paths)
        #expect(q.snapshots.list().items.isEmpty)
        do { let w = try await why(q); #expect(w == nil) }
    }

    /// The second folder can't be moved: the first comes back.
    @Test func failedMoveKeepsTheGroup() async throws {
        let q = queue(), j = try task(q, repos: ["api"])
        let paths = j.members.compactMap { $0.worktree?.path }
        for p in paths { try edit(p) }
        let dir = paths[1].deletingLastPathComponent().path
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
        let why = await q.cleanUp(try group(q))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
        #expect(why?.hasPrefix("Не удалено") == true)
        intact(j, paths)
    }

    @Test func changeAfterSnapshotKeeps() async throws {
        let q = queue(), j = try task(q)
        let w = try #require(j.worktree)
        try edit(w.path)
        var r = try q.snapshots.prepare([w], title: "", project: "", reason: "", now: Date())
        try write("позже\n", w.path, "late.txt")
        #expect(throws: (any Error).self) { try q.snapshots.move(&r) }
        intact(j, [w.path])
        #expect(read(w.path, "late.txt") == "позже\n")
    }

    @Test(arguments: [RemovedWorktrees.Stage.prepared, .moved, .removed]) func restartInTheMiddle(_ stage: RemovedWorktrees.Stage) async throws {
        let q = queue(), j = try task(q, repos: ["api"])
        let list = j.members.compactMap(\.worktree)
        for w in list { try edit(w.path) }
        q.saveNow()
        var r = try q.snapshots.prepare(list, title: "t", project: "app", reason: "", now: Date())
        switch stage {
        case .prepared:
            // Cut off between two folders.
            git("worktree", "lock", "--reason", WorktreeSnapshots.lockReason, list[0].path.path, at: app)
            try fm.moveItem(at: r.parts[0].info.path, to: r.parts[0].aside)
        default:
            try q.snapshots.move(&r)
            if stage == .removed { r.stage = .removed; try q.snapshots.save(r) }
        }
        let next = queue()
        let k = try #require(next.job(j.id))
        if stage == .removed {
            #expect(!k.hasWorktree)
            try await wait { next.busyOrphans.isEmpty }
            #expect(next.snapshots.list().items.map(\.stage) == [.done])
            #expect(Worktrees.scan(root: wts).isEmpty && git("branch", "--list", "tracktasks/*", at: api).isEmpty)
            #expect(try fm.contentsOfDirectory(atPath: list[0].path.deletingLastPathComponent().path).isEmpty)
            #expect(try await next.restoreWorktrees(next.snapshots.list().items[0]).get().allSatisfy { edited($0.path) })
        } else {
            #expect(list.allSatisfy { edited($0.path) })
            // `recoverMerges` at start keeps the job busy until its own check of the branches ends.
            try await wait { next.busyOrphans.isEmpty && !k.worktreeBusy }
            intact(k, list.map(\.path))
            #expect(next.snapshots.list().items.isEmpty)
        }
    }

    @Test func expiry() async throws {
        let q = queue(), j = try task(q)
        #expect(await q.cleanUp(try group(q)) == nil && j.worktree == nil)
        let s = q.snapshots
        try write("битый", s.folder, "\(UUID().uuidString).json")
        s.expire(days: 30, now: Date().addingTimeInterval(29 * 86400))
        s.expire(days: 0, now: Date().addingTimeInterval(9999 * 86400))
        #expect(s.list().items.count == 1 && s.list().unreadable.count == 1)
        s.expire(days: 30, now: Date().addingTimeInterval(31 * 86400))
        #expect(s.list().items.isEmpty && s.list().unreadable.count == 1 && refs(app).isEmpty)
    }
}
