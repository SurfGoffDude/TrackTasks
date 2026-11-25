import Foundation
import TrackTasksCore

/// The installed `gh`: it keeps the token, the app never reads it.
enum GitHubCLI {
    static func locate() -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { $0 + "/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static let timeout: TimeInterval = 60

    static func run(_ args: [String], in dir: URL, input: String? = nil, outputLimit: Int? = nil) -> Worktrees.Result {
        guard let gh = locate() else { return .init(ok: false, out: "", err: "Не найден GitHub CLI (gh)") }
        let p = process(gh, args, dir)
        // Don't log `args`: they carry the title.
        Log.git.process("gh", project: dir.lastPathComponent, command: args.prefix(2).joined(separator: " "))
        return TimedProcess.run(p, timeout: timeout, input: input, outputLimit: outputLimit)
    }

    /// Ask GitHub whether the login works. `--active` (ignore other accounts) is unknown to older gh versions.
    static func authStatus(_ host: String, in dir: URL) -> Worktrees.Result {
        let r = run(["auth", "status", "--active", "--hostname", host], in: dir)
        guard !r.ok, r.err.contains("unknown flag") else { return r }
        return run(["auth", "status", "--hostname", host], in: dir)
    }

    private static func process(_ gh: String, _ args: [String], _ dir: URL) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        p.environment = env
        return p
    }

    /// Is there a login for the host — offline (`gh auth status` would call GitHub). The token itself goes to /dev/null.
    static func hasLogin(_ host: String, in dir: URL) -> Bool {
        loginCheck(host, in: dir).ok
    }

    static func loginCheck(_ host: String, in dir: URL) -> Worktrees.Result {
        guard let gh = locate() else { return .init(ok: false, out: "", err: "Не найден GitHub CLI (gh)") }
        // May wait for a keychain prompt: not forever.
        return TimedProcess.run(process(gh, ["auth", "token", "--hostname", host], dir), timeout: 20, discardOutput: true)
    }

    static func view(_ url: String, in dir: URL) -> PullRequest? {
        let r = run(["pr", "view", url, "--json", PullRequest.jsonFields], in: dir)
        return r.ok ? PullRequest.parse(r.out) : nil
    }

    /// With checks, reviews and deployments. A token without access to checks still gets the state alone.
    static func viewStatus(_ url: String, in dir: URL) -> (PullRequest, PullRequestStatus?)? {
        let r = run(["pr", "view", url, "--json", PullRequestStatus.jsonFields], in: dir)
        guard r.ok, let pr = PullRequest.parse(r.out) else { return view(url, in: dir).map { ($0, nil) } }
        var status = PullRequestStatus.parse(r.out)
        if status != nil, pr.state == .open, let a = PullRequestGraphQL.args(url, query: PullRequestGraphQL.deployments) {
            let d = run(a, in: dir)
            status?.deployments = d.ok ? PullRequestGraphQL.parseDeployments(d.out) : nil
        }
        return (pr, status)
    }

    /// Raw end of the log of a failed job, checked to be of `commit`.
    @Sendable static func ciLog(_ ref: CIFix.JobRef, commit: String, in dir: URL) -> Result<String, JobQueue.CIFixError> {
        let info = run(ref.infoArgs, in: dir)
        guard info.ok else { return .failure(.init(text: "не проверен коммит лога: " + info.message)) }
        guard CIFix.belongs(info.out, ref, commit: commit) else { return .failure(.init(text: "лог относится к другому коммиту")) }
        let r = run(ref.logArgs, in: dir, outputLimit: CIFix.outputLimit)
        return r.ok ? .success(r.out) : .failure(.init(text: "лог не получен: " + r.message))
    }

    /// nil list = error text.
    static func comments(_ url: String, in dir: URL) -> (list: [PullRequestComment]?, cut: Bool, error: String) {
        guard let a = PullRequestGraphQL.args(url, query: PullRequestGraphQL.comments) else { return (nil, false, "Неизвестный адрес PR") }
        let r = run(a, in: dir)
        guard r.ok else { return (nil, false, r.message) }
        guard let c = PullRequestGraphQL.parseComments(r.out) else { return (nil, false, "Не разобран ответ GitHub") }
        return (c.list, c.cut, "")
    }
}

/// Everything the confirmation sheet shows. Collected offline.
struct PullRequestPreview {
    var remotes: [String] = []
    var remote = ""
    var remoteURL = ""
    var repo: GitHubRepo?
    var problem: String?
    var bases: [String] = []
    var base = ""
    /// Exact commit that will be pushed.
    var tip = ""
    var dirty: [String] = []

    static func load(_ w: Worktrees.Info, remote wanted: String?) -> PullRequestPreview {
        var p = PullRequestPreview()
        func git(_ a: [String]) -> Worktrees.Result { Worktrees.git(a, in: w.main) }
        func line(_ a: [String]) -> String { git(a).out.trimmingCharacters(in: .whitespacesAndNewlines) }
        p.remotes = line(["remote"]).split(separator: "\n").map(String.init)
        p.remote = wanted.flatMap { p.remotes.contains($0) ? $0 : nil }
            ?? (p.remotes.contains("origin") ? "origin" : p.remotes.first ?? "")
        if !p.remote.isEmpty {
            let url = line(["remote", "get-url", "--push", p.remote])
            p.remoteURL = GitHubRepo.masked(url)
            p.repo = GitHubRepo.parse(url)
            let prefix = "refs/remotes/\(p.remote)/"
            p.bases = line(["for-each-ref", "--format=%(refname)", prefix]).split(separator: "\n")
                .map { String($0.dropFirst(prefix.count)) }.filter { $0 != "HEAD" && !$0.hasPrefix("tracktasks/") }
            let current = line(["branch", "--show-current"])
            let remoteHead = String(line(["symbolic-ref", "-q", prefix + "HEAD"]).dropFirst(prefix.count))
            p.base = p.bases.contains(current) ? current
                : !remoteHead.isEmpty ? remoteHead : current.isEmpty ? "main" : current
            if !p.bases.contains(p.base) { p.bases.append(p.base) }
        }
        p.tip = line(["rev-parse", "--verify", "-q", "refs/heads/\(w.branch)"])
        p.dirty = Worktrees.dirtyFiles(in: w.path)
        let hasGH = GitHubCLI.locate() != nil
        p.problem = PullRequestPreflight.problem(hasRemote: !p.remotes.isEmpty, repo: p.repo, hasGH: hasGH,
                                                 loggedIn: hasGH && p.repo.map { GitHubCLI.hasLogin($0.host, in: w.main) } == true)
        if p.problem == nil, p.tip.isEmpty { p.problem = "Ветка \(w.branch) не найдена" }
        return p
    }

    /// Commits that are not in the remote base yet, as far as the local copy knows.
    static func commits(_ w: Worktrees.Info, tip: String, remote: String, base: String) -> [String] {
        let ref = "refs/remotes/\(remote)/\(base)"
        let known = Worktrees.git(["rev-parse", "--verify", "-q", ref], in: w.main).ok
        return Worktrees.git(["log", "--format=%h %s", "-n", "200", tip] + (known ? ["^" + ref] : ["--not", "--remotes=\(remote)"]), in: w.main).out
            .split(separator: "\n").map(String.init)
    }
}
