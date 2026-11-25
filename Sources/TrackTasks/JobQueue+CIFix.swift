import Foundation
import TrackTasksCore

/// «Исправить CI»: failed checks go to the task's session as a reply. Nothing here pushes: that is the person's «Обновить PR».
extension JobQueue {
    struct CIFixError: Error, Equatable { var text: String }

    /// Why the logs can't be collected or sent now, apart from the state of CI; nil = can.
    func ciFixBlocked(_ job: Job) -> String? {
        if job.worktree == nil { return "У задачи нет worktree" }
        if job.pipelineOpen { return Self.pipelineUnfinished }
        if !job.rolledBack.isEmpty { return Self.uncommittedRollback }
        if !FileManager.default.fileExists(atPath: job.home.runDir.path) { return "Папка сессии удалена: \(job.home.runDir.path)" }
        return replyBlocked(job.home)
    }

    private nonisolated static func tip(_ w: Worktrees.Info) -> String {
        Worktrees.git(["rev-parse", "--verify", "-q", "refs/heads/\(w.branch)"], in: w.main).out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collects the logs of the failed checks. Nothing is sent.
    func prepareCIFix(_ job: Job) async -> Result<CIFix.Draft, CIFixError> {
        if let why = ciFixBlocked(job) { return .failure(.init(text: why)) }
        guard let w = job.worktree, let link = job.pullRequest else { return .failure(.init(text: "Нет PR")) }
        let url = link.pr.url, commit = link.pushedOid
        let before = await Task.detached(priority: .userInitiated) { Self.tip(w) }.value
        if let why = CIFix.refusal(job.pullRequest, url: url, commit: commit, tip: before) { return .failure(.init(text: why)) }
        let failed = job.pullRequest?.status?.failed ?? []
        let fetch = ciLog
        let items = await Task.detached(priority: .userInitiated) { () -> [CIFix.Item] in
            let refs = failed.map { CIFix.jobRef($0.link, pr: url) }
            let read = Set(refs.indices.filter { refs[$0] != nil }.prefix(CIFix.maxChecks))
            let max = min(CIFix.maxLog, CIFix.maxTotal / Swift.max(read.count, 1))
            return zip(failed, refs).enumerated().map { i, p in
                guard let ref = p.1 else { return .init(check: p.0, log: nil, problem: CIFix.external) }
                guard read.contains(i) else { return .init(check: p.0, log: nil, problem: "логи берутся только у первых \(CIFix.maxChecks) проверок") }
                switch fetch(ref, commit, w.main) {
                case .failure(let e): return .init(check: p.0, log: nil, problem: e.text)
                case .success(let raw):
                    let log = CIFix.clean(raw, max: max)
                    return log.text.isEmpty ? .init(check: p.0, log: nil, problem: "лог пуст") : .init(check: p.0, log: log)
                }
            }
        }.value
        let draft = CIFix.Draft(url: url, number: link.pr.number, commit: commit, items: items)
        let after = await Task.detached(priority: .userInitiated) { Self.tip(w) }.value
        if let why = CIFix.refusal(job.pullRequest, draft: draft, tip: after) { return .failure(.init(text: why)) }
        return .success(draft)
    }

    func ciFixText(_ job: Job, _ draft: CIFix.Draft, chosen: Set<Int>, note: String = "") -> String {
        let text = draft.message(chosen, note: note)
        return text.isEmpty || job.owner == nil ? text : "Репозиторий «\(job.repoName)». " + text
    }

    /// Sends what was shown. Returns an error text; nil = sent.
    func sendCIFix(_ job: Job, _ draft: CIFix.Draft, chosen: Set<Int>, note: String = "", automatic: Bool = false) async -> String? {
        let text = ciFixText(job, draft, chosen: chosen, note: note)
        guard !text.isEmpty else { return "Ничего не выбрано" }
        guard let w = job.worktree else { return "У задачи нет worktree" }
        let tip = await Task.detached(priority: .userInitiated) { Self.tip(w) }.value
        // No suspension from here on.
        let home = job.home
        if let why = ciFixBlocked(job) ?? CIFix.refusal(job.pullRequest, draft: draft, tip: tip) { return why }
        if automatic, !autoCIFixAllowed(job) { return "Автоматически отправить нельзя" }
        let oldTries = home.ciFixTries, oldForeign = home.foreignLog
        if automatic { _ = home.ciFixTries.take(draft.url, commit: draft.commit) }
        // The session has a stranger's text from now on: no full access and no automatic merge.
        home.foreignLog = true
        guard saveNow() else {
            home.ciFixTries = oldTries
            home.foreignLog = oldForeign
            return "Не отправлено: очередь не записана на диск"
        }
        home.log.append("⚙︎ " + (automatic ? "Автоисправление CI \(home.ciFixTries.count(draft.url))/\(CIFix.maxAuto)" : "Исправление CI")
            + ": PR #\(draft.number), коммит \(draft.commit.prefix(8))")
        return sendReply(home, text: text) ? nil : "Сейчас отправить нельзя"
    }

    // MARK: Automatic

    private func autoCIFixAllowed(_ job: Job) -> Bool {
        let home = job.home
        guard !paused, let link = job.pullRequest, link.pr.state == .open, link.ci == .red,
              home.kind == .runTask, home.state == .done, ciAutoFix(home.cwd), ciAutoFix(job.cwd),
              // All failures at once, and logs of a run that still goes can't be read.
              link.status?.count(.pending) == 0,
              jobs.contains(where: { $0 === home }), home.ciFixTries.allows(link.pr.url, commit: link.pushedOid),
              ciFixBlocked(job) == nil, !awaitsAnswers(home), !hasForeignSource(home), !isScheduled(home) else { return false }
        return true
    }

    /// Called with every answer of GitHub about the pull request; no timers of its own.
    @discardableResult
    func autoCIFix(_ job: Job) -> Task<Void, Never>? {
        let home = job.home
        guard autoCIFixAllowed(job), ciFixing.insert(home.id).inserted else { return nil }
        return Task {
            defer { ciFixing.remove(home.id) }
            // Without a log there is nothing to fix by; nothing is counted.
            guard case .success(let draft) = await prepareCIFix(job), draft.hasLogs else { return }
            guard await sendCIFix(job, draft, chosen: Set(draft.items.indices), automatic: true) == nil else { return }
            job.worktreeNote = "CI красный: логи отправлены агенту автоматически (\(home.ciFixTries.count(draft.url)) из \(CIFix.maxAuto)). Исправление отправь кнопкой «Обновить PR»"
            save()
        }
    }
}
