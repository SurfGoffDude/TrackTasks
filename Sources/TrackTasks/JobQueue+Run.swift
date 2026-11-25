import Foundation
import TrackTasksCore

extension JobQueue {
    // MARK: Running

    static let autoModelKey = "jobsAutoModel"
    static var autoModel: Bool { UserDefaults.standard.object(forKey: autoModelKey) as? Bool ?? true }

    func start(_ job: Job) {
        guard let agent = settleAgent(job) else { return }
        if let why = worktreeRefusal(job) { return failStart(job, why) }
        let can = capabilities(job)
        if job.remoteUnclaimed {
            job.log.append("⚙︎ Подключаюсь к запуску на сервере")
            return run(job, model: job.model ?? .auto, prompt: nil, resume: job.sessionID, fork: false, resumeAt: nil)
        }
        if job.kind == .reply, job.limitWait == nil { return startReply(job) }
        if job.executor == .docker {
            if let why = containerRefusal(job) { return failStart(job, why) }
            // Before setup: it runs in the container too.
            if let w = job.worktree {
                do { try ContainerStore.shared.mark(w) } catch { return failStart(job, error.localizedDescription) }
            }
        }
        if setupBeforeStart(job) { return }
        if let h = job.pendingHandoff { return startHandoff(job, h) }
        if job.guardsReview, job.planBaseline == nil, !can.contains(.remote) { return snapshotThenReview(job) }
        if job.planPhase == .planning, job.planBaseline == nil, !can.contains(.remote) { return snapshotThenStart(job) }
        if let w = job.limitWait { return continueAfterLimit(job, w) }
        guard job.lane == .code || job.planPhase == .planning else { return launch(job, model: .background) }
        if job.planPhase == .planning, !job.planFeedback.isEmpty, can.contains(.resume), let sid = job.sessionID {
            // Rework: the same session sees its old plan and the comment.
            job.resumedParent = true
            return launch(job, model: job.model ?? .sonnet, prompt: ClaudePrompts.planRework(job.planFeedback), resume: sid)
        }
        if job.kind == .runTask, can.contains(.resumeAt), let r = job.rewind, let sid = r.session {
            job.resumedParent = true
            job.log.append("⚙︎ Продолжает сессию \(sid.prefix(8))… с точки отката (новая сессия)")
            return launch(job, model: job.model ?? .sonnet, resume: sid, fork: true, resumeAt: r.point)
        }
        if can.contains(.fork), let src = job.forkSession, job.sessionID == nil, job.resumeSession == nil {
            job.resumedParent = true
            job.log.append("⚙︎ Ответвление сессии \(src.prefix(8))… (--resume --fork-session)")
            return launch(job, model: job.model ?? .sonnet, resume: src, fork: true)
        }
        if job.kind == .fix {
            // Same model as the task (keeps the session's cache); no Haiku run for a fix.
            let m = job.model ?? self.job(job.parentID)?.model ?? fixModel(job)
            let resume = fixSession(job)
            job.resumedParent = resume != nil
            return launch(job, model: m, resume: resume)
        }
        // The code run continues the session that wrote the plan (claude keeps sessions per working directory).
        if PlanFlow.resumesPlanSession(job.planPhase, inMainFolder: job.worktree == nil), job.resumeSession == nil,
           can.contains(.resume), let sid = job.sessionID {
            job.resumedParent = true
            job.log.append("⚙︎ Продолжает сессию плана (--resume \(sid.prefix(8))…)")
            return launch(job, model: job.model ?? .sonnet, resume: sid)
        }
        // The profile names the model, or the agent has no models the tracker can pick.
        guard job.profileModel.isEmpty, can.contains(.autoModel) else { return launch(job, model: .auto) }
        guard Self.autoModel else { return launch(job, model: .current) }
        // Size and obvious cases decide without asking Haiku.
        let t = job.taskPath.flatMap { Codec.task(at: URL(fileURLWithPath: $0)) }
        switch ModelPick.heuristic(title: t?.title ?? job.title, body: t?.body ?? "", size: t?.size ?? "") {
        case .sonnet(let why): job.modelReason = why; launch(job, model: .sonnet)
        case .opus(let why): job.modelReason = why; launch(job, model: .opus)
        case .ask: classify(job, agent)
        }
    }

    /// Haiku reads the task and picks Sonnet (routine) or Opus (hard). The slot is held meanwhile.
    private func classify(_ job: Job, _ agent: any Agent) {
        let text = job.taskPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? job.title
        let prompt = """
        Выбери модель для выполнения задачи программирования. Ответь строго в формате «sonnet: причина» или «opus: причина», причина — до 8 слов.
        sonnet — типовая или небольшая задача: правка UI, мелкая фича, понятный баг, рефакторинг в 1–3 файлах, тексты, конфиги.
        opus — сложная задача: архитектура, много файлов, неясная причина бага, конкурентность, алгоритмы, безопасность, миграции данных, исследование.

        Проект: \(job.projectName)
        Задача:
        \(String(text.prefix(6000)))
        """
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let p = agent.makeRun()
        p.onExit = { [weak self, weak job] s in
            guard let self, let job else { return }
            job.proc = nil
            self.recordSpend(s, job.projectName, "Выбор модели", self.spendTask(job))
            self.pipelineTask(job)?.pipeline?.cost.add(s.costUSD)
            if s.stopped {
                job.state = .cancelled
                job.finishedAt = Date()
                self.releaseWorktree(job)
                self.pipelineStepEnded(job, .cancelled, changed: false, commitError: nil)
                self.onFinished?(job)
                self.pump()
                return
            }
            let answer = s.resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = answer.lowercased()
            let m: ClaudeModel = lower.hasPrefix("opus") || (!lower.hasPrefix("sonnet") && lower.contains("opus")) ? .opus : .sonnet
            if s.failed || answer.isEmpty {
                job.modelReason = "Haiku не ответил — по умолчанию"
                self.launch(job, model: .sonnet)
                return
            }
            if let colon = answer.firstIndex(of: ":") {
                job.modelReason = answer[answer.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            self.launch(job, model: m)
        }
        do {
            try p.start(AgentRequest(cwd: dir, prompt: prompt, model: ClaudeModel.haiku.alias, access: .answer,
                                     isolated: ClaudeOptions.isolateBackground))
            job.proc = p
            job.state = .running
            job.lastLine = "Haiku выбирает модель…"
            onStarted?(job)
        } catch {
            launch(job, model: .current)
        }
    }

    /// Fresh worktree jobs that never produced anything get cleaned up.
    private func releaseWorktree(_ job: Job) {
        // A pipeline keeps it: an earlier step may have worked there, «↻» goes on in it.
        guard let w = job.worktree, job.kind == .runTask, job.sessionID == nil, job.pipeline == nil, !job.remoteUnclaimed, !job.members.contains(where: \.committed),
              job.resumeSession == nil, job.rewind == nil, job.handoffs.isEmpty,
              !jobs.contains(where: { $0 !== job && $0.worktree?.path == w.path }) else { return }
        dropWorktrees(job)
    }

    /// One turn of the agent. In a worktree the code is saved first (`turn` names the checkpoint).
    func launch(_ job: Job, model: ClaudeModel, prompt override: String? = nil, resume: String? = nil, fork: Bool = false,
                resumeAt: String? = nil, turn: String? = nil, checkpoint: Bool = true) {
        job.model = agents[job.agentID]?.capabilities.contains(.autoModel) == true && job.profileModel.isEmpty ? model : nil
        // Before the checkpoint: it keeps everything git doesn't ignore.
        if let w = job.worktree, !shots(job).isEmpty {
            do { try PreviewFolder.protect(w.path) } catch { return failStart(job, "Папка снимков недоступна: \(error.localizedDescription)") }
        }
        guard checkpoint, job.isCodeTask, let w = job.worktree else {
            return run(job, model: model, prompt: override, resume: resume, fork: fork, resumeAt: resumeAt)
        }
        let sid = resume ?? job.resumeSession
        checkpointThen(job, w, label: turn ?? Self.turnLabel(job, resumes: sid != nil), resume: sid, resumeAt: resumeAt) { [weak self] in
            self?.run(job, model: model, prompt: override, resume: resume, fork: fork, resumeAt: resumeAt)
        }
    }

    /// Cancelled while its checkpoint was being saved: claude was never started.
    func cancelledBeforeTurn(_ job: Job) {
        if handoffNotStarted(job, "передача отменена") { return }
        releaseWorktree(job)
        job.lastLine = ""
        finish(job, .cancelled)
    }

    private func run(_ job: Job, model: ClaudeModel, prompt override: String?, resume: String?, fork: Bool, resumeAt: String?) {
        guard let agent = agents[job.agentID] else { return failStart(job, Self.noAgent(job.agentID)) }
        let can = capabilities(job)
        if let why = worktreeRefusal(job) { return failStart(job, why) }
        // The last line of defence: replies, fixes and main-folder jobs get here too.
        if job.lane == .code, job.worktree == nil, requiresWorktree(job) {
            return failStart(job, "\(pipelineTask(job) == nil ? agent.title : "Пайплайн") правит код только в worktree, а задача идёт в основной папке")
        }
        if job.kind == .runTask, job.lane == .code, !job.repos.isEmpty, job.worktree == nil {
            return failStart(job, "Задача на несколько репозиториев идёт только в worktree")
        }
        let box = job.executor == .docker || ContainerStore.shared.isContainer(job.runDir)
        if box, let why = containerRefusal(job, fork: fork) { return failStart(job, why) }
        var remote: AgentRemote?
        if can.contains(.remote) {
            switch remoteRequest(job) {
            case .success(let r): remote = r
            case .failure(let e): return failStart(job, e.message)
            }
        }
        let p: any AgentRun
        if box {
            // Never the host instead.
            guard let docker, let w = job.worktree else { return failStart(job, "executor: docker — Docker не настроен") }
            p = DockerAgentRun(.init(host: docker, worktree: w, taskFile: job.taskPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                                     returnsTask: job.kind != .review,
                                     reviewBase: job.kind == .review && !job.baseCommit.isEmpty ? job.baseCommit : nil))
        } else { p = agent.makeRun() }
        if let p = p as? any RemoteAgentRun { watchRemote(job, p) }
        if let p = p as? any ACPFeaturesRun {
            p.onFeatures = { [weak self, weak job] f in
                guard let job, job.acpFeatures != f else { return }
                job.acpFeatures = f
                self?.save()
            }
        }
        p.onPermission = { [weak self, weak job] r in
            guard let job else { return }
            job.permissions.append(r)
            if self?.autoAnswer(job, r) == true { return }
            job.lastLine = "Ждёт разрешения: " + r.title
            Attention.request()
            Notifier.shared.permission(r, job: job)
            PhonePush.send(.permission, job: job, wait: .permission)
        }
        if job.kind == .reply { p.onTurnStarted = { [weak self, weak job] in if let job { self?.replyAccepted(job) } } }
        let handoff = job.pendingHandoff != nil
        if handoff { p.onTurnStarted = { [weak self, weak job] in if let job { self?.handoffAccepted(job) } } }
        p.onEvent = { [weak job] e in
            guard let job else { return }
            switch e {
            case .text(let t):
                job.log.append(t)
                job.lastLine = t.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            case .tool(let t):
                job.log.append("⚙︎ " + t)
                job.lastLine = t
            }
        }
        p.onExit = { [weak self, weak job] s in
            guard let self, let job else { return }
            self.agentExited(job, s)
        }

        let isCode = job.lane == .code
        // Asked anew for every run: after the term a retry or a resumed session has ordinary rights.
        let bypass = can.contains(.bypass) && allows(.fullAccess, job)
        job.fullAccess = bypass
        if isCode { folderUsed(by: job) }
        job.outlivedNoted = false
        if bypass { danger(job, "полный доступ (--dangerously-skip-permissions)") }
        let planning = job.planPhase == .planning
        var prompt = override ?? job.prompt
        var system = job.systemPrompt
        if planning {
            system += ClaudePrompts.planSystem
            if override == nil { prompt = ClaudePrompts.planOnly(prompt, feedback: job.planFeedback) }
        } else if job.planPhase == .approved, !handoff {
            prompt = ClaudePrompts.approved(prompt)
        }
        if override == nil { prompt += stepPrompt(job) }
        var addDirs: [URL] = []
        if box, let w = job.worktree {
            func inside(_ s: String) -> String {
                s.replacingOccurrences(of: w.path.path, with: ContainerSpec.workspace)
                    .replacingOccurrences(of: job.cwd.path, with: ContainerSpec.workspace)
            }
            // Of a handover exactly the shown text goes.
            if !handoff { prompt = inside(prompt) }
            system = inside(system) + Self.containerSystem
            if job.kind == .review {
                prompt += "\n\nИстории git здесь нет: изменения задачи (вместо git diff) лежат в файле \(ContainerSpec.workspace)/\(DockerAgentRun.reviewDiff)."
            }
        } else if let w = job.worktree {
            // Tracker files stay in the main folder; code changes go to the worktree branch.
            if let tp = job.taskPath, !handoff {
                prompt = prompt.replacingOccurrences(of: "tasks/" + URL(fileURLWithPath: tp).lastPathComponent, with: tp)
            }
            system += """


            ВАЖНО: ты работаешь в отдельном git worktree \(w.path.path) (ветка \(w.branch)), параллельно с другими задачами.
            Код меняй только здесь, в текущей папке. Коммитить не нужно — это сделает трекер.
            Файл задачи, about.md и spectrack.md бери из основной папки проекта \(job.cwd.path) (абсолютные пути), а не из копии в worktree.
            Worktree создан от последнего коммита: незакоммиченных правок из основной папки здесь нет.
            НЕ копируй исходники из основной папки в worktree. Если нужного для задачи кода здесь нет
            (он, видимо, ещё не закоммичен в основной папке) — не делай задачу, остановись и сообщи об этом в ответе.
            """
            addDirs = [job.cwd.appendingPathComponent("tasks", isDirectory: true)]
            let task = group(job)
            if !task.parts.isEmpty {
                system += ClaudePrompts.reposSystem(task)
                // Both agents may write to such a folder: only for code runs.
                if isCode { addDirs += task.parts.compactMap(\.worktree?.path) }
            }
        }
        if planning, job.parts.isEmpty, !job.repoFolders.isEmpty { system += ClaudePrompts.reposPlanning(job.repoFolders) }
        let resumeID = can.contains(.resume) ? resume ?? job.resumeSession : nil
        if override == nil, job.resumeSession == nil, !job.handoffs.isEmpty, !planning {
            prompt = "Работа над задачей уже начата, возможно другим агентом. Проверь по файлам, что уже сделано, и доведи задачу до конца по исходной инструкции:\n\n" + prompt
        }
        if override == nil, job.resumeSession != nil {
            prompt = "Работа над задачей была прервана. Проверь, что уже сделано, и доведи задачу до конца по исходной инструкции:\n\n" + prompt
        }
        // Claude's light jobs have their own cheap model in Settings; other agents know only the profile's one.
        let picksModel = can.contains(.autoModel)
        let modelName = job.profileModel.isEmpty || (picksModel && !isCode && !planning && job.pipelineStep.isEmpty) ? (picksModel ? model.alias : "") : job.profileModel
        var images: [Data] = []
        // Only with the message itself, not with a failed check sent after it.
        if remote?.attach != true, override.map({ $0.contains(job.prompt) }) ?? true {
            do {
                for s in shots(job).prefix(PreviewFolder.maxPerMessage) {
                    guard let w = job.worktree else { throw PreviewFolder.Failure(message: "Снимок элемента удалён вместе с worktree, сообщение не отправлено") }
                    let d = try PreviewFolder.read(s, in: w.path)
                    if can.contains(.images) { images.append(d) }
                }
            } catch {
                return failStart(job, error.localizedDescription)
            }
        }
        let request = AgentRequest(
            cwd: job.runDir, prompt: prompt, systemPrompt: system,
            model: modelName, access: isCode ? .coding : .planning,
            resume: resumeID,
            fork: fork && resumeID != nil && resume != nil,
            resumeAt: fork && resumeID != nil && resume != nil ? resumeAt : nil,
            bypassPermissions: bypass,
            addDirs: addDirs,
            isolated: can.contains(.isolation) && ClaudeOptions.isolateBackground,
            remote: remote,
            acp: job.acp,
            images: images
        )
        let wasRunning = job.state == .running
        job.stopAsked = false
        // On disk before the process: after a crash in between the message may have arrived.
        let marked = markLaunched(job)
        if handoff {
            // A crash from here on must not send the text again by itself.
            job.state = .running
            saveNow()
        }
        do {
            try p.start(request)
            job.proc = p
            job.state = .running
            job.resumeSession = nil
            if (isCode || planning) && (override == nil || handoff) {
                job.lastLine = (planning ? "План · " : "") + "Модель: \(job.modelTitle ?? "по умолчанию (\(agent.title))")" + (job.modelReason.isEmpty ? "" : " — \(job.modelReason)")
            }
            if !wasRunning { onStarted?(job) }
        } catch {
            if marked { unmarkLaunched(job) }
            if remote?.attach == false { job.remote?.returned = true }
            failStart(job, error.localizedDescription)
        }
        save()
    }

    /// The agent was never started.
    func failStart(_ job: Job, _ error: String) {
        if handoffNotStarted(job, error) { return }
        job.state = .failed
        job.lastLine = error
        job.finishedAt = Date()
        releaseWorktree(job)
        settleReply(job)
        if job.pipeline != nil { pipelineStepEnded(job, .failed, changed: false, commitError: nil) }
        onFinished?(job)
        save()
        pump()
    }

    private static func noAgent(_ id: AgentID) -> String { "Агент «\(id.rawValue)» не поддерживается этой версией TrackTasks" }

    /// Agent of the job. The profile is looked up once, at the first start; later runs keep that agent: it has the
    /// session. An unknown profile or agent fails the job — never a silent switch to another one.
    private func settleAgent(_ job: Job) -> (any Agent)? {
        if let why = Self.executorRefusal(job, docker: docker != nil) ?? repoExecutorRefusal(job) ?? remoteRefusal(job) {
            failStart(job, why)
            return nil
        }
        let wasLocal = job.executor != .docker
        markExecutor(job)
        if wasLocal, job.executor == .docker, job.worktree == nil, job.lane == .code, job.kind == .runTask {
            // Changed in about.md while it waited: the planner makes a worktree.
            pump()
            return nil
        }
        if job.agent == nil {
            guard let p = profiles().resolve(job.profile) else {
                failStart(job, "Профиль агента «\(job.profile)» не найден — проверь `agent:` в задаче или Настройки → «Агенты»")
                return nil
            }
            job.agent = p.agent
            let own = pipelineStep(job)?.model ?? ""
            job.profileModel = own.isEmpty ? p.model : own
            job.server = p.server
            job.acp = p.acp
            job.acpFeatures = nil
        }
        guard let a = agents[job.agentID] else {
            failStart(job, Self.noAgent(job.agentID))
            return nil
        }
        return a
    }

    /// The same for the other repositories of the task: isolation asked for by any of them is not skipped.
    private func repoExecutorRefusal(_ job: Job) -> String? {
        for f in folders(job).dropFirst() where Executor.resolve(projectAt: f, task: nil) != .use(.local) {
            return "executor в about.md репозитория «\(f.lastPathComponent)»: без изоляции задача не запускается"
        }
        return nil
    }

    private static func hasExecutor(_ job: Job) -> Bool { job.kind != .updateAbout && job.kind != .quickAdd }

    private static func chosenExecutor(_ job: Job) -> Executor.Choice {
        // Kept by the job or by its folder: about.md can't weaken it any more.
        if job.executor == .docker || ContainerStore.shared.isContainer(job.runDir) { return .use(.docker) }
        return Executor.resolve(projectAt: job.cwd, task: job.taskPath.map { URL(fileURLWithPath: $0) })
    }

    /// Only towards isolation. Without docker nothing is remembered: the start is refused.
    func markExecutor(_ job: Job) {
        guard docker != nil, Self.hasExecutor(job), Self.chosenExecutor(job) == .use(.docker) else { return }
        job.executor = .docker
    }

    /// Why this job can't go to a container; it never goes to the host instead.
    private func containerRefusal(_ job: Job, fork: Bool = false) -> String? {
        guard docker != nil else { return "executor: docker — Docker не настроен (Настройки → Docker); без изоляции задача не запускается" }
        if agents[job.agentID]?.capabilities.contains(.container) != true { return "\(agentTitle(job)) не работает в контейнере" }
        if job.planPhase == .planning { return "План идёт в основной папке, а её нельзя подключить к контейнеру — поставь задаче plan: false" }
        if job.resolvesMerge { return "Слияние веток в контейнере не делается: истории git там нет — разреши конфликт вручную" }
        if !folders(job).dropFirst().isEmpty { return "Задача на несколько репозиториев в контейнере не выполняется: подключается только один worktree" }
        if fork { return "Ответвление и откат разговора в контейнере не поддерживаются" }
        guard job.worktree != nil else { return "executor: docker работает только в worktree" }
        return nil
    }

    static let containerSystem = """


        ВАЖНО: ты работаешь в контейнере, доступна только папка /workspace (git worktree задачи). Код меняй здесь, коммитить не нужно — это сделает трекер.
        Файл задачи (tasks/…), about.md и spectrack.md лежат в /workspace; обратно переносится только файл задачи.
        Истории git нет: в репозитории один снимок, сделанный перед этим ходом, `git diff` показывает только правки этого хода.
        Программ и сети может не быть: если без них задачу не сделать — остановись и сообщи об этом.
        """

    /// «Проверить снова»: the container wasn't removed, or its folder didn't pass the check.
    func recheckContainer(_ job: Job) {
        guard let w = job.worktree, !job.isActive, let engine = docker?.engine ?? DockerEngine.find() else { return }
        Task { [weak self] in
            let why = await Task.detached(priority: .userInitiated) { ContainerStore.shared.check(w.path, engine) }.value
            job.worktreeNote = why ?? "Контейнер удалён, папка проверена"
            self?.save()
        }
    }

    /// Why the job may not start where it was asked to: a task that asked for isolation never falls back silently.
    static func executorRefusal(_ job: Job, docker: Bool = false) -> String? {
        guard hasExecutor(job) else { return nil }
        switch chosenExecutor(job) {
        case .use(.local): return nil
        case .use(.docker): return docker ? nil : "executor: docker — Docker не настроен (Настройки → Docker); без изоляции задача не запускается"
        case .invalid(let v): return "executor: \(v) — допустимо local | docker (about.md или файл задачи)"
        }
    }

    func agentTitle(_ job: Job) -> String { agents[job.agentID]?.title ?? job.agentID.rawValue }

    func capabilities(_ job: Job) -> AgentCapabilities {
        var c = agents[job.agentID]?.capabilities ?? []
        // As the program itself announced; not known before its first answer.
        if job.agentID == .acp, job.acpFeatures?.canResume == true { c.insert(.resume) }
        guard job.executor == .docker else { return c }
        // Its sessions aren't among the host's ones; without the volume they don't outlive a run.
        return c.subtracting(docker?.sessions == true ? [.fork, .resumeAt] : [.fork, .resumeAt, .resume])
    }

    /// The job's agent edits code only in a worktree, and so does every pipeline. Before the first start the agent comes from the profile.
    func requiresWorktree(_ job: Job) -> Bool {
        if pipelineTask(job) != nil || job.executor == .docker { return true }
        guard let id = job.agent ?? profiles().resolve(job.profile)?.agent else { return false }
        return agents[id]?.capabilities.contains(.requiresWorktree) == true
    }

    /// Nothing tells whether an ACP agent asks before it acts: not even a plan or a reply runs in the main folder.
    func worktreeOnly(_ job: Job) -> Bool { job.agentID == .acp }

    private func worktreeRefusal(_ job: Job) -> String? {
        guard worktreeOnly(job) else { return nil }
        if job.planPhase == .planning {
            return "План идёт в основной папке, а \(agentTitle(job)) работает только в worktree — "
                + (pipelineTask(job) == nil ? "поставь задаче plan: false" : "выбери для шага плана другого агента")
        }
        return job.worktree == nil ? "\(agentTitle(job)) работает только в worktree, а этот запуск идёт в основной папке" : nil
    }

    /// Whether the limit guard applies to the job. Unknown agent or profile: it does (the safe side).
    func spendsGuardedLimit(_ job: Job) -> Bool {
        guard let id = job.agent ?? profiles().resolve(job.profile)?.agent, let a = agents[id] else { return true }
        return a.capabilities.contains(.guardedLimit)
    }

    /// Reviews, fixes and replies count towards their task.
    private func spendTask(_ job: Job) -> SpendTask? {
        guard let path = job.taskPath else { return nil }
        return SpendTask(title: self.job(job.parentID)?.title ?? job.title, file: (path as NSString).lastPathComponent)
    }

    private func agentExited(_ job: Job, _ s: AgentRunResult) {
        job.proc = nil
        job.permissions = []
        if job.pendingHandoff != nil {
            // A run left on a server may have begun.
            if job.remoteUnclaimed || s.turns > 0 || s.gotResult && !s.failed && !s.stopped && s.limit == nil {
                handoffAccepted(job)
            } else {
                job.cost.add(s.costUSD)
                recordSpend(s, job.projectName, kindTitle(job.kind), spendTask(job))
                if handoffNotStarted(job, s.stopped ? "передача отменена" : s.errorText) { return }
            }
        }
        // A fork that died before its first message still reports the source id: never adopt it.
        if let id = s.sessionID, id != job.forkSession, id != job.rewind?.session {
            job.sessionID = id
            if job.kind == .runTask { job.rewind = nil }
        }
        if job.kind == .reply { replyExited(job, s) }
        job.cost.add(s.costUSD)
        pipelineTask(job)?.pipeline?.cost.add(s.costUSD)
        job.summary = AgentRunResult.combine(job.summary, s.summary)
        recordSpend(s, job.projectName, kindTitle(job.kind), spendTask(job))
        if !s.model.isEmpty {
            job.log.append("⚙︎ Сессия: MCP-серверов \(s.mcpServers), инструментов mcp__: \(s.mcpTools)")
        }

        if let limit = s.limit, s.failed { return limitRefused(job, s, limit) }
        if job.resumedParent {
            job.resumedParent = false
            // The task's session may be missing or not resumable here (other cwd/settings):
            // nothing was done yet, so start the fix as a new session instead of failing.
            if s.failed, s.turns == 0, !s.cannotStart {
                job.log.append("⚙︎ Сессию задачи продолжить не удалось (\(s.errorText.prefix(200))) — новая сессия")
                job.sessionID = nil
                launch(job, model: job.model ?? .sonnet, checkpoint: false)
                return
            }
        }

        if s.stopped {
            finish(job, .cancelled)
        } else if s.failed {
            job.lastLine = (job.kind == .reply && s.turns == 0 ? "сессию продолжить не удалось. " : "") + s.errorText
            finish(job, .failed)
        } else if job.kind == .runTask, job.planPhase == .planning {
            planRunFinished(job)
        } else if job.isCodeTask, !(job.verifyCommand ?? "").isEmpty || !group(job).parts.isEmpty || hasTaskCheck(job) {
            verify(job, command: job.verifyCommand ?? "", model: job.model ?? .sonnet)
        } else if job.guardsReview {
            reviewRunFinished(job, text: s.resultText)
        } else {
            if job.kind == .review { applyReview(job, text: s.resultText) }
            finish(job, .done)
        }
    }

    func finish(_ job: Job, _ state: Job.State) {
        let task = group(job)
        let parts = job.isCodeTask ? commitParts(of: task, after: job, state) : (changed: false, failed: false, error: nil)
        var branchChanged = parts.changed
        var commitError = parts.error
        if let w = job.worktree, job.isCodeTask {
            if state == .done {
                let r = Worktrees.commitAll(w, message: "TrackTasks: \(job.title)")
                let owner = job.isFollowUp ? (self.job(job.parentID) ?? job) : job
                if r.ok {
                    owner.rolledBack = ""
                    // Whatever was left in the folder is in the branch now.
                    owner.mergeArtifacts = []
                }
                if !r.ok {
                    commitError = r.message
                    (job.kind == .reply ? owner : job).worktreeNote = "Не удалось закоммитить: \(r.message)"
                } else if r.out == "nothing" {
                    if job.kind == .runTask && !job.committed {
                        // The session lives in this folder: it stays while another repository of the task has work.
                        if parts.failed || job.parts.contains(where: \.committed) || !job.handoffs.isEmpty {
                            job.worktreeNote = "Код не изменился"
                        } else {
                            job.worktreeNote = "Код не изменился — worktree удалён"
                            Terminals.shared.closeAll(job.id)
                            // A pipeline may repeat the step: the same folder and branch, so only after they are gone.
                            job.worktreeBusy = job.pipeline != nil
                            dropWorktrees(job) { [weak self] in self?.emptyWorktreeRemoved(job) }
                        }
                    }
                } else {
                    branchChanged = true
                    owner.committed = true
                    // New work after the merge of this repository: it waits for a merge again.
                    if !owner.parts.isEmpty { owner.merged = false }
                    owner.worktreeNote = "Изменения в ветке \(w.branch)"
                    if job.kind == .fix { job.worktreeNote = "Исправления добавлены в ветку \(w.branch)" }
                }
            } else {
                // A reply that never started left nothing behind.
                let owner = job.kind == .reply ? (job.sessionID == nil ? job : self.job(job.parentID) ?? job) : job
                owner.worktreeNote = "Незавершённые изменения остались в \(w.branch)"
                // The agent may have written to files of the list: they are work now and block a merge.
                if job.isFollowUp, job.sessionID != nil { self.job(job.parentID)?.mergeArtifacts = [] }
            }
        }
        if job.resolvesMerge, state == .done {
            if let owner = self.job(job.parentID) {
                let parent = member(owner, job.targetRepo)
                parent.mergeFailed = false
                parent.mergeCheck = nil
                // Main is in the branch now: the task's own diff starts from there.
                if let w = parent.worktree ?? job.worktree {
                    let b = Worktrees.git(["merge-base", "HEAD", "refs/heads/\(w.branch)"], in: w.main)
                    if b.ok { parent.baseCommit = b.out.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                parent.worktreeNote = "Конфликт разрешён в ветке — можно сливать"
            } else {
                // Main folder fixed: jobs that were blocked by it can merge again.
                let p = job.cwd.standardizedFileURL.path
                for j in allMembers where j.mainConflict && j.cwd.standardizedFileURL.path == p {
                    j.mainConflict = false
                    j.worktreeNote = "Основная папка исправлена — можно сливать"
                }
            }
        }
        var reviewParent: Job?
        if job.kind == .reply, job.isCodeTask, state == .done, let parent = self.job(job.parentID) {
            parent.verifyFailed = job.verifyFailed
            if !job.verifyNote.isEmpty { parent.verifyNote = job.verifyNote }
            // The agent finished the turn: an interrupted task is completed by the reply, as by a normal run.
            parent.state = .done
            parent.interrupted = false
            // In a worktree we know whether the reply changed anything; the main folder is always re-reviewed.
            if job.worktree == nil ? !Git.diffStat(job.cwd).isEmpty : branchChanged {
                // The old verdict is about other code.
                parent.review = ""
                parent.verdict = nil
                parent.reviewFixed = false
                parent.mergeCheck = nil
                reviewParent = parent
            }
        }
        if job.kind == .fix, state == .done, let parent = self.job(job.parentID) {
            if job.fixesMergeCheck {
                let repo = member(parent, job.targetRepo)
                if job.verifyFailed {
                    // The red check stays: «Исправить» again or «Слить», which checks anew.
                    repo.worktreeNote = "Исправить не удалось: " + job.verifyNote
                } else {
                    repo.mergeCheck = nil
                    repo.worktreeNote = "Проверка исправлена в ветке — можно сливать"
                }
            } else if !job.resolvesMerge { parent.reviewFixed = true }
            // Repaired code was not reviewed.
            if job.fixesMergeCheck || job.resolvesMerge, onAutopilot(parent) {
                parent.verdict = nil
                parent.reviewFixed = false
            }
            parent.verifyFailed = job.verifyFailed
            parent.verifyNote = job.verifyNote.isEmpty ? parent.verifyNote : job.verifyNote
            // The fix job doesn't own the shared worktree.
            job.worktree = nil
        }
        if job.kind == .review { job.worktree = nil }
        job.state = state
        job.finishedAt = Date()
        settleReply(job)
        refreshTaskCheck(group(job))
        onFinished?(job)
        let carriedAnswers = job.kind == .reply && state == .done && self.job(job.parentID)?.questions?.sending == job.id
        let asking = questionsAfterTurn(job, state)
        let asks = asking.map(awaitsAnswers) ?? false
        let noted = asking.map(noteQuestions) ?? false
        if !noted || state != .done { notifyFinished(job) }
        // A pipeline has its own reviews and fixes.
        pipelineStepEnded(job, state, changed: branchChanged, commitError: commitError)
        if state == .done, job.kind == .runTask, job.pipeline == nil, !asks, Self.autoReview, job.worktree != nil || !Git.diffStat(job.cwd).isEmpty {
            requestReview(job)
        }
        // The review was put off until the answers, also when they changed nothing.
        if carriedAnswers, reviewParent == nil, let p = asking, p.verdict == nil, p.review.isEmpty,
           p.worktree != nil || !p.hadWorktree && !Git.diffStat(p.cwd).isEmpty { reviewParent = p }
        if let reviewParent, reviewParent.pipeline == nil, !asks, Self.autoReview { requestReview(reviewParent) }
        if job.kind == .review, state == .done, let task = self.job(job.parentID) { autoFix(task) }
        save()
        pump()
    }

    private func emptyWorktreeRemoved(_ job: Job) {
        if job.pipeline != nil { job.worktreeBusy = false }
    }

    private func notifyFinished(_ job: Job) {
        // Steps of a pipeline: told when it stops or ends.
        if job.pipeline != nil || !job.pipelineStep.isEmpty { return }
        switch (job.kind, job.state) {
        case (.review, .done):
            guard let p = self.job(job.parentID) else { return }
            Notifier.shared.post(title: p.verdict == .ok ? "Ревью: можно сливать" : "Ревью: есть замечания",
                                 body: "\(p.projectName): \(p.title)", jobID: p.id,
                                 canMerge: p.verdict == .ok && p.members.contains { $0.ownAwaitsMerge && !$0.hasLivePR })
        case (.reply, .done):
            PhonePush.send(.done, job: job, verifyFailed: job.verifyFailed)
            Notifier.shared.post(title: job.verifyFailed ? "Агент ответил, но проверка не прошла" : "Агент ответил",
                                 body: "\(job.projectName): \(job.title)", jobID: job.parentID ?? job.id)
        case (_, .done) where job.isCodeTask:
            PhonePush.send(.done, job: job, verifyFailed: job.verifyFailed)
            Notifier.shared.post(title: job.verifyFailed ? "Готово, но проверка не прошла" : "Задача выполнена",
                                 body: "\(job.projectName): \(job.title)", jobID: job.id,
                                 canMerge: job.members.contains { $0.ownAwaitsMerge && !$0.hasLivePR } && !Self.autoReview)
        case (_, .failed):
            PhonePush.send(.failed, job: job)
            Notifier.shared.post(title: "Задача не выполнена", body: "\(job.projectName): \(job.title)", jobID: job.id)
        default:
            break
        }
    }

    func kindTitle(_ k: Job.Kind) -> String {
        switch k {
        case .runTask: "Выполнение задачи"
        case .updateAbout: "about.md"
        case .quickAdd: "Быстрая задача"
        case .review: "Ревью"
        case .fix: "Исправление по ревью"
        case .reply: "Ответ агенту"
        }
    }
}
