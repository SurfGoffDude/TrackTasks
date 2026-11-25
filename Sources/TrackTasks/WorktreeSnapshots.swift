import Foundation
import TrackTasksCore

/// A removed task: what its worktrees were and the snapshots to bring them back from. Written before anything is deleted.
struct RemovedWorktrees: Codable, Identifiable, Equatable, Sendable {
    /// prepared: snapshots exist, nothing is moved for sure. moved: all folders are aside, they can be put back.
    /// removed: no way back, what is left has to be deleted. done: only the snapshots are left.
    enum Stage: String, Codable, Sendable { case prepared, moved, removed, done }

    struct Part: Codable, Equatable, Sendable {
        var info: Worktrees.Info
        /// Where the folder waits for deletion.
        var aside: URL
        var snapshot: WorktreeSnapshot.Saved
        var container: Bool
        /// Names only: these files are not in the snapshot.
        var ignored: [String]
        var ignoredCount: Int
    }

    var id = UUID()
    var title: String
    var project: String
    var date: Date
    var reason: String
    var stage = Stage.prepared
    var parts: [Part]
    var label: String { title.isEmpty ? (parts.first?.info.branch ?? "") : title }
}

/// Manifests of removed worktrees, one file each. Any thread.
final class WorktreeSnapshots: @unchecked Sendable {
    typealias Failure = WorktreeSnapshot.Failure
    static let daysKey = "worktreeSnapshotDays"
    /// 0 = never delete.
    static var days: Int { UserDefaults.standard.object(forKey: daysKey) as? Int ?? 30 }
    static let asidePrefix = ".tt-removing-"
    static let lockReason = "tracktasks-cleanup"
    static let maxListed = 200

    let folder: URL
    private let lock = NSLock()
    /// One change of manifests or restoring at a time.
    private let work = NSLock()
    private let git: WorktreeSnapshot.Runner = DiffLoader.runEnv
    /// Tests: a failure of writing.
    var saveFailure: ((RemovedWorktrees) -> Error?)?

    init(folder: URL) { self.folder = folder }

    private func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    /// Unreadable files are left alone.
    func list() -> (items: [RemovedWorktrees], unreadable: [String]) {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var items: [RemovedWorktrees] = [], bad: [String] = []
        for u in names where u.pathExtension == "json" && UUID(uuidString: u.deletingPathExtension().lastPathComponent) != nil {
            if let d = try? Data(contentsOf: u), let r = try? dec.decode(RemovedWorktrees.self, from: d) { items.append(r) }
            else { bad.append(u.lastPathComponent) }
        }
        return (items.sorted { $0.date > $1.date }, bad.sorted())
    }

    func save(_ r: RemovedWorktrees) throws {
        if let e = saveFailure?(r) { throw e }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try lock.withLock { _ = try SafeJSON.save(try enc.encode(r), to: file(r.id)) }
    }

    private func drop(_ id: UUID) throws {
        try lock.withLock {
            let f = file(id), bak = SafeJSON.sibling(f, suffix: "bak", now: Date())
            if WorktreeSnapshot.exists(bak) { try FileManager.default.removeItem(at: bak) }
            if WorktreeSnapshot.exists(f) { try FileManager.default.removeItem(at: f) }
        }
    }

    /// The refs (only while they are what was written), then the manifest. An error keeps the manifest.
    func delete(_ r: RemovedWorktrees) throws {
        work.lock(); defer { work.unlock() }
        // A cleanup that is going on or was cut off still needs it.
        guard r.stage == .done else { throw Failure("Уборка ещё не закончена") }
        for p in r.parts where WorktreeSnapshot.exists(p.info.main) { try WorktreeSnapshot.delete(p.snapshot, in: p.info.main, git: git) }
        try drop(r.id)
    }

    /// A cleanup that was given up.
    func forget(_ r: RemovedWorktrees) {
        for p in r.parts { try? WorktreeSnapshot.delete(p.snapshot, in: p.info.main, git: git) }
        try? drop(r.id)
    }

    func expire(days: Int, now: Date) {
        guard days > 0 else { return }
        for r in list().items where r.stage == .done && now.timeIntervalSince(r.date) > Double(days) * 86400 { try? delete(r) }
    }

    /// In the main folder, without its hooks.
    @discardableResult private func run(_ args: [String], _ main: URL) -> DiffReject.Output {
        git(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + args, main, [:], nil)
    }

    // MARK: Removal

    func site(_ w: Worktrees.Info) -> WorktreeSnapshot.Site {
        .init(folder: w.path, branch: w.branch, links: Set(Worktrees.links(of: w.path)))
    }

    /// Snapshots of all worktrees and the manifest, or nothing.
    func prepare(_ list: [Worktrees.Info], title: String, project: String, reason: String, now: Date) throws -> RemovedWorktrees {
        var r = RemovedWorktrees(title: title, project: project, date: now, reason: reason, parts: [])
        do {
            for (n, w) in list.enumerated() {
                let s = site(w)
                let saved = try WorktreeSnapshot.create(s, id: r.id.uuidString.lowercased(), number: n + 1, git: git)
                r.parts.append(.init(info: w, aside: w.path.deletingLastPathComponent()
                    .appendingPathComponent(Self.asidePrefix + r.id.uuidString.prefix(8) + "-" + w.path.lastPathComponent),
                    snapshot: saved, container: ContainerStore.shared.isContainer(w.path), ignored: [], ignoredCount: 0))
                let ignored = try WorktreeSnapshot.ignored(s, git: git)
                r.parts[n].ignored = Array(ignored.prefix(Self.maxListed))
                r.parts[n].ignoredCount = ignored.count
            }
            try save(r)
        } catch {
            forget(r)
            throw error
        }
        return r
    }

    /// Nothing has changed since the snapshots; then all folders go aside. An error puts everything back.
    func move(_ r: inout RemovedWorktrees) throws {
        do {
            for p in r.parts where try !WorktreeSnapshot.matches(site(p.info), p.snapshot, git: git) {
                throw Failure("\(p.info.branch) изменилась после снимка")
            }
            for p in r.parts {
                // Keeps the record from «git worktree prune» while the folder is aside.
                let o = run(["worktree", "lock", "--reason", Self.lockReason, p.info.path.path], p.info.main)
                guard o.ok else { throw Failure(o.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
                try FileManager.default.moveItem(at: p.info.path, to: p.aside)
            }
            r.stage = .moved
            try save(r)
        } catch {
            putBack(r)
            throw error
        }
    }

    /// Folders only: quick, also at launch.
    func returnFolders(_ r: RemovedWorktrees) {
        for p in r.parts where WorktreeSnapshot.exists(p.aside) && !WorktreeSnapshot.exists(p.info.path) {
            do { try FileManager.default.moveItem(at: p.aside, to: p.info.path) } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    StorageIssues.shared.report("Worktree \(p.info.branch) не возвращён на место: он лежит в \(p.aside.path)")
                } }
            }
        }
    }

    /// The manifest and the snapshots stay while a folder isn't back.
    func putBack(_ r: RemovedWorktrees) {
        returnFolders(r)
        for p in r.parts where WorktreeSnapshot.exists(p.info.path) {
            unlock(p)
            _ = run(["worktree", "repair", p.info.path.path], p.info.main)
        }
        guard !r.parts.contains(where: { WorktreeSnapshot.exists($0.aside) }) else { return }
        if r.parts.allSatisfy({ WorktreeSnapshot.exists($0.info.path) }) { return forget(r) }
        // Somebody else deleted a folder: its snapshot is all there is.
        var kept = r
        kept.stage = .done
        try? save(kept)
    }

    /// Only our lock.
    private func unlock(_ p: RemovedWorktrees.Part) {
        let o = run(["worktree", "list", "--porcelain", "-z"], p.info.main)
        let path = TaskRepos.canonical(p.info.path)
        // Records are divided by an empty field.
        for rec in o.text.components(separatedBy: "\0\0") {
            let f = rec.components(separatedBy: "\0")
            guard let w = f.first(where: { $0.hasPrefix("worktree ") })?.dropFirst(9), f.contains("locked \(Self.lockReason)"),
                  String(w) == path || String(w) == p.info.path.path else { continue }
            _ = run(["worktree", "unlock", p.info.path.path], p.info.main)
        }
    }

    /// After stage `removed`; can be repeated.
    func finish(_ removed: RemovedWorktrees) throws {
        var r = removed
        for p in r.parts {
            if WorktreeSnapshot.exists(p.aside) { try FileManager.default.removeItem(at: p.aside) }
            guard !WorktreeSnapshot.exists(p.info.path), WorktreeSnapshot.exists(p.info.main) else { continue }
            // Twice: it is locked.
            _ = run(["worktree", "remove", "--force", "--force", p.info.path.path], p.info.main)
            Checkpoints.removeAll(branch: p.info.branch, in: p.info.main, git: git)
            _ = run(["update-ref", "-d", "refs/heads/\(p.info.branch)", p.snapshot.head], p.info.main)
            _ = run(["config", "--remove-section", "branch.\(p.info.branch)"], p.info.main)
            ContainerStore.shared.forget(p.info.path)
            RemoteCleanup.shared.release(folder: p.info.path)
        }
        r.stage = .done
        try save(r)
    }

    // MARK: Restoring

    /// New folders and branches next to what exists now; all repositories or none.
    func restore(_ r: RemovedWorktrees, root: URL) throws -> [Worktrees.Info] {
        work.lock(); defer { work.unlock() }
        guard r.stage == .done else { throw Failure("Уборка ещё не закончена") }
        for p in r.parts where !WorktreeSnapshot.exists(p.info.main) { throw Failure("Нет папки \(p.info.main.path)") }
        var targets: [Worktrees.Info] = []
        for n in 1...1000 {
            targets = r.parts.map { p in
                let dir = root.appendingPathComponent(p.info.path.deletingLastPathComponent().lastPathComponent)
                return .init(path: dir.appendingPathComponent("\(p.info.path.lastPathComponent)-r\(n)"), main: p.info.main,
                             branch: n == 1 ? p.info.branch : "\(p.info.branch)-r\(n)")
            }
            let taken = try targets.contains { t in
                try WorktreeSnapshot.exists(t.path) || WorktreeSnapshot.branchExists(t.branch, in: t.main, git: git)
            }
            if !taken { break }
            targets = []
        }
        guard !targets.isEmpty else { throw Failure("Не нашлось свободного имени") }
        var made: [(Worktrees.Info, RemovedWorktrees.Part)] = []
        do {
            for (t, p) in zip(targets, r.parts) {
                try WorktreeSnapshot.restore(p.snapshot, main: t.main, to: t.path, branch: t.branch, git: git) {
                    // Before any file of the agent is there.
                    if p.container { try ContainerStore.shared.mark(t) }
                }
                made.append((t, p))
            }
        } catch {
            for (t, p) in made { WorktreeSnapshot.undo(p.snapshot, main: t.main, folder: t.path, branch: t.branch, git: git) }
            for t in targets where !WorktreeSnapshot.exists(t.path) { ContainerStore.shared.forget(t.path) }
            throw error
        }
        for (t, p) in made where !p.container {
            Worktrees.linkDependencies(from: t.main, to: t.path)
            Worktrees.putProjectFiles(from: t.main, to: t.path)
        }
        return targets
    }
}
