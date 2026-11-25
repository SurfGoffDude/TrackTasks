import Foundation
import TrackTasksCore

struct AutoSteps: Codable, Equatable {
    var reviews = 0, fixes = 0, repairs = 0, merges = 0
    var parked: String?
}

extension JobQueue {
    /// The project may merge by itself and the task is the person's own.
    /// A task with a pipeline is merged by the person only.
    func onAutopilot(_ job: Job) -> Bool { job.pipeline == nil && !job.fromPipeline && allows(.merge, job) }

    /// Moves every finished branch one step on. Called from `pump`, i.e. after every queue event.
    func autopilot() {
        guard !autopiloting, mergeBatch == nil else { return }
        autopiloting = true
        defer { autopiloting = false }
        for job in jobs where job.kind == .runTask && job.parentID == nil && job.state == .done && job.awaitsMerge
            && job.auto.parked == nil && !job.worktreeBusy {
            if let h = job.autoHold, h > Date() { continue }
            if !job.repos.isEmpty || job.isGroup {
                // Merging several repositories isn't atomic: the person does it.
                if dangerMode().grant(job.cwd.path, now: Date())?.autopilot == true {
                    job.auto.parked = "несколько репозиториев — слей вручную"
                    autoNote(job, "отложено: несколько репозиториев")
                    save()
                }
                continue
            }
            guard onAutopilot(job) else { continue }
            autopilotStep(job)
        }
        reportAutopilot()
    }

    private func autopilotStep(_ job: Job) {
        var f = Autopilot.Facts()
        f.ready = !hasActiveChild(job) && !job.isActive
        let task = job.taskPath.flatMap { Codec.task(at: URL(fileURLWithPath: $0)) }
        f.taskDone = task?.status == .done
        f.awaitsAnswers = awaitsAnswers(job) || task.map { !AgentQuestions.open(in: $0.body, done: f.taskDone).isEmpty } ?? false
        f.livePR = job.hasLivePR
        f.rolledBack = !job.rolledBack.isEmpty
        f.verify = MergeRunner.command(job.cwd)
        f.needsMac = job.worktree.map { MergeRunner.needsMac(f.verify, in: $0.path) } ?? false
        f.approvedVerify = dangerMode().grant(job.cwd.path, now: Date())?.verify
        f.taskCheck = taskGate(job)?.decide().refusal?.why
        f.verdict = job.verdict.map { $0 == .ok ? .ok : .issues }
        f.reviewFixed = job.reviewFixed
        f.mergeConflict = job.mergeFailed
        f.checkRed = job.mergeCheck?.state == .red
        f.reviews = job.auto.reviews
        f.fixes = job.auto.fixes
        f.repairs = job.auto.repairs
        f.merges = job.auto.merges
        switch Autopilot.step(f) {
        case .wait: break
        case .park(let why):
            job.auto.parked = why
            job.worktreeNote = Self.parkedNote(why)
            autoNote(job, "отложено: " + why)
            if f.taskCheck != nil { refreshTaskCheck(job) }
            save()
        case .review:
            job.auto.reviews += 1
            autoNote(job, "ревью")
            requestReview(job)
        case .fixReview:
            job.auto.fixes += 1
            autoNote(job, "исправление замечаний ревью \(job.auto.fixes)/\(Autopilot.maxFixes)")
            requestFix(job)
        case .resolveConflict where !canResolve(job):
            job.auto.parked = "конфликт с main: агент на сервере его не разрешает"
            job.worktreeNote = "Автопилот отложил: " + job.auto.parked!
            autoNote(job, "отложено: " + job.auto.parked!)
        case .resolveConflict:
            job.auto.repairs += 1
            autoNote(job, "разрешение конфликта с main")
            requestResolve(job)
        case .fixCheck:
            job.auto.repairs += 1
            autoNote(job, "исправление проверки вместе с main")
            requestMergeFix(job)
        case .merge:
            // One branch of a project at a time.
            let folder = job.cwd.standardizedFileURL.path
            guard !gitBusy(around: job.cwd), !jobs.contains(where: { $0.mergePhase != nil && $0.cwd.standardizedFileURL.path == folder }),
                  autoMerging.insert(folder).inserted else { return }
            Task { @MainActor in
                let ok = await self.mergeNow(job, ask: false, automatic: true)
                self.autoMerging.remove(folder)
                self.autopilotMerged(job, ok)
            }
        }
    }

    private func autopilotMerged(_ job: Job, _ ok: Bool) {
        if ok {
            autoNote(job, "слито в main")
            autoReport[job.cwd.path, default: []].append(job.title)
        } else if job.mergeCheck?.state != .red, !job.mergeFailed {
            if job.mergeWaits {
                // Uncommitted files in main are the person's or another agent's: never touched, tried again later.
                job.autoHold = Date().addingTimeInterval(60)
                DispatchQueue.main.asyncAfter(deadline: .now() + 61) { [weak self] in self?.pump() }
            } else {
                job.auto.merges += 1
            }
        }
        save()
        pump()
    }

    /// The person wants it tried again.
    func resumeAutopilot(_ job: Job) {
        job.auto = AutoSteps()
        job.autoHold = nil
        job.worktreeNote = ""
        save()
        pump()
    }

    static func parkedNote(_ why: String) -> String { "Автопилот отложил: " + why }

    private func autoNote(_ job: Job, _ text: String) { job.log.append("⚙︎ Автопилот: " + text) }

    /// One notification when a project has nothing left to do.
    private func reportAutopilot() {
        for (path, merged) in autoReport {
            let mine = jobs.filter { $0.cwd.path == path }
            guard !mine.contains(where: { $0.isActive || $0.mergePhase != nil }), !autoMerging.contains(URL(fileURLWithPath: path).standardizedFileURL.path),
                  !mine.contains(where: { $0.awaitsMerge && $0.auto.parked == nil && $0.state == .done && onAutopilot($0) }) else { continue }
            autoReport[path] = nil
            let parked = mine.filter { $0.awaitsMerge && $0.auto.parked != nil }
            let failed = mine.filter { $0.state == .failed && $0.parentID == nil }
            var body = parked.map { "\($0.title): \($0.auto.parked ?? "")" } + failed.map { "\($0.title): не выполнена" }
            if body.isEmpty { body = merged }
            Notifier.shared.post(title: "Автопилот: слито \(merged.count), отложено \(parked.count + failed.count)",
                                 body: body.prefix(6).joined(separator: "\n"))
        }
    }
}
