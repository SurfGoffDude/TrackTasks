import Foundation
import TrackTasksCore

/// Worktrees removed and kept together: of one task, or of one lost task.
@MainActor struct CleanupGroup: Identifiable {
    var infos: [Worktrees.Info]
    /// Every job that works in them.
    var jobs: [Job]
    nonisolated let id: String
    var title: String { jobs.first?.title ?? "" }
    var project: String { jobs.first?.projectName ?? infos.first?.main.lastPathComponent ?? "" }
    var paths: Set<String> { Set(infos.map(\.path.path)) }
}

/// A group with everything known about it.
struct CleanupItem: Identifiable {
    var group: CleanupGroup
    var state: WorktreeCleanup.Group
    var verdict: WorktreeCleanup.Verdict
    var id: String { group.id }
}

struct CleanupPreview: Identifiable, Sendable {
    var id: String { info.id }
    var info: Worktrees.Info
    var uncommitted: [String] = []
    var ignored: [String] = []
    /// `.worktreeinclude` copies: ignored too, but can be taken from the main folder again.
    var copies: [String] = []
    var error = ""
}

extension JobQueue {
    nonisolated static let cleanupMaxKey = "worktreeCleanupMax"
    nonisolated static let cleanupDaysKey = "worktreeCleanupDays"
    static var cleanupSettings: WorktreeCleanup.Settings {
        .init(maxCount: UserDefaults.standard.integer(forKey: cleanupMaxKey), maxAgeDays: UserDefaults.standard.integer(forKey: cleanupDaysKey))
    }

    // MARK: Pins

    private struct Pins: Codable { var pinned: [String] }

    static func loadPins(_ url: URL) -> Set<String>? {
        if let p = StorageIssues.shared.load(Pins.self, from: url, decoder: JSONDecoder()) { return Set(p.pinned) }
        // A damaged file was set aside, now or earlier.
        return FileManager.default.fileExists(atPath: url.path) || hasDamagedCopy(url) ? nil : []
    }

    private static func hasDamagedCopy(_ url: URL) -> Bool {
        let start = url.deletingPathExtension().lastPathComponent + ".corrupt-"
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []).contains { $0.hasPrefix(start) }
    }

    func pin(_ paths: Set<String>, _ on: Bool) {
        var all = pinnedWorktrees ?? []
        if on { all.formUnion(paths) } else { all.subtract(paths) }
        pinnedWorktrees = all
        do { StorageIssues.shared.save(try JSONEncoder().encode(Pins(pinned: all.sorted())), to: pinsURL) }
        catch { StorageIssues.shared.report("Закрепления worktree не записаны: \(error.localizedDescription)") }
    }

    // MARK: Groups and facts

    func cleanupGroups() async -> [CleanupGroup] {
        let root = worktreesRoot
        let disk = await Task.detached(priority: .utility) { Worktrees.scan(root: root) }.value
        return cleanupGroups(disk)
    }

    /// Follow-ups share the worktree of their task; a worktree whose job lost it (or is just creating it) is found by the id.
    func cleanupGroups(_ disk: [Worktrees.Info]) -> [CleanupGroup] {
        var out: [(infos: [Worktrees.Info], jobs: [Job], ids: Set<String>)] = []
        func join(_ infos: [Worktrees.Info], _ job: Job?, _ ids: Set<String>) {
            var mine = (infos: infos, jobs: job.map { [$0] } ?? [], ids: ids)
            let paths = Set(infos.map(\.path.path))
            var rest: [(infos: [Worktrees.Info], jobs: [Job], ids: Set<String>)] = []
            for g in out {
                guard !g.ids.isDisjoint(with: mine.ids) || g.infos.contains(where: { paths.contains($0.path.path) }) else { rest.append(g); continue }
                mine.infos = g.infos + mine.infos.filter { i in !g.infos.contains { $0.path.path == i.path.path } }
                mine.jobs = g.jobs + mine.jobs
                mine.ids.formUnion(g.ids)
            }
            out = rest + [mine]
        }
        func short(_ j: Job) -> String { "job " + j.id.uuidString.prefix(6).lowercased() }
        for j in jobs {
            let infos = j.members.compactMap(\.worktree)
            if !infos.isEmpty { join(infos, j, [short(j)]) }
        }
        // The disk may name the same folder differently.
        let owned = Set(out.flatMap { $0.infos.map { TaskRepos.canonical($0.path) } })
        for w in disk where !owned.contains(TaskRepos.canonical(w.path)) {
            let name = w.path.lastPathComponent
            let job = jobs.first { short($0) == "job " + name }
            join([w], job, [job == nil ? "\(name)|\(w.branch)" : "job " + name])
        }
        return out.map { g in
            // The job itself first, not its follow-ups.
            var seen = Set<UUID>()
            let unique = g.jobs.filter { seen.insert($0.id).inserted }
            let ids = Set(unique.map(\.id))
            let sorted = unique.filter { $0.parentID.map { !ids.contains($0) } ?? true } + unique.filter { $0.parentID.map { ids.contains($0) } ?? false }
            return CleanupGroup(infos: g.infos, jobs: sorted, id: g.infos[0].path.path)
        }
    }

    /// `held`: this cleanup itself keeps the group busy.
    private func queueFacts(_ g: CleanupGroup, held: Bool) -> [String: WorktreeCleanup.Facts] {
        let ids = Set(g.jobs.map(\.id))
        let related = jobs.filter { j in
            ids.contains(j.id) || j.parentID.map(ids.contains) == true || j.forkOf.map(ids.contains) == true
        }
        let own = related.filter { ids.contains($0.id) || $0.parentID.map(ids.contains) == true }
        var f: WorktreeCleanup.Facts = [:]
        f[.working] = related.contains { $0.state == .running || creatingWorktree.contains($0.id) }
        f[.waiting] = related.contains { $0.state == .pending } || own.contains { j in
            j.awaitingPlan && j.isActive || j.questions?.waits == true || awaitsAnswers(j) || !j.permissions.isEmpty || j.answering
                || j.limitWait != nil || j.pipelineOpen || !j.replyDraft.isEmpty
        }
        let mains = g.infos.map(\.main)
        f[.busy] = (!held && (own.contains(where: \.worktreeBusy) || !busyOrphans.isDisjoint(with: g.paths)))
            || own.contains { $0.members.contains { $0.mergePhase != nil } }
            || own.contains { ciFixing.contains($0.id) }
            || mains.contains { m in
                gitBusy(around: m) || autoMerging.contains { TaskRepos.canonical(URL(fileURLWithPath: $0)) == TaskRepos.canonical(m) }
            }
        f[.rollback] = own.contains { $0.members.contains { !$0.rolledBack.isEmpty } }
        let unclaimed = RemoteCleanup.shared.works.filter { !$0.unclaimed.isEmpty }
        let t = Terminals.shared
        let tabs = t.tabs.values.joined().filter(\.isRunning)
        var out: [String: WorktreeCleanup.Facts] = [:]
        for w in g.infos {
            let path = w.path.path
            let real = TaskRepos.canonical(w.path)
            func inside(_ u: URL) -> Bool { let p = TaskRepos.canonical(u); return p == real || p.hasPrefix(real + "/") }
            var m = f
            m[.remote] = own.contains(where: \.remoteUnclaimed) || unclaimed.contains { inside(URL(fileURLWithPath: $0.folder)) }
            m[.server] = DevServers.shared.servers.contains { inside(URL(fileURLWithPath: $0.key)) && $0.value.contains(where: \.isRunning) }
            if own.contains(where: { j in t.tabs(j).contains(where: \.isRunning) }) || tabs.contains(where: { inside($0.folder) })
                || t.orphans.contains(where: { inside(URL(fileURLWithPath: $0.folder)) }) { m[.terminal] = true }
            else if !t.restoring, t.restoreFailure == nil { m[.terminal] = false }
            if let pins = pinnedWorktrees { m[.pinned] = pins.contains(path) }
            let member = own.lazy.flatMap(\.members).first { $0.worktree?.path.path == path }
            if let member { m[.openPR] = member.hasLivePR }
            out[path] = m
        }
        return out
    }

    private struct DiskFacts: Sendable {
        var facts: WorktreeCleanup.Facts = [:]
        /// true: the branch isn't on any remote.
        var local: Bool?
        var locked: Bool?
        var activity: Date?
        var inUse: Bool?
    }

    nonisolated private static func diskFacts(_ list: [Worktrees.Info]) -> [String: DiskFacts] {
        let fm = FileManager.default
        func git(_ a: [String], _ dir: URL) -> DiffReject.Output { DiffLoader.runEnv(a, in: dir, env: ["GIT_OPTIONAL_LOCKS": "0"], input: nil) }
        func line(_ o: DiffReject.Output) -> String { o.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        func modified(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        let used = ProcessTree.working(in: list.map(\.path.path))
        var out: [String: DiskFacts] = [:]
        for w in list {
            var d = DiskFacts()
            d.inUse = used.map { $0.contains(w.path.path) }
            if !w.branch.isEmpty {
                let head = git(["symbolic-ref", "--short", "-q", "HEAD"], w.path)
                if head.ok { d.facts[.offBranch] = line(head) != w.branch } else if head.status == 1 { d.facts[.offBranch] = true }
                let merged = git(["merge-base", "--is-ancestor", "refs/heads/\(w.branch)", "HEAD"], w.main)
                if merged.status == 0 || merged.status == 1 { d.facts[.unmerged] = merged.status == 1 }
                let refs = git(["for-each-ref", "--format=%(refname)", "refs/remotes/*/\(w.branch)"], w.main)
                let up = git(["config", "--get", "branch.\(w.branch).remote"], w.main)
                if refs.ok, up.status == 0 || up.status == 1 { d.local = line(refs).isEmpty && up.status == 1 }
            } else { d.facts[.offBranch] = true }
            let dir = git(["rev-parse", "--path-format=absolute", "--git-dir"], w.path)
            let marks = ["merge-start", "merge-land"].map { git(["show-ref", "--verify", "--quiet", "refs/tracktasks/\($0)/\(w.branch)"], w.main).status }
            if dir.ok, !line(dir).isEmpty {
                let gitDir = URL(fileURLWithPath: line(dir))
                let names = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "rebase-merge", "rebase-apply"]
                if names.contains(where: { fm.fileExists(atPath: gitDir.appendingPathComponent($0).path) }) || marks.contains(0) { d.facts[.unfinished] = true }
                else if marks.allSatisfy({ $0 == 1 }) { d.facts[.unfinished] = false }
                d.locked = fm.fileExists(atPath: gitDir.appendingPathComponent("locked").path)
                var dates = [modified(w.path), modified(gitDir.appendingPathComponent("logs/HEAD"))]
                // Also files edited by hand since.
                let links = Set(Worktrees.links(of: w.path))
                let edited = git(["ls-files", "--modified", "--others", "--exclude-standard", "-z"], w.path)
                if edited.ok {
                    dates += edited.out.split(separator: 0).prefix(5000).map { String(decoding: $0, as: UTF8.self) }
                        .filter { !links.contains($0) }.map { modified(w.path.appendingPathComponent($0)) }
                    d.activity = dates.compactMap { $0 }.max()
                }
            }
            out[w.path.path] = d
        }
        return out
    }

    /// A worktree nobody owns may be one that is being created right now.
    private static let freshOrphan: TimeInterval = 600

    private func state(_ g: CleanupGroup, _ disk: [String: DiskFacts], held: Bool) -> WorktreeCleanup.Group {
        let queue = queueFacts(g, held: held)
        var last: Date? = g.jobs.flatMap { [$0.created] + ($0.finishedAt.map { [$0] } ?? []) }.max()
        var members: [WorktreeCleanup.Member] = []
        var known = true
        for w in g.infos {
            let path = w.path.path
            var f = queue[path] ?? [:]
            let d = disk[path] ?? DiskFacts()
            f.merge(d.facts) { $1 }
            // PR of a branch no job knows about.
            if f[.openPR] == nil, d.local == true { f[.openPR] = false }
            if let locked = d.locked { if locked, f[.pinned] != nil { f[.pinned] = true } } else { f[.pinned] = nil }
            if f[.terminal] == false { f[.terminal] = d.inUse }
            if let a = d.activity { last = max(last ?? a, a) } else { known = false }
            if g.jobs.isEmpty, let a = d.activity, now().timeIntervalSince(a) < Self.freshOrphan, f[.pinned] == false { f[.busy] = nil }
            members.append(.init(path: path, facts: f))
        }
        return .init(members: members, activity: known ? last : nil)
    }

    private func groupState(_ g: CleanupGroup, held: Bool = false) async -> WorktreeCleanup.Group {
        let list = g.infos
        let disk = await Task.detached(priority: .utility) { Self.diskFacts(list) }.value
        return state(g, disk, held: held)
    }

    func cleanupItems(settings: WorktreeCleanup.Settings? = nil) async -> [CleanupItem] {
        let groups = await cleanupGroups()
        let all = groups.flatMap(\.infos)
        let disk = await Task.detached(priority: .utility) { Self.diskFacts(all) }.value
        let states = groups.map { state($0, disk, held: false) }
        let verdicts = WorktreeCleanup.decide(states, settings ?? Self.cleanupSettings, now: now(), queueRead: trustsQueue)
        return zip(groups, states).map { g, s in
            CleanupItem(group: g, state: s, verdict: verdicts[g.id] ?? .keep("неизвестно"))
        }.sorted { ($0.state.activity ?? .distantPast) < ($1.state.activity ?? .distantPast) }
    }

    /// Not while a damaged copy of the queue lies there: its tasks' worktrees look like nobody's.
    var trustsQueue: Bool { queueRead && !Self.hasDamagedCopy(queueFile) }

    func cleanupPreview(_ g: CleanupGroup) async -> [CleanupPreview] {
        let list = g.infos, snapshots = snapshots
        return await Task.detached(priority: .userInitiated) {
            list.map { w in
                var p = CleanupPreview(info: w)
                do {
                    p.uncommitted = try WorktreeSnapshot.uncommitted(snapshots.site(w), git: DiffLoader.runEnv)
                    p.copies = WorktreeFiles.manifest(of: w.path)?.copies ?? []
                    let copies = Set(p.copies.flatMap { [$0, $0 + "/"] })
                    p.ignored = try WorktreeSnapshot.ignored(snapshots.site(w), git: DiffLoader.runEnv).filter { !copies.contains($0) && $0 != PreviewFolder.name + "/" }
                } catch { p.error = error.localizedDescription }
                return p
            }
        }.value
    }

    nonisolated static func size(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var sum: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            sum += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return sum
    }

    // MARK: Removal

    /// The whole group with a snapshot, or nothing. Returns why not; nil = removed.
    /// `overriding`: what the person confirmed.
    func cleanUp(_ group: CleanupGroup, overriding: Set<WorktreeCleanup.Protection> = [], reason: String = "вручную") async -> String? {
        // Anything could have changed since the list was shown.
        guard let g = await cleanupGroups().first(where: { $0.id == group.id }), g.paths == group.paths else { return "Список worktree изменился — обнови" }
        func blocked(_ s: WorktreeCleanup.Group) -> String? {
            let b = WorktreeCleanup.blocks(s, overriding: overriding)
            return b.isEmpty ? nil : WorktreeCleanup.text(b)
        }
        if let why = blocked(await groupState(g)) { return why }
        // Synchronous from here to the claim.
        let now = queueFacts(g, held: false)
        for f in now.values where f[.busy] != false || f[.working] != false || f[.waiting] != false { return "Состояние задачи изменилось" }
        hold(g, true)
        defer { hold(g, false) }

        let snapshots = snapshots, infos = g.infos, title = g.title, project = g.project, date = self.now()
        func failed(_ why: String) -> String {
            Log.queue.process("worktree cleanup refused", project: project, command: why)
            return why
        }
        let made = await Task.detached(priority: .utility) {
            Result { try snapshots.prepare(infos, title: title, project: project, reason: reason, now: date) }
        }.value
        var r: RemovedWorktrees
        switch made {
        case .failure(let e): return failed("Снимок не сделан, ничего не удалено: \(e.localizedDescription)")
        case .success(let x): r = x
        }

        // Extra repositories had no setup.
        let main = g.jobs.first?.worktree
        let teardown = g.jobs.first.flatMap(dangerTeardown)
        let ready = await Task.detached(priority: .utility) { () -> String? in
            for w in infos {
                if let why = ContainerStore.shared.release(w.path) { return why }
                if main == nil || main?.path == w.path {
                    ScriptStore.teardown(w, allowed: teardown)
                    if let why = ContainerStore.shared.release(w.path) { return why }
                }
            }
            return nil
        }.value
        // teardown may have undone it.
        func giveUp(_ r: RemovedWorktrees, _ why: String) async -> String {
            for j in g.jobs { j.setupDone = false }
            await Task.detached(priority: .utility) { snapshots.putBack(r) }.value
            save()
            return failed("Не удалено: \(why)")
        }
        if let why = ready { return await giveUp(r, why) }
        if let why = blocked(await groupState(g, held: true)) { return await giveUp(r, why) }

        let start = r
        let moved = await Task.detached(priority: .utility) { () -> Result<RemovedWorktrees, Error> in
            var x = start
            return Result { try snapshots.move(&x); return x }
        }.value
        switch moved {
        case .failure(let e): return await giveUp(r, e.localizedDescription)
        case .success(let x): r = x
        }
        // Somebody came in while the folders were moved.
        let aside = r.parts.map(\.aside.path)
        let used = await Task.detached(priority: .utility) { ProcessTree.working(in: aside) }.value
        let late = queueFacts(g, held: true).values.contains { f in
            WorktreeCleanup.Protection.allCases.contains { p in
                [.unmerged, .unfinished, .offBranch, .openPR].contains(p) || overriding.contains(p) ? false : f[p] != false
            }
        }
        if used != [] || late { return await giveUp(r, "worktree снова понадобился") }

        r.stage = .removed
        do { try snapshots.save(r) } catch {
            r.stage = .moved
            return await giveUp(r, error.localizedDescription)
        }
        // No way back.
        forgetRemoved([r])
        for j in g.jobs { Terminals.shared.closeAll(j.id) }
        if pinnedWorktrees?.isDisjoint(with: g.paths) == false { pin(g.paths, false) }
        saveNow()
        let done = r
        let left = await Task.detached(priority: .utility) { () -> String? in
            do { try snapshots.finish(done); return nil } catch { return error.localizedDescription }
        }.value
        if let left { StorageIssues.shared.report("Worktree убран не до конца, продолжу при запуске: \(left)") }
        pump()
        return nil
    }

    private func hold(_ g: CleanupGroup, _ on: Bool) {
        for j in g.jobs { j.worktreeBusy = on }
        if on { busyOrphans.formUnion(g.paths) } else { busyOrphans.subtract(g.paths) }
    }

    /// The jobs have no worktree any more, like after «Удалить ветку».
    func forgetRemoved(_ list: [RemovedWorktrees]) {
        for r in list where r.stage == .removed {
            let gone = Set(r.parts.map(\.info.path.path))
            for j in jobs {
                for m in j.members {
                    guard let w = m.worktree, gone.contains(w.path.path), !WorktreeSnapshot.exists(w.path) else { continue }
                    m.worktree = nil
                    m.mergeArtifacts = []
                    if !m.merged { m.worktreeNote = "Worktree убран, снимок — в «Уборка worktree»" }
                    guard m.owner == nil else { continue }
                    m.setupDone = false
                    // The session can't be continued: its folder is gone.
                    m.interrupted = false
                    m.rewind = nil
                    m.resumeSession = nil
                    if m.state == .cancelled { m.sessionID = nil }
                }
            }
        }
    }

    // MARK: After a crash

    /// Cleanups cut off by the end of the app. What can be put back is put back at once, before anything looks for it.
    func returnWorktrees() -> [RemovedWorktrees] {
        let (items, unreadable) = snapshots.list()
        for n in unreadable { StorageIssues.shared.report("Запись об убранном worktree \(n) не читается: она и её снимок не тронуты") }
        let cut = items.filter { $0.stage != .done }
        for r in cut where r.stage != .removed { snapshots.returnFolders(r) }
        return cut
    }

    func finishCleanups(_ cut: [RemovedWorktrees]) {
        guard !cut.isEmpty else { return }
        for r in cut where r.stage != .removed {
            let paths = Set(r.parts.map(\.info.path.path))
            for j in jobs where j.worktree.map({ paths.contains($0.path.path) }) == true { j.setupDone = false }
        }
        let snapshots = snapshots
        busyOrphans.formUnion(cut.flatMap { $0.parts.map(\.info.path.path) })
        Task.detached(priority: .utility) { [weak self] in
            for r in cut {
                if r.stage == .removed { try? snapshots.finish(r) } else { snapshots.putBack(r) }
            }
            await self?.cleanupsFinished(cut)
        }
    }

    private func cleanupsFinished(_ cut: [RemovedWorktrees]) {
        busyOrphans.subtract(cut.flatMap { $0.parts.map(\.info.path.path) })
        save()
    }

    // MARK: By itself

    /// At launch and when the settings change. The timer is only for age: everything else comes with a finished job.
    func scheduleCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        expireSnapshots()
        guard Self.cleanupSettings.enabled else { return }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireSnapshots(); self?.autoCleanup() }
        }
        autoCleanup()
    }

    private func expireSnapshots() {
        let s = snapshots, days = WorktreeSnapshots.days, t = now()
        Task.detached(priority: .utility) { s.expire(days: days, now: t) }
    }

    func autoCleanup() {
        guard isReady, Self.cleanupSettings.enabled else { return }
        Task { await runCleanup(Self.cleanupSettings) }
    }

    /// One group at a time, each looked at anew. Returns what was removed.
    @discardableResult
    func runCleanup(_ settings: WorktreeCleanup.Settings) async -> [String] {
        guard settings.enabled, !cleaning, !frozen, trustsQueue, pinnedWorktrees != nil else { return [] }
        cleaning = true
        defer { cleaning = false }
        var gone: [String] = [], notes: [String] = []
        for item in await cleanupItems(settings: settings) where item.verdict.removes && cleanupFailed[item.id] == nil {
            let name = item.group.title.isEmpty ? item.group.infos[0].branch : item.group.title
            if let why = await cleanUp(item.group, reason: item.verdict.reason) {
                cleanupFailed[item.id] = why
                notes.append("\(name): \(why)")
            } else {
                gone.append(name)
            }
        }
        guard !gone.isEmpty || !notes.isEmpty else { return gone }
        cleanupNote = ([gone.isEmpty ? "" : "Убрано worktree: \(gone.joined(separator: ", "))"] + notes).filter { !$0.isEmpty }.joined(separator: "\n")
        if !gone.isEmpty, queueFile == Self.storeURL {
            Notifier.shared.post(title: "Убрано worktree: \(gone.count)", body: gone.joined(separator: ", ") + ". Снимки — в очереди, «Уборка worktree».")
        }
        return gone
    }

    // MARK: Restoring

    /// Not given to a job: appears among branches without a task, pinned.
    func restoreWorktrees(_ r: RemovedWorktrees) async -> Result<[Worktrees.Info], Error> {
        let s = snapshots, root = worktreesRoot
        // Holds a restart for an update.
        let hold = MergeToken()
        hold.begin()
        defer { hold.end() }
        let made = await Task.detached(priority: .userInitiated) { Result { try s.restore(r, root: root) } }.value
        if case .success(let list) = made { pin(Set(list.map(\.path.path)), true) }
        return made
    }
}
