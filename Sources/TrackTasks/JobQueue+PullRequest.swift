import Foundation
import TrackTasksCore

extension Job {
    var hasOpenPR: Bool { worktree != nil && pullRequest?.pr.state == .open }
    /// The branch goes through a pull request (open, or merged and not pulled yet): no local merge.
    var hasLivePR: Bool { pullRequest?.isLive == true }
}

extension JobQueue {
    // MARK: Pull request

    /// Push the previewed commit and create the pull request (or just push, when one is already open).
    /// Called only after the user confirmed the preview. Returns an error text; nil = done.
    func publishPR(_ job: Job, preview: PullRequestPreview, base: String, title: String, body: String) async -> String? {
        guard let w = job.worktree, let repo = preview.repo, preview.problem == nil, !preview.tip.isEmpty else { return preview.problem ?? "Нет ветки" }
        guard !job.worktreeBusy, !job.home.isActive, !hasActiveChild(job) else { return "В ветке идёт другая операция — дождись её" }
        if job.pipelineOpen { return "Не отправлено: " + Self.pipelineUnfinished }
        guard job.rolledBack.isEmpty else { return "Не отправлено: " + Self.uncommittedRollback }
        job.worktreeBusy = true
        let open = job.pullRequest.flatMap { $0.pr.state == .open ? $0.pr : nil }
        let (pr, error) = await Task.detached(priority: .userInitiated) { () -> (PullRequest?, String?) in
            let auth = GitHubCLI.authStatus(repo.host, in: w.main)
            guard auth.ok else { return (nil, "gh не подтвердил вход для \(repo.host). Проверь сеть или выполни: gh auth login --hostname \(repo.host)\n" + auth.message) }
            // The exact commit from the preview, never forced.
            let push = TimedProcess.gitNetwork(["push", preview.remote, "\(preview.tip):refs/heads/\(w.branch)"], in: w.main, timeout: 300)
            guard push.ok else { return (nil, "Пуш не удался: " + push.message) }
            if let open { return (GitHubCLI.view(open.url, in: w.main) ?? open, nil) }
            let c = GitHubCLI.run(["pr", "create", "--repo", repo.slug, "--head", w.branch, "--base", base,
                                   "--title", title, "--body-file", "-"], in: w.main, input: body)
            if c.ok, var pr = PullRequest.parseCreated(c.out) {
                pr.head = w.branch
                pr.base = base
                pr.headOid = preview.tip
                return (GitHubCLI.view(pr.url, in: w.main) ?? pr, nil)
            }
            // Already exists (e.g. the previous answer was lost).
            let l = GitHubCLI.run(["pr", "list", "--repo", repo.slug, "--head", w.branch, "--state", "open",
                                   "--json", PullRequest.jsonFields], in: w.main)
            if l.ok, let pr = PullRequest.parseList(l.out)?.first { return (pr, nil) }
            return (nil, "Ветка отправлена, но PR не создан: " + c.message)
        }.value
        job.worktreeBusy = false
        if let pr {
            job.pullRequest = PullRequestLink(pr: pr, remote: preview.remote, pushedOid: preview.tip)
            job.mergeFailed = false
            refreshPR(job)
            schedulePRPoll()
            job.worktreeNote = open == nil ? "Создан PR #\(pr.number)" : "PR #\(pr.number) обновлён"
        }
        save()
        return error
    }

    /// Ask GitHub about pull requests that can still change. On window activation — at most once a minute.
    func refreshPRs(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPRRefresh) > 60 else { return }
        lastPRRefresh = Date()
        for j in allMembers where j.worktree != nil && j.pullRequest != nil { refreshPR(j) }
        schedulePRPoll()
    }

    /// Nothing tells the app about CI, so open pull requests are asked every 5 minutes. No open ones — no timer.
    func schedulePRPoll() {
        guard prPoll == nil, allMembers.contains(where: \.hasOpenPR) else { return }
        prPoll = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard let self, !Task.isCancelled else { return }
            prPoll = nil
            if Date().timeIntervalSince(lastPRRefresh) > 60 {
                lastPRRefresh = Date()
                for j in allMembers where j.hasOpenPR { refreshPR(j) }
            }
            schedulePRPoll()
        }
    }

    func refreshPR(_ job: Job, report: Bool = false) {
        guard let link = job.pullRequest, let w = job.worktree, !link.leftover else { return }
        if link.pr.state == .merged, link.pr.mergeOid != nil { return settlePR(job, report: report) }
        let asked = Date()
        Task {
            let found = await Task.detached(priority: .utility) { GitHubCLI.viewStatus(link.pr.url, in: w.main) }.value
            // The link may have been replaced (a new pull request or push) meanwhile.
            guard job.pullRequest?.pr.url == link.pr.url, job.pullRequest?.pushedOid == link.pushedOid else { return }
            guard let (pr, status) = found else {
                if report { job.worktreeNote = "Не удалось узнать состояние PR #\(link.pr.number): проверь сеть и gh auth status" }
                return
            }
            if pr.state != link.pr.state {
                switch pr.state {
                case .open: job.worktreeNote = "PR #\(pr.number) снова открыт"
                case .closed: job.worktreeNote = "PR #\(pr.number) закрыт без слияния"
                case .merged: job.worktreeNote = "PR #\(pr.number) слит — подтяни основную ветку"
                }
            }
            if var l = job.pullRequest, l.pr != pr || l.status != status {
                l.update(pr: pr, status: status, asked: asked)
                job.pullRequest = l
                save()
            }
            if report, pr.state == link.pr.state, pr.state != .merged {
                job.worktreeNote = status == nil ? "PR #\(pr.number): состояние прежнее, проверки CI получить не удалось" : "PR #\(pr.number): обновлено"
            }
            autoCIFix(job)
            settlePR(job, report: report)
        }
    }

    /// Merged and pulled into the main folder: remove the worktree and let dependents go.
    /// Keeps the worktree when it holds anything that never reached GitHub.
    /// `report`: the user asked — say why it isn't settled yet.
    func settlePR(_ job: Job, report: Bool = false) {
        guard let link = job.pullRequest, link.pr.state == .merged, !link.leftover, !(job.isGroup && job.merged), let w = job.worktree else { return }
        guard !job.worktreeBusy, !job.home.isActive, !hasActiveChild(job) else {
            // Another repository of the task may be busy settling: this one is next.
            if job.isGroup, job.worktreeBusy { job.settleLater = true }
            if report, !job.worktreeBusy { job.worktreeNote = "PR #\(link.pr.number) слит — дождись ответа, ревью или исправления в ветке" }
            return
        }
        job.worktreeBusy = true
        Task {
            let decision = await Task.detached(priority: .utility) { () -> PullRequestCleanup in
                let tip = Worktrees.git(["rev-parse", "--verify", "-q", "refs/heads/\(w.branch)"], in: w.main).out
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                func inMain(_ oid: String) -> Bool {
                    !oid.isEmpty && Worktrees.git(["merge-base", "--is-ancestor", oid, "HEAD"], in: w.main).ok
                }
                let st = Worktrees.git(["status", "--porcelain", "-z", "-uall"], in: w.path)
                let left = DirtyFiles.significant(DirtyFiles.parsePorcelainZ(st.out)).filter { !Worktrees.links(of: w.path).contains($0) }
                let dirty = FileManager.default.fileExists(atPath: w.path.path) && (!st.ok || !left.isEmpty)
                return .decide(state: link.pr.state, pulled: link.pr.mergeOid.map(inMain) ?? inMain(tip), dirty: dirty,
                               tip: tip, pushed: link.pushedOid, head: link.pr.headOid, tipInMain: inMain(tip))
            }.value
            // A reply or a fix may have started while git ran.
            guard !hasActiveChild(job) else { job.worktreeBusy = false; return }
            let n = link.pr.number
            switch decision {
            case .none: break
            case .waitPull:
                if link.pr.mergeOid == nil {
                    // A squash can't be recognised without it; the next refresh asks GitHub again.
                    job.worktreeNote = "PR #\(n) слит, но GitHub не сообщил коммит слияния — обнови состояние позже"
                } else if report {
                    job.worktreeNote = "PR #\(n) слит, но его коммита нет в основной папке — подтяни \(link.pr.base)"
                }
            case .dirty: job.worktreeNote = "PR #\(n) слит и подтянут, но в worktree есть незакоммиченные правки — он оставлен. Закоммить их или удали worktree."
            case .newCommits:
                job.pullRequest?.leftover = true
                job.worktreeNote = "PR #\(n) слит, но в ветке есть коммиты, не попавшие в него — слей их или создай новый PR."
            case .clean:
                job.merged = true
                job.mergeFailed = false
                job.mainConflict = false
                if job.parts.isEmpty {
                    Terminals.shared.closeAll(job.id)
                    let own = job.owner == nil
                    let teardown = own ? dangerTeardown(job) : nil
                    await Task.detached(priority: .userInitiated) { Worktrees.remove(w, deleteBranch: true, force: true, teardown: teardown, scripts: own) }.value
                    job.worktree = nil
                    job.worktreeNote = "PR #\(n) слит и подтянут, worktree удалён"
                } else {
                    job.worktreeNote = "PR #\(n) слит и подтянут"
                }
            }
            job.worktreeBusy = false
            save()
            if decision == .clean { await closeGroup(job) }
            for m in job.home.members where m.settleLater {
                m.settleLater = false
                settlePR(m)
            }
            if decision == .clean {
                onMerged?(job)
                pump()
            }
        }
    }

    /// git changed in a project folder: a pull may have brought merged pull requests.
    func settlePRs(in path: String, except: Job? = nil) {
        let real = TaskRepos.canonical(URL(fileURLWithPath: path))
        for j in allMembers where j !== except && j.realCwd == real && j.pullRequest?.pr.state == .merged { settlePR(j) }
    }

    /// «Подтянуть»: fast-forward the main folder to the remote base.
    func pullBase(_ job: Job) {
        guard let link = job.pullRequest, let w = job.worktree, !job.worktreeBusy, !gitBusy(around: job.cwd), link.pr.state == .merged else { return }
        job.worktreeBusy = true
        job.worktreeNote = "Подтягиваю \(link.pr.base)…"
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                let current = Worktrees.git(["branch", "--show-current"], in: w.main).out.trimmingCharacters(in: .whitespacesAndNewlines)
                guard current == link.pr.base else {
                    return "В основной папке открыта ветка «\(current)», а PR слит в «\(link.pr.base)». Переключись и подтяни вручную."
                }
                // Pull in two steps: the timeout may interrupt only the fetch, never the update of the files.
                let f = TimedProcess.gitNetwork(["fetch", link.remote, link.pr.base], in: w.main)
                guard f.ok else { return "Не удалось подтянуть: " + f.message }
                let r = Worktrees.git(["merge", "--ff-only", "FETCH_HEAD"], in: w.main)
                return r.ok ? nil : "Не удалось подтянуть: " + r.message
            }.value
            job.worktreeBusy = false
            if let error { job.worktreeNote = error; save() }
            else { job.worktreeNote = "\(link.pr.base) подтянута"; refreshPR(job, report: true); settlePRs(in: job.cwd.standardizedFileURL.path, except: job) }
        }
    }
}
