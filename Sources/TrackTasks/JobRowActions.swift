import SwiftUI
import TrackTasksCore

extension JobRow {
    /// Windows of «Ещё»: shown from its button, a menu item can't hold a popover.
    enum Panel: String, Identifiable {
        case fork, checkpoints, server
        var id: String { rawValue }
    }

    /// The main action, the frequent ones with their names, the rest in «Ещё».
    @ViewBuilder
    func actions(_ offers: [JobAction: JobOffer], _ guide: JobGuide) -> some View {
        let main = guide.primary
        let frequent = JobAction.allCases.filter { $0 != main && $0.place == .visible && $0 != .fixReview && offers[$0] != nil }
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 6) {
                if let main, let o = offers[main] {
                    actionButton(main, o)
                        .buttonStyle(.glassProminent)
                        .tint(main == .fixCheck ? .red : nil)
                }
                ForEach(frequent) { a in
                    if let o = offers[a] { actionButton(a, o).buttonStyle(.glass) }
                }
                // A running server must be seen without opening the menu.
                if DevServers.shared.isRunning(in: job.runDir), let o = offers[.server] {
                    actionButton(.server, o).buttonStyle(.glass)
                }
                if offers.keys.contains(where: { $0 != main && $0.place != .visible }) { moreMenu(offers, main) }
            }
            // The main action's reason is in «Дальше».
            ForEach(blockedReasons(frequent, offers), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func blockedReasons(_ list: [JobAction], _ offers: [JobAction: JobOffer]) -> [String] {
        var order: [String] = [], names: [String: [String]] = [:]
        for a in list {
            guard let o = offers[a], let why = o.blocked else { continue }
            if names[why] == nil { order.append(why) }
            names[why, default: []].append("«\(o.title)»")
        }
        return order.map { "Недоступно \(names[$0]!.joined(separator: ", ")): \($0)" }
    }

    @ViewBuilder
    private func actionButton(_ a: JobAction, _ o: JobOffer) -> some View {
        let b = Button { perform(a) } label: { Label(o.title, systemImage: o.icon).labelStyle(.titleAndIcon) }
            .disabled(o.blocked != nil)
            .help(o.blocked ?? o.help)
        if a == .approveScripts, let s = job.scriptApproval {
            b.popover(isPresented: $showScripts) { scriptsSheet(s) }
        } else if a == .approveTaskCheck {
            b.popover(item: $taskCheckShown) { taskCheckSheet($0) }
        } else {
            b
        }
    }

    private func moreMenu(_ offers: [JobAction: JobOffer], _ main: JobAction?) -> some View {
        Menu {
            section("Работа", .work, offers, main)
            section("Изменения", .changes, offers, main)
            section("Задача", .task, offers, main)
            if offers[.discard] != nil {
                Divider()
                menuItem(.discard, offers[.discard]!)
            }
        } label: { Label("Ещё", systemImage: "ellipsis.circle").labelStyle(.titleAndIcon) }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .help("Остальные действия")
            .popover(item: $panel) { p in
                switch p {
                case .fork: forkSheet
                case .checkpoints: CheckpointsList(job: job)
                case .server: DevServerPanel(folder: job.runDir, main: job.cwd, branch: job.worktree?.branch ?? "", job: job.id)
                }
            }
    }

    @ViewBuilder
    private func section(_ title: String, _ place: JobAction.Place, _ offers: [JobAction: JobOffer], _ main: JobAction?) -> some View {
        let list = JobAction.allCases.filter { $0.place == place && $0 != main && offers[$0] != nil }
        if !list.isEmpty {
            Section(title) { ForEach(list) { a in if let o = offers[a] { menuItem(a, o) } } }
        }
    }

    private func menuItem(_ a: JobAction, _ o: JobOffer) -> some View {
        Button(role: a == .discard ? .destructive : nil) { perform(a) } label: {
            Label(o.title, systemImage: o.icon)
            if let why = o.blocked { Text(why) }
        }
        .disabled(o.blocked != nil)
    }

    private func perform(_ a: JobAction) {
        let q = store.jobs
        switch a {
        case .stop: q.cancel(job)
        case .approveScripts: showScripts = true
        case .approveTaskCheck: if let r = job.taskCheckRefusal, r.ask != nil { taskCheckShown = r }
        case .recheckMain: q.recheckInMain(job)
        case .retry: q.retry(job)
        case .startDespiteFiles: q.runDespiteSameFiles(job)
        case .startDespiteDirty: q.runDespiteDirtyMain(job)
        case .runInMain: q.runInMainFolder(job)
        case .mergeAll: q.merge(job)
        case .merge, .stopMerge, .resolveConflict, .fixCheck, .resolveMain, .pullRequest: store.performBranch(a, job)
        case .fixReview: q.requestFix(job)
        case .pullBase: q.pullBase(job)
        case .returnAutopilot: q.resumeAutopilot(job)
        case .diff: openWindow(id: DiffView.windowID, value: DiffSource(job: job))
        case .diffTerminal:
            let d = DiffSource(job: job)
            store.openTerminal(at: d.folder, command: d.terminalCommand)
        case .review: q.requestReview(job)
        case .fork: panel = .fork
        case .handoff: store.handoffJob = job
        case .checkpoints: panel = .checkpoints
        case .server: panel = .server
        case .resumeTerminal: if let id = job.sessionID { continueInTerminal(id, embedded: Terminals.embedded) }
        case .resumeExternal: if let id = job.sessionID { continueInTerminal(id, embedded: false) }
        case .terminal: toggleTerminal()
        case .terminalExternal: openExternal()
        case .commit: if let p = store.project(job.projectID) { store.commitProject = p }
        case .snapshot: store.snapshotJob = job
        case .openProject: if let pid = job.projectID { store.selectedID = pid }
        case .discard: q.discard(job)
        }
    }

    private func toggleTerminal() {
        let t = Terminals.shared
        if !Terminals.embedded { openExternal() }
        else if t.shown.contains(job.id) { t.shown.remove(job.id) }
        else if t.tabs(job).isEmpty { t.open(job, .shell) }
        else { t.shown.insert(job.id) }
    }

    private func openExternal() {
        Terminals.shared.markUsed(job)
        store.openTerminal(at: job.runDir)
    }

    func continueInTerminal(_ id: String, embedded: Bool) {
        let command = store.claudeCommand(resume: id)
        if embedded { Terminals.shared.open(job, .claude, command: command) }
        else {
            Terminals.shared.markUsed(job)
            store.openTerminal(at: job.runDir, command: command)
        }
    }

    private func scriptsSheet(_ s: WorktreeScripts) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Команды worktree из about.md").font(.headline)
            Text("Они выполняются в оболочке с твоими правами. Проверь, что ты им доверяешь; после любого изменения команды подтверждение спросят снова.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 360, alignment: .leading)
            ForEach(WorktreeScripts.Kind.allCases, id: \.self) { k in
                if !s.command(k).isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(k.title).font(.caption.bold())
                        Text(s.command(k)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Отмена") { showScripts = false }
                Button("Подтвердить и запустить") {
                    showScripts = false
                    store.jobs.approveScripts(job)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(14)
    }

    /// Approves exactly the text shown here, whatever the file holds by then.
    private func taskCheckSheet(_ r: TaskVerify.Refusal) -> some View {
        func code(_ title: String, _ text: String) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.bold())
                Text(text.isEmpty ? "поля нет" : text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        let new = r.ask ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            Text("Проверка задачи (verify)").font(.headline)
            Text("Выполняется после проверки проекта и перед слиянием — в оболочке с твоими правами, в Docker-задаче в контейнере. Подтверждается ровно этот текст; после любого изменения спросят снова. Опасный режим и автопилот его не подтверждают.")
                .font(.caption).foregroundStyle(.secondary)
            if job.foreignSource || job.scheduled {
                Label("Задача создана не тобой (импорт или автоматизация): команда могла прийти снаружи", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let a = r.approved { code("Подтверждено раньше", a) }
            else if let q = r.queued, !TaskVerify.same(q, new) { code("Было при постановке в очередь", q) }
            code(r.approved == nil && r.queued.map { TaskVerify.same($0, new) } != false ? "Команда" : "Сейчас в задаче", new)
            HStack {
                Spacer()
                Button("Отмена") { taskCheckShown = nil }
                Button(new.isEmpty ? "Подтвердить удаление" : "Подтвердить") {
                    taskCheckShown = nil
                    store.jobs.approveTaskCheck(job, r)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .frame(width: 400, alignment: .leading)
        .padding(14)
    }

    private var forkSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fork сессии").font(.headline)
            Text("Новая задача продолжит копию диалога с той же историей в своём worktree от ветки этой задачи. Исходная сессия и ветка не меняются.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)
            TextField("Что сделать иначе", text: $forkText, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Отмена") { panel = nil }
                Button("Ответвить") {
                    store.jobs.fork(job, prompt: forkText)
                    forkText = ""
                    panel = nil
                }
                .buttonStyle(.glassProminent)
                .disabled(forkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }

    /// Link from a fork to its source and back.
    @ViewBuilder var forkLinks: some View {
        if job.forkOf != nil {
            let src = store.jobs.job(job.forkOf)
            Label("Ответвление от «\(src?.title ?? job.forkTitle)»" + (job.forkSession.map { " · сессия \($0.prefix(8))…" } ?? ""),
                  systemImage: "arrow.triangle.branch")
                .font(.caption).foregroundStyle(.purple)
                .help(src == nil ? "Исходная задача убрана из очереди" : "Исходная сессия не меняется")
        }
        let forks = store.jobs.forks(of: job)
        if !forks.isEmpty {
            Label("Ответвления: " + forks.map { "«\($0.title)» — \($0.worktree?.branch ?? "без ветки")" }.joined(separator: ", "),
                  systemImage: "arrow.triangle.branch")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

extension SafeMerge.Phase {
    var title: String {
        switch self {
        case .waiting: "Жду проверку проекта…"
        case .preparing: "Вливаю основную ветку…"
        case .checking: "Проверяю вместе с основной…"
        case .landing: "Сливаю…"
        }
    }
}

extension Store {
    /// Actions of one branch: of the task, or of one of its repositories.
    func performBranch(_ a: JobAction, _ m: Job) {
        switch a {
        case .merge: jobs.merge(m, single: true)
        case .stopMerge: jobs.cancelMerge(m)
        case .resolveConflict: jobs.requestResolve(m)
        case .fixCheck: jobs.requestMergeFix(m)
        case .resolveMain: jobs.resolveMain(m)
        case .pullRequest: prJob = m
        default: break
        }
    }
}

/// Buttons of one repository of a task. The main action belongs to the card.
struct BranchActions: View {
    @Environment(Store.self) private var store
    let job: Job

    var body: some View {
        let offers = store.jobs.branchOffers(job)
        if let phase = job.mergePhase {
            Label(phase.title, systemImage: "arrow.triangle.merge").font(.caption).foregroundStyle(.purple)
        }
        ForEach(JobAction.allCases.filter { offers[$0] != nil }) { a in
            if let o = offers[a] {
                Button { store.performBranch(a, job) } label: { Label(o.title, systemImage: o.icon).labelStyle(.titleAndIcon) }
                    .buttonStyle(.glass)
                    .disabled(o.blocked != nil)
                    .help(o.blocked ?? o.help)
            }
        }
        if let why = JobAction.allCases.compactMap({ offers[$0]?.blocked }).first {
            Text("Недоступно: \(why)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Questions of a merge.
struct MergeQuestions: ViewModifier {
    @Environment(Store.self) private var store
    let job: Job

    func body(content: Content) -> some View {
        content
            .alert("Ветка трогает файлы с незакоммиченными правками",
                   isPresented: Binding(get: { !job.mergeOverlap.isEmpty }, set: { if !$0 { job.mergeOverlap = [] } })) {
                Button("Отмена", role: .cancel) {}
                Button("Слить всё равно") { store.jobs.merge(job, force: true, single: true) }
            } message: {
                Text("В основной папке\(job.isGroup ? " «\(job.repoName)»" : "") не закоммичены файлы, которые меняет ветка \(job.worktree?.branch ?? ""):\n\n"
                     + job.mergeOverlap.prefix(15).joined(separator: "\n")
                     + (job.mergeOverlap.count > 15 ? "\n… ещё \(job.mergeOverlap.count - 15)" : "")
                     + "\n\nЕсли слить сейчас, правки временно спрячутся (git stash), ветка сольётся, и правки вернутся. "
                     + "Где они пересекаются с веткой, в файлах появятся маркеры конфликта (<<<<<<<), а копия правок останется в git stash.")
            }
            .alert("CI красный", isPresented: Binding(get: { job.mergeRedCI }, set: { if !$0 { job.mergeRedCI = false } })) {
                Button("Отмена", role: .cancel) {}
                Button("Слить всё равно") { store.jobs.merge(job, redCI: true, single: true) }
            } message: {
                Text((job.pullRequest?.ciWarning ?? "Состояние CI изменилось."))
            }
    }
}

/// Repositories of a task that changes several: state and buttons of each. Failures show in a collapsed card too.
struct JobReposView: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    let job: Job

    var body: some View {
        if job.isGroup {
            VStack(alignment: .leading, spacing: 6) {
                if !job.groupSummary.isEmpty { Text(job.groupSummary).font(.caption.weight(.medium)) }
                ForEach(job.members) { m in
                    // The task's own questions are asked by its card.
                    if m.owner == nil { row(m) } else { row(m).modifier(MergeQuestions(job: m)) }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        } else if !job.repos.isEmpty {
            Label("Репозитории: " + job.repos.joined(separator: ", "), systemImage: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ m: Job) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            FlowLayout(spacing: 8) {
                Text(m.repoName).font(.callout.weight(.medium))
                if m.merged { Label("слит", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                if let w = m.worktree, !m.merged { Text(w.branch).font(.caption.monospaced()).foregroundStyle(.purple).lineLimit(1) }
                if !m.diffStat.isEmpty { Text(m.diffStat).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                if m.worktree != nil, job.state != .pending {
                    Button { openWindow(id: DiffView.windowID, value: DiffSource(job: m)) } label: {
                        Label("Изменения", systemImage: "plusminus").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.glass).help("Изменения в «\(m.repoName)»")
                }
                if !job.isActive { BranchActions(job: m) }
            }
            .controlSize(.small)
            if m.owner != nil {
                if !m.worktreeNote.isEmpty {
                    Text(m.worktreeNote).font(.caption).textSelection(.enabled)
                        .foregroundStyle(m.merged ? Color.green : m.mergeFailed || m.mainConflict || m.mergeCheck?.state == .red ? .red : .secondary)
                }
                if let c = m.mergeCheck, c.state == .red {
                    Text(VerifyErrors.lines(c.output).prefix(3).joined(separator: "\n"))
                        .font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                }
                if let link = m.pullRequest { PullRequestBadge(job: m, link: link) }
            }
        }
    }
}
