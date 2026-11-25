import Foundation

/// Merge of a job's branch that lets only a checked result into the main folder:
/// main (M) is merged into the branch in its worktree (V), `verify` runs on V, then a merge commit with exactly
/// V's tree and parents M, V is put on main with `--ff-only`. git itself refuses when main has moved from M.
/// The caller holds the project's check lock for the whole `run`.
public enum SafeMerge {
    public typealias Output = DiffReject.Output
    public typealias Runner = Checkpoints.Runner

    public struct Site: Sendable {
        public var folder: URL
        public var main: URL
        public var branch: String
        /// Symlinked dependencies of the worktree (not code).
        public var links: Set<String>
        public init(folder: URL, main: URL, branch: String, links: Set<String> = []) {
            self.folder = folder; self.main = main; self.branch = branch; self.links = links
        }
    }

    public enum Phase: String, Sendable { case waiting, preparing, checking, landing }

    public struct VerifyResult: Sendable {
        public var ok: Bool
        public var output: String
        public var timedOut: Bool
        public init(ok: Bool, output: String = "", timedOut: Bool = false) {
            self.ok = ok; self.output = output; self.timedOut = timedOut
        }
    }

    /// What was checked and how it ended. Valid only for exactly these commits and command.
    public struct Check: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case passed, red, timedOut, unverified }
        public var state: State
        public var branchCommit: String
        public var mainCommit: String
        public var mainBranch: String
        public var command: String
        public var output: String
        /// Untracked files that appeared while `verify` ran: build leftovers, not somebody's work.
        public var artifacts: [String]
        /// The task's own check, run after `command`; nil — there was none (also records of older versions).
        public var taskCommand: String?
        /// It is the one that failed.
        public var taskFailed: Bool?
        /// What didn't pass.
        public var failedCommand: String { taskFailed == true ? taskCommand ?? command : command }
        public init(state: State, branchCommit: String, mainCommit: String, mainBranch: String, command: String,
                    output: String = "", artifacts: [String] = [], taskCommand: String? = nil, taskFailed: Bool? = nil) {
            self.state = state; self.branchCommit = branchCommit; self.mainCommit = mainCommit
            self.mainBranch = mainBranch; self.command = command; self.output = output; self.artifacts = artifacts
            self.taskCommand = taskCommand; self.taskFailed = taskFailed
        }
        /// Exactly these commands were run.
        func runs(_ cmd: String, _ task: String) -> Bool {
            TaskVerify.same(command, cmd) && TaskVerify.same(taskCommand ?? "", task)
        }
        /// Good to land without another run.
        func covers(_ v: String, _ m: String, _ branch: String, _ cmd: String, _ task: String) -> Bool {
            (state == .passed || state == .unverified) && branchCommit == v && mainCommit == m && mainBranch == branch && runs(cmd, task)
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// `note` — what happened to uncommitted edits of the main folder; `markers` — they overlap with the merge.
        case merged(commit: String, note: String, markers: Bool)
        case conflict([String])
        case red
        case timedOut
        /// Main kept moving during the checks.
        case moved
        case cancelled
        /// Uncommitted files of the main folder the branch touches, not confirmed by the user.
        case overlap([String])
        case mainConflict([String])
        case failed(String)
    }

    public struct Report: Sendable {
        public var outcome: Outcome
        /// The last check, also of earlier runs when it is still the latest.
        public var check: Check?
        /// Main commit that is now in the branch.
        public var mergedMain: String?
        /// Build leftovers of all checks so far, also of cancelled ones: pass them to the next `run`.
        public var artifacts: [String]
        public init(outcome: Outcome, check: Check?, mergedMain: String? = nil, artifacts: [String] = []) {
            self.outcome = outcome; self.check = check; self.mergedMain = mergedMain; self.artifacts = artifacts
        }
    }

    public struct Hooks {
        public var verify: (_ command: String) -> VerifyResult
        public var isCancelled: () -> Bool
        public var onPhase: (Phase) -> Void
        /// Last word before main is touched: a reason not to merge, nil = go.
        public var mayLand: () -> String?
        public init(verify: @escaping (String) -> VerifyResult, isCancelled: @escaping () -> Bool = { false },
                    onPhase: @escaping (Phase) -> Void = { _ in }, mayLand: @escaping () -> String? = { nil }) {
            self.verify = verify; self.isCancelled = isCancelled; self.onPhase = onPhase; self.mayLand = mayLand
        }
    }

    public enum Allowed: Sendable {
        case files(Set<String>)
        case any
        func rest(_ overlap: [String]) -> [String] {
            switch self {
            case .any: []
            case .files(let f): overlap.filter { !f.contains($0) }
            }
        }
    }

    public static let maxRepeats = 2

    // MARK: Run

    /// Cheap reasons not to start: unresolved conflicts in main, unconfirmed overlap with its uncommitted files.
    public static func precheck(_ s: Site, allowed: Allowed, git: @escaping Runner) -> Outcome? {
        let g = Repo(s, git)
        do {
            let stuck = try g.unmerged(s.main)
            if !stuck.isEmpty { return .mainConflict(stuck) }
            let rest = allowed.rest(try g.overlap("HEAD...refs/heads/\(s.branch)"))
            return rest.isEmpty ? nil : .overlap(rest)
        } catch { return .failed(error.localizedDescription) }
    }

    /// `taskCommand` is the task's own check ("" = none): it runs after `command`, separately, and never replaces it.
    public static func run(_ s: Site, command: String, taskCommand: String = "", known: Check? = nil, artifacts knownArtifacts: [String] = [],
                           allowed: Allowed = .files([]), git: @escaping Runner, hooks: Hooks) -> Report {
        let g = Repo(s, git)
        var artifacts = Set(knownArtifacts)
        var report = Report(outcome: .moved, check: known, artifacts: knownArtifacts)
        do {
            try g.setRef(g.startRef, try g.commit("HEAD", s.main))
            // Left over on purpose when the process dies: `recover` finds it.
            defer { g.deleteRef(g.startRef); g.deleteRef(g.landRef) }
            // Tracked or gone by now: not a leftover any more.
            func keep(_ names: Set<String>) {
                artifacts = names
                report.artifacts = names.sorted()
            }
            keep(artifacts.intersection(try g.untracked()))
            var previous: Prepared?
            for _ in 0...maxRepeats {
                if hooks.isCancelled() { report.outcome = .cancelled; return report }
                hooks.onPhase(.preparing)
                let p = try prepare(g, artifacts, after: previous)
                previous = p
                report.mergedMain = p.main
                if hooks.isCancelled() { report.outcome = .cancelled; return report }

                if let c = report.check, c.covers(p.tip, p.main, p.mainBranch, command, taskCommand) {
                    // Already checked exactly this.
                } else if command.isEmpty, taskCommand.isEmpty {
                    report.check = Check(state: .unverified, branchCommit: p.tip, mainCommit: p.main, mainBranch: p.mainBranch,
                                         command: "", artifacts: artifacts.sorted())
                } else {
                    hooks.onPhase(.checking)
                    let before = Set(try g.untracked())
                    var r = command.isEmpty ? VerifyResult(ok: true) : hooks.verify(command)
                    var taskFailed = false
                    if r.ok, !taskCommand.isEmpty, !hooks.isCancelled() {
                        r = hooks.verify(taskCommand)
                        taskFailed = !r.ok
                    }
                    let after = Set(try g.untracked())
                    keep(artifacts.intersection(after).union(after.subtracting(before)))
                    if hooks.isCancelled() { report.outcome = .cancelled; return report }
                    report.check = Check(state: r.ok ? (command.isEmpty ? .unverified : .passed) : r.timedOut ? .timedOut : .red, branchCommit: p.tip,
                                         mainCommit: p.main, mainBranch: p.mainBranch, command: command,
                                         output: r.ok ? "" : r.output, artifacts: artifacts.sorted(),
                                         taskCommand: taskCommand.isEmpty ? nil : taskCommand, taskFailed: taskFailed ? true : nil)
                    guard r.ok else { report.outcome = r.timedOut ? .timedOut : .red; return report }
                }
                do {
                    guard let done = try land(g, p, artifacts, allowed, hooks) else { continue }
                    report.outcome = done
                    if let now = try? g.untracked() { keep(artifacts.intersection(now)) }
                    return report
                } catch let e as Failure where e.staleCheck {
                    // The code in the folder is not what was checked.
                    report.check = nil
                    throw e
                }
            }
        } catch let e as Stop {
            report.outcome = e.outcome
        } catch {
            report.outcome = .failed(error.localizedDescription)
        }
        return report
    }

    // MARK: Phases

    struct Prepared { var tip: String; var main: String; var mainBranch: String }

    private static func prepare(_ g: Repo, _ artifacts: Set<String>, after previous: Prepared?) throws -> Prepared {
        let s = g.s
        try g.checkBranch()
        if g.hasMergeHead(s.folder) {
            throw Failure("В worktree не завершено слияние — закончи или отмени его в терминале")
        }
        let left = try g.worktreeDirty(artifacts)
        if !left.isEmpty {
            throw Failure("В worktree незакоммиченные правки — \(DirtyFiles.summary(left)). Ответь агенту ещё раз или закоммить их в терминале")
        }
        let stuck = try g.unmerged(s.main)
        if !stuck.isEmpty { throw Stop(.mainConflict(stuck)) }
        let m = try g.commit("HEAD", s.main), mainBranch = g.currentBranch(s.main)
        if let previous {
            guard mainBranch == previous.mainBranch else { throw Failure(switched) }
            guard g.isAncestor(previous.main, m) else {
                throw Failure("История основной ветки переписана во время проверки — слей ещё раз, если так и задумано")
            }
        }
        if !g.isAncestor(m, "refs/heads/\(s.branch)") {
            let r = g.run(["-c", "merge.autostash=false", "merge", "--ff", "--no-verify", "--no-edit", "-m",
                           "Merge \(mainBranch.isEmpty ? String(m.prefix(12)) : mainBranch) into \(s.branch)", m], s.folder)
            if !r.ok {
                let files = (try? g.unmerged(s.folder)) ?? []
                if g.hasMergeHead(s.folder) {
                    let a = g.run(["merge", "--abort"], s.folder)
                    guard a.ok else { throw Failure("Слияние в worktree не отменилось: \(Repo.message(a))") }
                    if !files.isEmpty { throw Stop(.conflict(files)) }
                }
                throw Failure("Не удалось влить основную ветку в worktree: \(Repo.message(r))")
            }
        }
        return Prepared(tip: try g.commit("refs/heads/\(s.branch)", s.main), main: m, mainBranch: mainBranch)
    }

    /// nil — main has moved, check again.
    private static func land(_ g: Repo, _ p: Prepared, _ artifacts: Set<String>, _ allowed: Allowed, _ hooks: Hooks) throws -> Outcome? {
        let s = g.s
        try g.checkBranch()
        guard try g.commit("refs/heads/\(s.branch)", s.main) == p.tip else {
            throw Failure("Ветка изменилась во время проверки — слей ещё раз", staleCheck: true)
        }
        let left = try g.worktreeDirty(artifacts)
        if !left.isEmpty {
            throw Failure("Во время проверки в worktree изменились файлы — \(DirtyFiles.summary(left)). Проверено не то, что в ветке", staleCheck: true)
        }
        guard g.currentBranch(s.main) == p.mainBranch else { throw Failure(switched) }
        if try g.commit("HEAD", s.main) != p.main { return nil }
        let stuck = try g.unmerged(s.main)
        if !stuck.isEmpty { return .mainConflict(stuck) }
        let rest = allowed.rest(try g.overlap("\(p.main)..\(p.tip)"))
        if !rest.isEmpty { return .overlap(rest) }
        if hooks.isCancelled() { return .cancelled }
        if let why = hooks.mayLand() { throw Failure(why) }
        hooks.onPhase(.landing)
        // Nothing of the branch is missing in main.
        if p.tip == p.main { return .merged(commit: p.main, note: "", markers: false) }

        let sign = g.run(["config", "--type=bool", "commit.gpgsign"], s.main).text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        let c = try g.text(["commit-tree"] + (sign ? ["-S"] : []) + ["-p", p.main, "-p", p.tip,
                            "-m", "Merge branch '\(s.branch)'", "\(p.tip)^{tree}"], s.main)
        try g.setRef(g.landRef, c)
        let ff = ["-c", "merge.autostash=false", "merge", "--ff-only", "--no-edit", c]
        var r = g.run(ff, s.main)
        var note = "", markers = false
        if !r.ok, try g.commit("HEAD", s.main) == p.main, r.err.contains("would be overwritten") {
            let stash = try g.stash()
            r = g.run(ff, s.main)
            // Always put the edits back, merged or not.
            let back = g.unstash(stash)
            let conflicts = (try? g.unmerged(s.main)) ?? []
            if back.ok {
                note = "Незакоммиченные правки в основной папке временно спрятаны и возвращены."
            } else {
                markers = !conflicts.isEmpty
                note = markers
                    ? "Твои незакоммиченные правки пересеклись с веткой — в файлах маркеры конфликта (<<<<<<<): \(DirtyFiles.summary(conflicts, limit: 8)). "
                        + "Поправь их; копия правок осталась в git stash («\(g.stashLabel)»), после проверки: git stash drop."
                    : "Твои правки не вернулись автоматически — они в git stash («\(g.stashLabel)»): git stash pop"
            }
        }
        guard r.ok else {
            if try g.commit("HEAD", s.main) != p.main, note.isEmpty || !note.contains("git stash") { return nil }
            throw Failure("Основная ветка не сдвинута: \(Repo.message(r))" + (note.isEmpty ? "" : "\n" + note))
        }
        // git can't tell that somebody switched the branch between the check above and the fast-forward.
        let now = g.currentBranch(s.main)
        if now != p.mainBranch { note = "Во время слияния в основной папке переключили ветку: слито в «\(now)», а не в «\(p.mainBranch)». " + note }
        return .merged(commit: c, note: note, markers: markers)
    }

    private static let switched = "В основной папке переключили ветку — слей ещё раз"

    // MARK: After a crash or quit

    public enum Recovery: Equatable, Sendable {
        /// The main folder has the merge; only the cleanup of the worktree is left.
        case landed(stash: String?)
        /// The merge is in these branches, but the main folder is on another one now.
        case landedElsewhere([String], stash: String?)
        /// The main folder's branch was not touched.
        case interrupted(stash: String?)
    }

    /// What a merge cut off by the end of the app left behind; nil — there was none.
    public static func recover(_ s: Site, git: @escaping Runner) -> Recovery? {
        let g = Repo(s, git)
        let land = g.run(["rev-parse", "-q", "--verify", "\(g.landRef)^{commit}"], s.main)
        let started = g.run(["rev-parse", "-q", "--verify", g.startRef], s.main).ok
        guard land.ok || started else { return nil }
        let stash = g.stashes().contains { $0.subject.hasSuffix(g.stashLabel) } ? g.stashLabel : nil
        let c = land.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let landed = land.ok && g.isAncestor(c, "HEAD")
        let elsewhere = land.ok && !landed ? g.branches(containing: c) : []
        if !landed, g.hasMergeHead(s.folder) { _ = g.run(["merge", "--abort"], s.folder) }
        g.deleteRef(g.startRef)
        g.deleteRef(g.landRef)
        if !elsewhere.isEmpty { return .landedElsewhere(elsewhere, stash: stash) }
        return landed ? .landed(stash: stash) : .interrupted(stash: stash)
    }

    /// Uncommitted code of the worktree.
    public static func uncommitted(_ s: Site, ignoring artifacts: [String] = [], git: @escaping Runner) -> [String] {
        (try? Repo(s, git).worktreeDirty(Set(artifacts))) ?? []
    }

    // MARK: git

    struct Failure: LocalizedError {
        let message: String
        var staleCheck = false
        init(_ message: String, staleCheck: Bool = false) { self.message = message; self.staleCheck = staleCheck }
        var errorDescription: String? { message }
    }

    private struct Stop: Error {
        let outcome: Outcome
        init(_ o: Outcome) { outcome = o }
    }

    private struct Repo {
        let s: Site
        let git: Runner
        init(_ s: Site, _ git: @escaping Runner) { self.s = s; self.git = git }

        var startRef: String { "refs/tracktasks/merge-start/\(s.branch)" }
        var landRef: String { "refs/tracktasks/merge-land/\(s.branch)" }
        var stashLabel: String { "TrackTasks: правки перед слиянием \(s.branch)" }

        func run(_ args: [String], _ dir: URL) -> Output { git(args, dir, ["LC_ALL": "C"], nil) }

        func ok(_ args: [String], _ dir: URL) throws -> Output {
            let o = run(args, dir)
            guard o.ok else { throw Failure(Self.message(o)) }
            return o
        }
        func text(_ args: [String], _ dir: URL) throws -> String {
            try ok(args, dir).text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        static func message(_ o: Output) -> String {
            let t = (o.err.isEmpty ? o.text : o.err).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "git: код \(o.status)" : t
        }

        func commit(_ rev: String, _ dir: URL) throws -> String { try text(["rev-parse", "--verify", "\(rev)^{commit}"], dir) }
        func currentBranch(_ dir: URL) -> String {
            run(["symbolic-ref", "--short", "-q", "HEAD"], dir).text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func isAncestor(_ a: String, _ b: String) -> Bool { run(["merge-base", "--is-ancestor", a, b], s.main).ok }
        /// Local branches with the commit, except the job's own one.
        func branches(containing c: String) -> [String] {
            run(["for-each-ref", "--contains", c, "--format=%(refname)", "refs/heads"], s.main).text.split(separator: "\n")
                .map { String($0.dropFirst("refs/heads/".count)) }.filter { $0 != s.branch }
        }
        func hasMergeHead(_ dir: URL) -> Bool { run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], dir).ok }
        func setRef(_ ref: String, _ oid: String) throws { _ = try ok(["update-ref", ref, oid], s.main) }
        func deleteRef(_ ref: String) { _ = run(["update-ref", "-d", ref], s.main) }

        func checkBranch() throws {
            guard !s.branch.isEmpty, currentBranch(s.folder) == s.branch else {
                throw Failure("Worktree удалён или в нём не ветка \(s.branch)")
            }
        }

        func unmerged(_ dir: URL) throws -> [String] {
            Self.split(try ok(["diff", "--name-only", "-z", "--diff-filter=U"], dir).text)
        }
        func dirty(_ dir: URL) throws -> [String] {
            DirtyFiles.significant(DirtyFiles.parsePorcelainZ(try ok(["status", "--porcelain", "-z", "-uall"], dir).text))
        }
        func worktreeDirty(_ artifacts: Set<String>) throws -> [String] {
            // An artifact counts only while it's untracked; a tracked change is never ignored.
            let skip = artifacts.intersection(try untracked())
            return try dirty(s.folder).filter { !skip.contains($0) && !s.links.contains($0) }
        }
        func untracked() throws -> [String] {
            Self.split(try ok(["ls-files", "--others", "--exclude-standard", "-z"], s.folder).text)
        }
        func overlap(_ range: String) throws -> [String] {
            // No rename detection: the old path of a renamed file counts too.
            DirtyFiles.overlap(branch: Self.split(try ok(["diff", "--name-only", "--no-renames", "-z", range], s.main).text), dirty: try dirty(s.main))
        }
        private static func split(_ t: String) -> [String] { t.split(separator: "\0").map(String.init) }

        func stashes() -> [(oid: String, subject: String)] {
            run(["stash", "list", "--format=%H %gs"], s.main).text.split(separator: "\n").map {
                let p = $0.split(separator: " ", maxSplits: 1).map(String.init)
                return (p[0], p.count > 1 ? p[1] : "")
            }
        }
        func stash() throws -> String {
            let before = Set(stashes().map(\.oid))
            let r = run(["stash", "push", "--include-untracked", "-m", stashLabel], s.main)
            // By label, not stash@{0}: the list is shared with the user and other worktrees.
            guard r.ok, let mine = stashes().first(where: { !before.contains($0.oid) && $0.subject.hasSuffix(stashLabel) }) else {
                throw Failure("Не удалось временно спрятать незакоммиченные правки (git stash):\n" + Self.message(r))
            }
            return mine.oid
        }
        func unstash(_ oid: String) -> Output {
            guard let i = stashes().firstIndex(where: { $0.oid == oid }) else { return Output(status: 1, out: Data(), err: "stash \(oid) не найден") }
            return run(["stash", "pop", "stash@{\(i)}"], s.main)
        }
    }
}
