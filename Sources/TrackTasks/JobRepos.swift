import Foundation
import TrackTasksCore

/// An extra repository of a task (`repos:`) as saved in queue.json. Read leniently: a value this version doesn't
/// understand must not make the whole queue unreadable.
struct RepoWork: Codable {
    var main: URL
    var worktree: Worktrees.Info?
    var baseCommit = ""
    var committed = false
    var merged = false
    var note = ""
    var diffStat = ""
    var mergeFailed = false
    var mainConflict = false
    var mergeCheck: SafeMerge.Check?
    var mergeArtifacts: [String] = []
    var pullRequest: PullRequestLink?
    var rolledBack = ""

    @MainActor init(_ p: Job) {
        main = p.cwd
        worktree = p.worktree
        baseCommit = p.baseCommit
        committed = p.committed
        merged = p.merged
        note = p.worktreeNote
        diffStat = p.diffStat
        mergeFailed = p.mergeFailed
        mainConflict = p.mainConflict
        mergeCheck = p.mergeCheck
        mergeArtifacts = p.mergeArtifacts
        pullRequest = p.pullRequest
        rolledBack = p.rolledBack
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ t: T.Type) -> T? { (try? c.decodeIfPresent(t, forKey: k)) ?? nil }
        worktree = get(.worktree, Worktrees.Info.self)
        main = get(.main, URL.self) ?? worktree?.main ?? URL(fileURLWithPath: "/")
        baseCommit = get(.baseCommit, String.self) ?? ""
        committed = get(.committed, Bool.self) ?? false
        merged = get(.merged, Bool.self) ?? false
        note = get(.note, String.self) ?? ""
        diffStat = get(.diffStat, String.self) ?? ""
        mergeFailed = get(.mergeFailed, Bool.self) ?? false
        mainConflict = get(.mainConflict, Bool.self) ?? false
        mergeCheck = get(.mergeCheck, SafeMerge.Check.self)
        mergeArtifacts = get(.mergeArtifacts, [String].self) ?? []
        pullRequest = get(.pullRequest, PullRequestLink.self)
        rolledBack = get(.rolledBack, String.self) ?? ""
    }
}

/// An array whose bad elements are dropped instead of failing the decoding.
struct LenientRepoWorks: Codable {
    var list: [RepoWork]
    private struct Any_: Decodable {}
    init(_ list: [RepoWork]) { self.list = list }
    init(from decoder: Decoder) throws {
        list = []
        guard var c = try? decoder.unkeyedContainer() else { return }
        while !c.isAtEnd {
            if let w = try? c.decode(RepoWork.self) { list.append(w) } else if (try? c.decode(Any_.self)) == nil { break }
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(list)
    }
}

/// A task on several repositories: its own fields describe the project's repository, `parts` — the others.
/// A part is a `Job` that is never in the queue: merge, pull request and diff work with it as with any branch.
extension Job {
    /// The task the part belongs to; the job itself when it isn't a part.
    var home: Job { owner ?? self }
    /// The project's repository first.
    var members: [Job] { [self] + parts }
    var isGroup: Bool { owner != nil || !parts.isEmpty }
    /// Shown next to the repository's state.
    var repoName: String { cwd.lastPathComponent }
    /// Any repository still has a worktree.
    var hasWorktree: Bool { worktree != nil || parts.contains { $0.worktree != nil } }

    /// Finished in this repository with a commit that is not merged yet.
    var ownAwaitsMerge: Bool { worktree != nil && committed && !merged }
    /// The same in any repository of the task.
    var awaitsMerge: Bool { ownAwaitsMerge || parts.contains(where: \.ownAwaitsMerge) }

    /// Every changed repository is merged.
    var fullyMerged: Bool { isGroup ? members.contains(where: \.merged) && !awaitsMerge : merged }

    /// «Слито 1 из 2 · api: конфликт», "" for one repository.
    var groupSummary: String {
        guard !parts.isEmpty else { return "" }
        let changed = members.filter { $0.committed || $0.merged }
        guard !changed.isEmpty else { return "" }
        let left = changed.filter { !$0.merged }.compactMap { m -> String? in
            let why = m.mergeFailed ? "конфликт" : m.mainConflict ? "конфликты в основной папке"
                : m.mergeCheck?.state == .red ? "проверка красная" : m.hasLivePR ? "открыт PR"
                : !m.rolledBack.isEmpty ? "откат не закоммичен" : m.worktreeNote.hasPrefix("Не слито") ? "не слито" : nil
            return why.map { "\(m.repoName): \($0)" }
        }
        return (["Слито \(changed.filter(\.merged).count) из \(changed.count)"] + left).joined(separator: " · ")
    }

    func addPart(main: URL, worktree w: Worktrees.Info?, base: String) -> Job {
        let p = Job(kind: .runTask, title: title, projectID: main.path, projectName: main.lastPathComponent, cwd: main, prompt: "",
                    systemPrompt: ClaudePrompts.codingSystem(name: main.lastPathComponent, path: main.path), taskPath: taskPath)
        p.state = .done
        p.worktree = w
        p.baseCommit = base
        p.owner = self
        parts.append(p)
        return p
    }

    func addPart(_ r: RepoWork) {
        let p = addPart(main: r.main, worktree: r.worktree, base: r.baseCommit)
        p.committed = r.committed
        p.merged = r.merged
        p.worktreeNote = r.note
        p.diffStat = r.diffStat
        p.mergeFailed = r.mergeFailed
        p.mainConflict = r.mainConflict
        p.mergeCheck = r.mergeCheck
        p.mergeArtifacts = r.mergeArtifacts
        p.pullRequest = r.pullRequest
        p.rolledBack = r.rolledBack
    }

    /// The worktrees go on with the job that replaces this one.
    func moveWorktrees(to new: Job) {
        new.worktree = worktree
        new.baseCommit = baseCommit
        new.setupDone = setupDone
        new.parts = parts
        for p in parts { p.owner = new }
        if !parts.isEmpty {
            new.committed = committed
            new.merged = merged
            new.mergeFailed = mergeFailed
            new.mergeCheck = mergeCheck
            new.mergeArtifacts = mergeArtifacts
            new.pullRequest = pullRequest
        }
        worktree = nil
        parts = []
    }
}

extension JobQueue {
    /// The task whose repositories this job works in: a review, fix or reply works in its task's.
    func group(_ job: Job) -> Job {
        let h = job.home
        return h.isFollowUp || h.kind == .review ? self.job(h.parentID) ?? h : h
    }

    /// The member of `task` with this main folder; nil path — the project's own repository.
    func member(_ task: Job, _ repo: String?) -> Job {
        guard let repo else { return task }
        return task.parts.first { $0.cwd.path == repo } ?? task
    }

    /// Project folders the job changes code in.
    func folders(_ job: Job) -> [URL] {
        let g = group(job)
        return [job.owner == nil ? job.cwd : g.cwd] + (g.parts.isEmpty ? g.repoFolders : g.parts.map(\.cwd))
    }

    /// Resolves `repos:`; a problem stops the job before anything is created.
    func resolveRepos(_ job: Job) {
        job.repoFolders = []
        job.repoProblem = ""
        guard job.kind == .runTask, !job.repos.isEmpty else { return }
        if job.mustUseMain, job.worktree == nil {
            job.repoProblem = "repos: задача на несколько репозиториев идёт только в worktree, а в ней worktree: never"
            return
        }
        if let why = remoteRefusal(job) {
            job.repoProblem = why
            return
        }
        switch TaskRepos.resolve(job.repos, root: projectsRoot(), project: job.cwd) {
        case .success(let f): job.repoFolders = f
        case .failure(let f): if job.parts.isEmpty { job.repoProblem = f.message }
        }
    }

    /// A server gets a copy of one worktree and returns only its files: the other repositories would be lost.
    func remoteRefusal(_ job: Job) -> String? {
        guard !group(job).repos.isEmpty || !group(job).parts.isEmpty,
              let id = job.agent ?? profiles().resolve(job.profile)?.agent,
              agents[id]?.capabilities.contains(.remote) == true else { return nil }
        return "repos: агент на сервере работает только с одним репозиторием — выбери локальный профиль"
    }

    /// Removes the worktrees of all repositories of a job that leaves nothing behind.
    func dropWorktrees(_ job: Job, then: @escaping @MainActor @Sendable () -> Void = {}) {
        let own = job.worktree, extra = job.parts.compactMap(\.worktree)
        job.worktree = nil
        job.parts = []
        if own != nil { previews.remove(job.id) }
        guard own != nil || !extra.isEmpty else { return then() }
        let teardown = dangerTeardown(job)
        Task.detached(priority: .utility) {
            if let own { Worktrees.remove(own, deleteBranch: true, force: true, teardown: teardown) }
            for w in extra { Worktrees.remove(w, deleteBranch: true, force: true, scripts: false) }
            await then()
        }
    }

    struct MadeWorktree: Sendable {
        var info: Worktrees.Info
        var base: String
    }

    /// Worktrees in all repositories or in none. `expected`: the folders the queue decided about.
    nonisolated static func makeGroup(cwd: URL, title: String, id: UUID, repos: [String], expected: [URL],
                                      projectsRoot: URL, worktrees: URL) -> Result<[MadeWorktree], TaskRepos.Failure> {
        let found: [URL]
        switch TaskRepos.resolve(repos, root: projectsRoot, project: cwd) {
        case .failure(let f): return .failure(f)
        case .success(let f): found = f
        }
        guard found.map(\.path) == expected.map(\.path) else { return .failure(.init("repos: папки изменились с постановки в очередь — повтори («Повторить»)")) }
        var made: [MadeWorktree] = []
        for dir in [cwd] + found {
            switch Worktrees.make(for: dir, title: title, jobID: id, root: worktrees) {
            case .success(let m): made.append(.init(info: m.0, base: m.base))
            case .failure(let f):
                for m in made { Worktrees.remove(m.info, deleteBranch: true, force: true, scripts: false) }
                return .failure(.init("Не создан worktree в «\(dir.lastPathComponent)»: \(f.message). Остальные удалены, ничего не изменено"))
            }
        }
        return .success(made)
    }

    /// Commits the extra repositories, each on its own: an error in one doesn't stop the others.
    func commitParts(of task: Job, after job: Job, _ state: Job.State) -> (changed: Bool, failed: Bool, error: String?) {
        var changed = false, failed = false, error: String?
        for p in task.parts {
            guard let w = p.worktree else { continue }
            guard state == .done else {
                if job.kind != .reply || job.sessionID != nil {
                    p.worktreeNote = "Незавершённые изменения остались в \(w.branch)"
                    if job.sessionID != nil { p.mergeArtifacts = [] }
                }
                continue
            }
            let r = Worktrees.commitAll(w, message: "TrackTasks: \(job.title)")
            guard r.ok else {
                failed = true
                error = "\(p.repoName): \(r.message)"
                p.worktreeNote = "Не удалось закоммитить: \(r.message)"
                continue
            }
            p.rolledBack = ""
            p.mergeArtifacts = []
            if r.out == "nothing" {
                if !p.committed { p.worktreeNote = "Код не изменился" }
                continue
            }
            changed = true
            p.committed = true
            p.merged = false
            p.worktreeNote = "Изменения в ветке \(w.branch)"
            if job.kind == .reply { p.mergeCheck = nil }
        }
        return (changed, failed, error)
    }

    /// The last changed repository is merged: the rest of the group (the folder of the session, unchanged
    /// repositories) goes away. What isn't committed keeps its worktree.
    func closeGroup(_ job: Job) async {
        let task = job.home
        guard !task.parts.isEmpty, task.hasWorktree, !task.awaitsMerge, task.members.contains(where: \.merged),
              !task.worktreeBusy, !task.isActive, !hasActiveChild(task) else { return }
        task.worktreeBusy = true
        Terminals.shared.closeAll(task.id)
        let teardown = dangerTeardown(task)
        for m in task.members {
            guard let w = m.worktree else { continue }
            let artifacts = m.mergeArtifacts, own = m.owner == nil
            let left = await Task.detached(priority: .utility) { () -> [String] in
                let left = SafeMerge.uncommitted(w.mergeSite, ignoring: artifacts, git: DiffLoader.runEnv)
                if left.isEmpty { Worktrees.remove(w, deleteBranch: true, force: false, teardown: teardown, scripts: own) }
                return left
            }.value
            if left.isEmpty {
                m.worktree = nil
                m.mergeArtifacts = []
            } else {
                m.worktreeNote += ". Worktree оставлен: в нём незакоммиченное — \(DirtyFiles.summary(left))"
            }
        }
        task.worktreeBusy = false
        save()
    }
}

extension ClaudePrompts {
    /// «репозиторий → папка → ветка» for an agent that works in several repositories.
    @MainActor static func reposSystem(_ task: Job) -> String {
        let live = task.members.filter { $0.worktree != nil }
        let rows = live.map { "- \($0.repoName) → \($0.worktree!.path.path) → ветка \($0.worktree!.branch) (исходная папка \($0.cwd.path))" }
        let merged = task.parts.filter { $0.worktree == nil }.map { "- \($0.repoName) — уже слит, не меняй" }
        return """


        ЗАДАЧА НА НЕСКОЛЬКО РЕПОЗИТОРИЕВ. Репозиторий → папка → ветка:
        \((rows + merged).joined(separator: "\n"))
        Код меняй только в этих папках; исходные папки репозиториев не трогай. Коммитить не нужно: трекер закоммитит каждый репозиторий отдельно.
        """
    }

    static func reposPlanning(_ folders: [URL]) -> String {
        "\n\nЗадача затрагивает и другие репозитории (только чтение): " + folders.map(\.path).joined(separator: ", ")
            + ". В плане укажи, что меняется в каждом."
    }

    /// Where else to look for the task's changes.
    @MainActor static func reposDiff(_ task: Job) -> String {
        let lines = task.parts.compactMap { p in
            p.worktree.map { "- \(p.repoName): `git -C '\($0.path.path)' diff \(p.baseCommit.prefix(12))..HEAD`" }
        }
        return lines.isEmpty ? "" : "\nЗадача меняет и другие репозитории, проверь их тоже (в замечаниях указывай репозиторий):\n" + lines.joined(separator: "\n")
    }

    static func inRepo(_ name: String, _ folder: String) -> String {
        "Репозиторий «\(name)», его worktree — \(folder). Команды выполняй там (`git -C '\(folder)' …`), остальные репозитории задачи не меняй.\n\n"
    }
}
