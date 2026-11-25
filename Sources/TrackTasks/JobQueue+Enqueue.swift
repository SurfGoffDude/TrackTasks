import Foundation
import TrackTasksCore

extension JobQueue {
    enum EnqueueResult {
        case queued([Job])
        /// `extra`: dependencies to add; `plan`: everything in queue order.
        case needsDependencies(extra: [TaskItem], plan: [TaskItem])
        case failed(String)
    }

    /// `Store.enqueue` without dialogs.
    /// `autoDependencies: false`: dangerous mode doesn't add missing dependencies on its own.
    func tryEnqueue(_ tasks: [TaskItem], project: Project, chain: Bool = false, waves: Bool = false,
                    confirmed: Bool = false, autoDependencies: Bool = true, ensureGit: (_ projectID: String) -> String?) -> EnqueueResult {
        let byName = Dictionary(project.tasks.map { ($0.fileName, $0) }, uniquingKeysWith: { a, _ in a })
        let tasks = tasks.filter { $0.folder == .active }
        let nodes = project.dependencyNodes
        let queued = Set(project.tasks.filter { blockingJob(forTask: $0.id) != nil }.map(\.fileName))
        let targets = tasks.filter { $0.status != .done }.map(\.fileName)
        let order: [String]
        var wavePlan: [WavePlan.Wave] = []
        if waves {
            let prio = byName.mapValues(\.priority)
            switch WavePlan.waves(targets: targets, nodes: nodes, priority: prio, queued: queued) {
            case .failure(let f):
                return .failed(f.message)
            case .success(let w):
                wavePlan = w
                order = w.flatMap(\.tasks)
            }
        } else {
            switch DependencyPlan.order(targets: targets, nodes: nodes, queued: queued) {
            case .failure(let f):
                return .failed(f.message)
            case .success(let o):
                order = o
            }
        }
        let extra = order.filter { !targets.contains($0) }
        let now = Date(), mode = dangerMode()
        // Every missing task must be the person's own: `source:` text is never queued silently.
        let autoExtra = autoDependencies && !extra.isEmpty && extra.allSatisfy { name in
            guard let t = byName[name] else { return false }
            return mode.allows(.addDependency, .init(foreign: !t.source.isEmpty), project: project.url.path, now: now)
        }
        if !extra.isEmpty && !confirmed && !autoExtra {
            return .needsDependencies(extra: extra.compactMap { byName[$0] }, plan: order.compactMap { byName[$0] })
        }
        // Nothing is queued when one of the tasks can't be.
        for name in order {
            guard let t = byName[name] ?? tasks.first(where: { $0.fileName == name }), !t.repos.isEmpty else { continue }
            if let v = TaskVerify.load(taskAt: t.url), v != .none { return .failed("«\(t.title)»: \(TaskVerifyGate.reposReason)") }
            if t.mainFolderOnly { return .failed("«\(t.title)»: repos не совместимо с worktree: never") }
            if case .failure(let f) = TaskRepos.resolve(t.repos, root: projectsRoot(), project: project.url) { return .failed("«\(t.title)»: \(f.message)") }
        }
        // All or nothing: every pipeline is read before anything is queued.
        var pipelines: [String: WorkflowFile] = [:]
        for name in order {
            guard let t = byName[name] ?? tasks.first(where: { $0.fileName == name }), !t.workflow.isEmpty,
                  job(forTask: t.id) == nil else { continue }
            switch pipeline(of: t, in: project) {
            case .failure(let e): return .failed("«\(t.title)»: \(e.message)")
            case .success(let f): pipelines[name] = f
            }
        }
        let gitNote = ensureGit(project.id)
        if !pipelines.isEmpty, !Worktrees.hasCommits(project.url) {
            return .failed("Пайплайн идёт только в worktree, а в проекте нет git или коммитов")
        }
        var previous: UUID?
        var added: [Job] = []
        var waveJobs: [[UUID]] = Array(repeating: [], count: wavePlan.count)
        let waveOf = Dictionary(wavePlan.enumerated().flatMap { i, w in w.tasks.map { ($0, i) } },
                                uniquingKeysWith: { a, _ in a })
        for name in order {
            guard let t = byName[name] ?? tasks.first(where: { $0.fileName == name }),
                  job(forTask: t.id) == nil else { continue }
            let job = Job(kind: .runTask, title: t.title, projectID: project.id, projectName: project.displayName,
                         cwd: project.url, prompt: ClaudePrompts.runTask(t),
                         systemPrompt: ClaudePrompts.codingSystem(name: project.displayName, path: project.url.path),
                         taskPath: t.id)
            if let gitNote { job.log.append("⚙︎ " + gitNote) }
            if autoExtra, !confirmed, extra.contains(name) { danger(job, "добавлена как зависимость без вопроса") }
            if !project.verify.isEmpty { job.verifyCommand = project.verify }
            job.profile = t.agent
            job.evidenceAsked = true
            job.alwaysWorktree = project.alwaysWorktree
            job.mustUseMain = t.mainFolderOnly
            job.files = t.files
            job.taskPriority = t.priority
            job.repos = t.repos
            if Self.wantsPlan(t) { job.planPhase = .planning }
            if chain, !waves, let previous { job.dependsOn.append(previous) }
            if let wi = waveOf[name] {
                job.wave = wi + 1
                job.waveCount = wavePlan.count
                job.wavePriority = wavePlan[wi].priority
                if wi > 0 { job.dependsOn.append(contentsOf: waveJobs[wi - 1]) }
                waveJobs[wi].append(job.id)
            }
            // `depends:` in the task file → wait for every unfinished dependency's job.
            for d in t.depends {
                guard let dep = byName[d], dep.status != .done,
                      let dj = blockingJob(forTask: dep.id), !job.dependsOn.contains(dj.id) else { continue }
                job.dependsOn.append(dj.id)
            }
            if let f = pipelines[name] { beginPipeline(job, name: f.name, workflow: f.workflow) }
            previous = job.id
            add(job)
            added.append(job)
        }
        return .queued(added)
    }

    struct PipelineError: Error { let message: String }

    /// The task's `workflow:` as it is on disk now, or why it can't be started.
    private func pipeline(of t: TaskItem, in project: Project) -> Result<WorkflowFile, PipelineError> {
        func no(_ m: String) -> Result<WorkflowFile, PipelineError> { .failure(.init(message: "пайплайн «\(t.workflow)»: \(m)")) }
        guard AgentProfile.isValidID(t.workflow) else { return no("неверное имя") }
        if t.mainFolderOnly { return no("идёт только в worktree, а в задаче worktree: never") }
        if !Worktrees.enabled { return no("идёт только в worktree, а они выключены в Настройках") }
        switch WorkflowFile.load(WorkflowFile.url(t.workflow, in: project.url)) {
        case .failure(let e): return no(e.message)
        case .success(let f):
            if !f.errors.isEmpty { return no(f.errors.joined(separator: "; ")) }
            if t.plan, !f.workflow.steps.contains(where: { $0.type == .plan }) { return no("в задаче plan: true, а шага plan в нём нет") }
            return .success(f)
        }
    }
}
