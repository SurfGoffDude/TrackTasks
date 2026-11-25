import SwiftUI
import TrackTasksCore

struct QueueView: View {
    @Environment(Store.self) private var store
    @AppStorage(JobQueue.parallelKey) private var parallel = 3
    @AppStorage(JobQueue.limitGuardKey) private var limitGuard = 10
    @AppStorage(JobQueue.fiveHourGuardKey) private var fiveHourGuard = 0
    @State private var orphans: [Worktrees.Info] = []
    @State private var highlighted: UUID?
    @State private var cleanupShown = false

    var body: some View {
        @Bindable var queue = store.jobs
        // Review/fix runs are shown inside their task's row.
        let jobs = store.jobs.jobs.filter { $0.parentID == nil || store.jobs.job($0.parentID) == nil }.reversed()
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Очередь Claude")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    if Spend.shared.today > 0 {
                        Pill(text: String(format: "сегодня $%.2f", Spend.shared.today), color: .purple, icon: "creditcard")
                    }
                    if let waiting = store.jobs.waitingAnswers {
                        Pill(text: waiting, color: .orange, icon: "questionmark.bubble.fill")
                    }
                    Button("Уборка worktree") { cleanupShown = true }
                        .buttonStyle(.glass)
                        .help("Worktree на диске: размер, возраст, удаление со снимком и восстановление")
                        .fixedSize()
                    Button("Очистить завершённые") { store.jobs.clearFinished() }
                        .buttonStyle(.glass)
                        .disabled(!store.jobs.jobs.contains { !$0.isActive })
                        .fixedSize()
                }
                // Not ViewThatFits: it updates both copies while measuring, the stepper's update invalidates the window,
                // and the layout never ends (a whole core while the queue is open).
                FlowLayout(spacing: 10) { controls(queue: queue) }
                DangerBar()
                WaitingForYouView()
                QueueBulkBar()
                MergeReadyView()
                if let hold = store.jobs.limitHold, !store.jobs.paused {
                    Label(hold, systemImage: "gauge.with.dots.needle.100percent")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 12))
                }
                Text("Команды вне списка разрешённых Claude спрашивает у тебя (кроме проектов в опасном режиме)."
                     + " Если проект занят, следующая его задача идёт параллельно в отдельном git worktree."
                     + (JobQueue.autoReview ? " После выполнения — автоматическое ревью." : ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !orphans.isEmpty {
                    OrphanWorktrees(items: orphans) { Task { await loadOrphans() } }
                }

                if jobs.isEmpty {
                    ContentUnavailableView("Очередь пуста",
                                           systemImage: "list.bullet.rectangle.portrait",
                                           description: Text("Сначала открой проект и создай задачу, затем нажми «В очередь» у колонки «К выполнению» или выбери задачи ⌘-кликом. Здесь будет видно, что делает Claude и что нужно от тебя."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                    Button { store.selectedID = Store.dashboardID } label: { Label("Открыть проекты", systemImage: "square.grid.2x2") }
                        .buttonStyle(.glassProminent)
                        .frame(maxWidth: .infinity)
                } else {
                    GlassEffectContainer(spacing: 12) {
                        VStack(spacing: 12) {
                            ForEach(Array(jobs)) { job in
                                JobRow(job: job, highlighted: highlighted == job.id).id(job.id)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .onChange(of: store.focusJob, initial: true) { focus(scroll) }
        }
        .background(Backdrop(tint: .orange))
        .navigationTitle("Очередь Claude")
        .task { await loadOrphans() }
        .sheet(isPresented: $cleanupShown, onDismiss: { Task { await loadOrphans() } }) { WorktreeCleanupView().environment(store) }
        .onChange(of: store.jobs.cleaning) { if !store.jobs.cleaning { Task { await loadOrphans() } } }
    }

    private func loadOrphans() async {
        orphans = await store.jobs.orphanWorktrees()
    }

    private func focus(_ scroll: ScrollViewProxy) {
        guard let id = store.focusJob else { return }
        store.focusJob = nil
        highlighted = id
        Task {
            // The card unfolds first.
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.snappy) { scroll.scrollTo(id, anchor: .top) }
            try? await Task.sleep(for: .seconds(2))
            if highlighted == id { highlighted = nil }
        }
    }

    @ViewBuilder
    private func controls(queue: JobQueue) -> some View {
        @Bindable var queue = queue
        Toggle(isOn: $queue.paused) {
            Label(queue.paused ? "На паузе" : "Пауза", systemImage: queue.paused ? "pause.circle.fill" : "pause.circle")
        }
        .toggleStyle(.button)
        .buttonStyle(.glass)
        .tint(queue.paused ? .orange : nil)
        .fixedSize()
        Stepper(value: $parallel, in: JobQueue.parallelRange) {
            Label("Параллельно: \(parallel)", systemImage: "square.stack.3d.up")
                .monospacedDigit()
        }
        .fixedSize()
        .onChange(of: parallel) { store.jobs.pump() }
        Picker(selection: $limitGuard) {
            Text("без порога").tag(0)
            ForEach([5, 10, 20, 30], id: \.self) { Text("при < \($0)%").tag($0) }
        } label: {
            Label("Стоп по неделе", systemImage: "gauge.with.dots.needle.33percent")
        }
        .fixedSize()
        .onChange(of: limitGuard) { store.jobs.pump() }
        Picker(selection: $fiveHourGuard) {
            Text("без порога").tag(0)
            ForEach([5, 10, 20, 30], id: \.self) { Text("при < \($0)%").tag($0) }
        } label: {
            Label("Стоп по 5 ч", systemImage: "clock.badge.exclamationmark")
        }
        .fixedSize()
        .onChange(of: fiveHourGuard) { store.jobs.pump() }
        if store.jobs.runningCount > 0 {
            Pill(text: "идёт: \(store.jobs.runningCount)", color: .blue, icon: "bolt.fill")
        }
    }
}

/// Worktrees left on disk that no job owns: merge or delete them.
struct OrphanWorktrees: View {
    @Environment(Store.self) private var store
    let items: [Worktrees.Info]
    let reload: () -> Void
    @State private var busy: String?
    @State private var note: [String: String] = [:]
    @State private var token: MergeToken?
    @State private var overlap: Overlap?
    @State private var removing: CleanupItem?

    /// The branch touches uncommitted files of the main folder; `report` of the run that found it.
    private struct Overlap {
        let worktree: Worktrees.Info
        let files: [String]
        let report: SafeMerge.Report
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ветки без задачи в очереди", systemImage: "arrow.triangle.branch")
                .font(.headline)
            ForEach(items) { w in
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.branch.isEmpty ? w.path.lastPathComponent : w.branch).font(.callout.monospaced())
                        Text(w.main.lastPathComponent + (note[w.id].map { " · " + $0 } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    FlowLayout(spacing: 8) {
                    Button { store.openTerminal(at: w.main, command: "git log --oneline HEAD..\(w.branch) && git diff HEAD...\(w.branch)") } label: {
                        Label("Изменения", systemImage: "plusminus").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.glass).help("Diff ветки")
                    Button { store.openTerminal(at: w.path) } label: { Label("Терминал", systemImage: "terminal").labelStyle(.titleAndIcon) }
                        .buttonStyle(.glass).help("Терминал в worktree")
                    Button("Слить") {
                        merge(w)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(busy != nil || w.branch.isEmpty || store.jobs.busyOrphans.contains(w.id))
                    .help("Коммитит изменения в ветке, проверяет вместе с основной веткой и сливает в текущую ветку проекта")
                    if busy == w.id, let token {
                        Button { token.cancel() } label: { Label("Остановить слияние", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                            .buttonStyle(.glass).help("Остановить слияние")
                    }
                    Button(role: .destructive) {
                        ask(w)
                    } label: { Label("Удалить worktree и ветку", systemImage: "trash").labelStyle(.titleAndIcon) }
                    .buttonStyle(.glass).disabled(busy != nil || store.jobs.busyOrphans.contains(w.id)).help("Удалить worktree и ветку, оставив снимок")
                    if let busy, busy != w.id { Text("Недоступно: идёт операция с другой веткой").font(.caption).foregroundStyle(.secondary) }
                    else if busy == nil, store.jobs.busyOrphans.contains(w.id) { Text("Недоступно: с worktree сейчас что-то делают").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.purple.opacity(0.08)), in: .rect(cornerRadius: 16))
        .sheet(item: $removing) { item in
            CleanupConfirm(item: item, confirm: { overriding in remove(item) { await $0.cleanUp(item.group, overriding: overriding) } },
                           forget: { remove(item) { await $0.forgetMissing(item.group) } },
                           trash: { remove(item) { await $0.trashOrphan(item.group) } })
                .environment(store)
        }
        .alert("Ветка трогает файлы с незакоммиченными правками",
               isPresented: Binding(get: { overlap != nil }, set: { if !$0 { overlap = nil } }), presenting: overlap) { o in
            Button("Отмена", role: .cancel) {}
            Button("Слить всё равно") { merge(o.worktree, confirmed: o) }
        } message: { o in
            Text("В основной папке не закоммичены файлы, которые меняет ветка \(o.worktree.branch):\n\n"
                 + o.files.prefix(15).joined(separator: "\n")
                 + (o.files.count > 15 ? "\n… ещё \(o.files.count - 15)" : "")
                 + "\n\nЕсли слить сейчас, правки временно спрячутся (git stash), ветка сольётся, и правки вернутся. "
                 + "Где они пересекаются с веткой, в файлах появятся маркеры конфликта (<<<<<<<), а копия правок останется в git stash.")
        }
    }

    /// What has to be done before a merge of a folder nobody owns.
    private enum Ready: Sendable {
        case go(note: String)
        case stop(String, removed: Bool)
    }

    nonisolated private static func prepare(_ w: Worktrees.Info) -> Ready {
        let git: SafeMerge.Runner = DiffLoader.runEnv
        var note = ""
        // A merge cut off by the end of the app: without this its MERGE_HEAD would be committed as work.
        switch SafeMerge.recover(w.mergeSite, git: git) {
        case nil: break
        case .interrupted(let stash):
            if stash != nil { note = "Прошлое слияние прервано" + MergeRunner.stashNote(stash) }
        case .landedElsewhere(let branches, let stash):
            return .stop(MergeRunner.elsewhere(branches) + MergeRunner.stashNote(stash), removed: false)
        case .landed(let stash):
            let left = SafeMerge.uncommitted(w.mergeSite, git: git)
            let head = "Уже слито (приложение закрылось сразу после слияния)"
            guard left.isEmpty else {
                return .stop(head + ". Worktree оставлен: в нём незакоммиченное — \(DirtyFiles.summary(left))"
                             + MergeRunner.stashNote(stash), removed: false)
            }
            MergeRunner.cleanUp(w)
            return .stop(head + MergeRunner.stashNote(stash), removed: true)
        }
        // Work left from a crash/quit may be uncommitted — commit it first.
        let c = Worktrees.commitAll(w, message: "TrackTasks: незавершённая работа")
        return c.ok ? .go(note: note) : .stop([note, c.message].filter { !$0.isEmpty }.joined(separator: ". "), removed: false)
    }

    private func merge(_ w: Worktrees.Info, confirmed: Overlap? = nil) {
        guard !store.jobs.busyOrphans.contains(w.id) else { return }
        let t = MergeToken()
        busy = w.id
        // Cleanup waits.
        store.jobs.busyOrphans.insert(w.id)
        token = t
        note[w.id] = "проверяю вместе с основной веткой…"
        // Also while the branch is being prepared.
        t.begin()
        Task {
            defer { t.end() }
            // Confirmed: the same code goes on with its check; a commit now would take leftovers of `verify`.
            let ready = confirmed != nil ? .go(note: "") : await Task.detached { Self.prepare(w) }.value
            var text = "", merged = false
            switch ready {
            case .stop(let why, let removed):
                text = why
                merged = removed
                // The row goes away with its note.
                if removed { Notifier.shared.post(title: "Слито", body: why, jobID: nil) }
            case .go(let before):
                let r = await MergeRunner.run(w, known: confirmed?.report.check, artifacts: confirmed?.report.artifacts ?? [],
                                              allowed: .files(Set(confirmed?.files ?? [])), token: t)
                text = [before, MergeRunner.text(r)].filter { !$0.isEmpty }.joined(separator: ". ")
                switch r.outcome {
                case .merged(_, let extra, _):
                    merged = true
                    if !extra.isEmpty || !before.isEmpty || !r.artifacts.isEmpty {
                        Notifier.shared.post(title: "Слито", body: text, jobID: nil)
                    }
                case .overlap(let files):
                    // Files confirmed before stay confirmed: the next answer is about the whole list.
                    overlap = Overlap(worktree: w, files: Set(files).union(confirmed?.files ?? []).sorted(), report: r)
                default: break
                }
            }
            busy = nil
            store.jobs.busyOrphans.remove(w.id)
            token = nil
            note[w.id] = text
            if merged { store.reload(); reload() }
        }
    }

    private func ask(_ w: Worktrees.Info) {
        busy = w.id
        note[w.id] = nil
        Task {
            let item = await store.jobs.cleanupItems().first { $0.group.paths.contains(w.id) }
            busy = nil
            if let item { removing = item } else { reload() }
        }
    }

    private func remove(_ item: CleanupItem, _ work: @escaping @MainActor (JobQueue) async -> String?) {
        busy = item.id
        Task {
            let why = await work(store.jobs)
            busy = nil
            for p in item.group.paths { note[p] = why }
            if why == nil { store.reload() }
            reload()
        }
    }
}
