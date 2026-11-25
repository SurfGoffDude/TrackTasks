import Foundation

public struct GitBranch: Identifiable, Hashable, Sendable {
    /// Полное имя ссылки.
    public var id: String
    /// `main` или `origin/main`.
    public var name: String
    /// Для удалённой ветки.
    public var remote: String?
    public var tip: String
    public var isCurrent = false
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    /// Upstream удалён.
    public var gone = false
    /// Другая папка, где открыта ветка.
    public var worktree: String?

    /// Имя локальной ветки для удалённой.
    public var localName: String {
        guard let remote else { return name }
        return String(name.dropFirst(remote.count + 1))
    }
}

public struct GitState: Sendable {
    /// nil — detached HEAD.
    public var branch: String?
    /// Коммитов ещё нет.
    public var unborn = false
    /// Коммиты detached HEAD, которых нет ни в одной ветке: после переключения их не найти.
    public var loose = 0
    /// Незаконченная операция: merge, rebase…
    public var operation: String?
    public var branches: [GitBranch] = []
    public var remotes: [String] = []
    public var error: String?
    public init() {}
}

/// Ветки основной папки, переключение, fetch, pull и push. Принудительного нет ничего.
public enum GitBranches {
    // MARK: Состояние

    public static func load(_ dir: URL, git: GitRun.Runner) -> GitState {
        var s = GitState()
        s.branch = currentBranch(dir, git)
        s.unborn = !GitRun.hasHead(dir, git)
        if s.branch == nil, !s.unborn {
            s.loose = GitRun.line(["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes", "--tags"], dir, git).flatMap { Int($0) } ?? 0
        }
        s.operation = operation(dir, git: git)
        s.remotes = (GitRun.line(["remote"], dir, git) ?? "").split(separator: "\n").map(String.init)
        let o = GitRun.read(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:track,nobracket)%00%(worktreepath)%00%(symref)",
                             "refs/heads", "refs/remotes"], dir, git)
        guard o.ok else {
            s.error = GitRun.message(o)
            return s
        }
        for line in o.text.split(separator: "\n") {
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6 else { continue }
            if f[0].hasPrefix("refs/heads/") {
                var b = GitBranch(id: f[0], name: String(f[0].dropFirst(11)), tip: f[1])
                b.isCurrent = b.name == s.branch
                if !f[2].isEmpty { b.upstream = short(f[2]) }
                (b.ahead, b.behind, b.gone) = track(f[3])
                if !b.isCurrent, !f[4].isEmpty { b.worktree = f[4] }
                s.branches.append(b)
            } else if f[0].hasPrefix("refs/remotes/"), f[5].isEmpty {
                let name = String(f[0].dropFirst(13))
                // В имени remote может быть «/».
                let remote = s.remotes.filter { name.hasPrefix($0 + "/") }.max { $0.count < $1.count }
                guard let remote else { continue }
                s.branches.append(GitBranch(id: f[0], name: name, remote: remote, tip: f[1]))
            }
        }
        return s
    }

    static func currentBranch(_ dir: URL, _ git: GitRun.Runner) -> String? {
        guard let r = GitRun.line(["symbolic-ref", "-q", "HEAD"], dir, git), r.hasPrefix("refs/heads/") else { return nil }
        return String(r.dropFirst(11))
    }

    private static func short(_ ref: String) -> String {
        for p in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(p) { return String(ref.dropFirst(p.count)) }
        return ref
    }

    /// «ahead 1, behind 2» / «gone».
    static func track(_ s: String) -> (Int, Int, Bool) {
        var a = 0, b = 0
        for part in s.components(separatedBy: ", ") {
            let w = part.split(separator: " ")
            guard w.count == 2, let n = Int(w[1]) else { continue }
            if w[0] == "ahead" { a = n } else if w[0] == "behind" { b = n }
        }
        return (a, b, s == "gone")
    }

    /// Название незаконченной операции, nil — её нет.
    public static func operation(_ dir: URL, git: GitRun.Runner) -> String? {
        let marks = [("MERGE_HEAD", "merge"), ("rebase-merge", "rebase"), ("rebase-apply", "rebase"),
                     ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"), ("BISECT_LOG", "bisect")]
        let o = GitRun.read(["rev-parse"] + marks.flatMap { ["--git-path", $0.0] }, dir, git)
        guard o.ok else { return nil }
        for (path, mark) in zip(o.text.split(separator: "\n").map(String.init), marks) {
            let full = path.hasPrefix("/") ? path : dir.appendingPathComponent(path).path
            if FileManager.default.fileExists(atPath: full) { return mark.1 }
        }
        return nil
    }

    // MARK: Переключение

    public enum SwitchCheck: Equatable, Sendable {
        case allowed
        /// В папке незакоммиченное: решает пользователь.
        case ask([String])
        case denied(String)
    }

    /// Почему на ветку нельзя переключиться при любых файлах; nil — можно.
    public static func denied(_ b: GitBranch, _ s: GitState) -> String? {
        if let op = s.operation { return "Не закончена операция git: \(op)" }
        if s.unborn { return "В репозитории ещё нет коммита: сначала закоммить то, что есть" }
        if s.loose > 0 { return "Коммиты без ветки (\(s.loose)) после переключения потеряются: сначала создай ветку (git switch -c)" }
        if b.isCurrent { return "Эта ветка уже открыта" }
        if let w = b.worktree { return "Ветка открыта в другой папке: \(w)" }
        if b.remote != nil, let local = s.branches.first(where: { $0.remote == nil && $0.name == b.localName }) {
            return "Локальная ветка «\(local.name)» уже есть — переключись на неё"
        }
        return nil
    }

    public static func check(_ b: GitBranch, _ s: GitState, dirty: [String]) -> SwitchCheck {
        if let why = denied(b, s) { return .denied(why) }
        return dirty.isEmpty ? .allowed : .ask(dirty)
    }

    /// Без `-f`, `-m` и stash: мешающие правки git не тронет, а откажет. Без `--no-overwrite-ignore` он молча
    /// затирает игнорируемые файлы.
    static func switchArgs(_ b: GitBranch) -> [String] {
        let common = ["switch", "--no-overwrite-ignore", "--no-recurse-submodules", "--no-guess"]
        return b.remote == nil ? common + [b.name] : common + ["--track", "-c", b.localName, b.id]
    }

    public enum SwitchResult: Equatable, Sendable {
        case done
        case ask([String])
        case failed(String)
    }

    /// `confirmed` — файлы, которые пользователь видел в вопросе. Всё перечитывается здесь, перед самым запуском.
    public static func switchTo(_ id: String, in dir: URL, confirmed: Set<String> = [], git: GitRun.Runner) -> SwitchResult {
        let s = load(dir, git: git)
        guard let b = s.branches.first(where: { $0.id == id }) else { return .failed("Ветки больше нет") }
        let files: [GitFile]
        switch GitStaging.status(dir, git: git) {
        case .failure(let e): return .failed(e.message)
        case .success(let f): files = f
        }
        switch check(b, s, dirty: files.map(\.path)) {
        case .denied(let why): return .failed(why)
        case .ask(let d) where !Set(d).isSubset(of: confirmed): return .ask(d)
        default: break
        }
        let o = git(switchArgs(b), dir, [:], nil)
        return o.ok ? .done : .failed(GitRun.message(o))
    }

    // MARK: Fetch и pull

    /// У зеркала fetch переписывает локальные ветки.
    static func fetchBlocked(_ dir: URL, _ git: GitRun.Runner) -> String? {
        let o = GitRun.read(["config", "-z", "--get-regexp", "^remote\\..*\\.fetch$"], dir, git)
        for entry in o.text.split(separator: "\0") {
            guard let spec = entry.split(separator: "\n").last, let dst = spec.split(separator: ":").last, spec.contains(":") else { continue }
            if dst.hasPrefix("refs/heads/") || dst == "refs/*" { return "fetch здесь переписал бы локальные ветки (\(spec)) — сделай его в терминале" }
        }
        return nil
    }

    public static func fetch(_ dir: URL, remote: String? = nil, git: GitRun.Runner, network: GitRun.Network) -> Result<Void, GitRun.Failure> {
        if let why = fetchBlocked(dir, git) { return .failure(.init(why)) }
        let o = network(["fetch", "--no-recurse-submodules"] + (remote.map { [$0] } ?? ["--all"]), dir)
        return o.ok ? .success(()) : .failure(.init(GitRun.message(o)))
    }

    /// Ветка, которую подтягивает pull, и её remote.
    public static func pullSource(_ dir: URL, git: GitRun.Runner) -> Result<(branch: String, remote: String), GitRun.Failure> {
        guard let branch = currentBranch(dir, git) else { return .failure(.init("Ветка не выбрана (detached HEAD)")) }
        guard let t = target(branch, dir, git) else { return .failure(.init("У ветки «\(branch)» нет upstream")) }
        return .success((branch, t.remote))
    }

    /// Вторая половина pull, после fetch: только перемотка вперёд.
    public static func fastForward(_ dir: URL, branch: String, git: GitRun.Runner) -> Result<String, GitRun.Failure> {
        guard currentBranch(dir, git) == branch else { return .failure(.init("Ветка сменилась, пока шёл fetch")) }
        if let op = operation(dir, git: git) { return .failure(.init("Не закончена операция git: \(op)")) }
        guard let counts = GitRun.line(["rev-list", "--left-right", "--count", "HEAD...@{u}"], dir, git) else {
            return .failure(.init("Upstream ветки «\(branch)» не найден"))
        }
        let n = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard n.count == 2 else { return .failure(.init("Не понял ответ git: \(counts)")) }
        if n[1] == 0 { return .success("Новых коммитов нет") }
        if n[0] > 0 { return .failure(.init("Ветки разошлись: своих коммитов \(n[0]), новых на сервере \(n[1]). Перемотка невозможна — слей или перебазируй вручную")) }
        let o = git(["-c", "submodule.recurse=false", "merge", "--ff-only", "--no-squash", "--no-autostash", "--no-overwrite-ignore", "@{u}"], dir, [:], nil)
        return o.ok ? .success("Подтянуто коммитов: \(n[1])") : .failure(.init(GitRun.message(o)))
    }

    // MARK: Push

    public struct PushPlan: Equatable, Sendable {
        public var branch: String
        public var remote: String
        /// Ветка на remote.
        public var target: String
        public var setUpstream: Bool
        public var commits: Int
        public var title: String { "\(branch) → \(remote)/\(target)" }
        public func sameTarget(_ o: PushPlan) -> Bool {
            branch == o.branch && remote == o.remote && target == o.target && setUpstream == o.setUpstream
        }
        /// Явный refspec без «+»: `push.default` и `remote.*.push` не действуют.
        var args: [String] {
            ["push", "--no-force", "--no-follow-tags", "--recurse-submodules=no"] + (setUpstream ? ["-u"] : [])
                + [remote, "refs/heads/\(branch):refs/heads/\(target)"]
        }
    }

    private static func target(_ branch: String, _ dir: URL, _ git: GitRun.Runner) -> (remote: String, ref: String, tracking: String)? {
        guard let l = GitRun.line(["for-each-ref", "--format=%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream)", "refs/heads/\(branch)"], dir, git) else { return nil }
        // Шаблон совпадает и с «ветка/…» — берём первую строку, git сортирует по имени.
        let f = (l.split(separator: "\n").first ?? "").split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 3, !f[0].isEmpty, !f[1].isEmpty else { return nil }
        return (f[0], f[1], f[2])
    }

    public static func pushPlan(_ dir: URL, git: GitRun.Runner) -> Result<PushPlan, GitRun.Failure> {
        guard let branch = currentBranch(dir, git) else { return .failure(.init("Ветка не выбрана (detached HEAD): пушить нечего")) }
        guard GitRun.hasHead(dir, git) else { return .failure(.init("В ветке ещё нет коммитов")) }
        let remotes = (GitRun.line(["remote"], dir, git) ?? "").split(separator: "\n").map(String.init)
        guard !remotes.isEmpty else { return .failure(.init("У репозитория нет remote")) }
        let up = target(branch, dir, git)
        if up?.remote == "." { return .failure(.init("Upstream ветки «\(branch)» — локальная ветка, пушить некуда")) }
        let remote = up?.remote ?? (remotes.contains("origin") ? "origin" : remotes[0])
        let mirror = GitRun.line(["config", "--type=bool", "--get", "remote.\(remote).mirror"], dir, git)
        guard mirror != "true" else { return .failure(.init("\(remote) — зеркало (remote.\(remote).mirror): пуш переписал бы его целиком")) }
        var target = branch
        if let ref = up?.ref {
            guard ref.hasPrefix("refs/heads/") else { return .failure(.init("Upstream — не ветка: \(ref)")) }
            target = String(ref.dropFirst(11))
        }
        // Удалённая ссылка могла исчезнуть: тогда считаем от всего, что есть на remote.
        var not = "--remotes=\(remote)"
        if let t = up?.tracking, GitRun.read(["rev-parse", "--verify", "-q", t], dir, git).ok { not = t }
        let n = GitRun.line(["rev-list", "--count", "refs/heads/\(branch)", "--not", not], dir, git).flatMap { Int($0) } ?? 0
        return .success(PushPlan(branch: branch, remote: remote, target: target, setUpstream: up == nil, commits: n))
    }

    /// Отправляет ровно то, что подтвердил пользователь: план пересчитывается перед запуском.
    /// `exact: false` — сверяется только адрес (коммит сделан только что, число ещё не показывали).
    public static func push(_ plan: PushPlan, in dir: URL, exact: Bool = true, git: GitRun.Runner, network: GitRun.Network) -> Result<String, GitRun.Failure> {
        let now: PushPlan
        switch pushPlan(dir, git: git) {
        case .failure(let e): return .failure(e)
        case .success(let p): now = p
        }
        guard exact ? now == plan : now.sameTarget(plan) else {
            return .failure(.init("Пока ждали подтверждения, ветка изменилась (\(now.title), коммитов \(now.commits)) — повтори пуш"))
        }
        let o = network(now.args, dir)
        return o.ok ? .success("Отправлено: \(now.title)") : .failure(.init(GitRun.message(o)))
    }
}
