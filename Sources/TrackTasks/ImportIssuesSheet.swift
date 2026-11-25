import SwiftUI
import TrackTasksCore

/// Import of issues from GitHub (`gh`), Linear, Jira, GitLab and Sentry. Issue text is untrusted: it lands in the
/// task as inert data, the task stays `todo`, nothing is queued. Writing (comment, close) is GitHub only, on a click.
/// Sources are independent: each has its own rows, error and load number.
struct ImportIssuesSheet: View {
    let project: Project
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        var issue: IssueInfo
        var existing: TaskFile?
        var plan: IssueImport.Plan
        var id: String { issue.id }
    }

    /// A write to GitHub waiting for the user's confirmation.
    struct Pending: Identifiable {
        enum Kind { case comment, close }
        let id = UUID()
        var kind: Kind
        var ref: IssueRef
        var text = ""
    }

    @State private var repo: GitHubRepo?
    @State private var enabled: [IssueSourceID] = []
    /// nil = all available sources.
    @State private var picked: IssueSourceID?
    @State private var scopes: [IssueSourceID: String] = [:]
    @State private var filter = IssueFilter()
    @State private var rows: [IssueSourceID: [Row]] = [:]
    @State private var notes: [IssueSourceID: String] = [:]
    @State private var errors: [IssueSourceID: String] = [:]
    @State private var selected: Set<String> = []
    @State private var shownDiff: String?
    @State private var loading: Set<IssueSourceID> = []
    @State private var writing = false
    @State private var message = ""
    @State private var pending: Pending?
    /// Number of the latest load of a source: an older answer is dropped.
    @State private var loadTokens: [IssueSourceID: Int] = [:]
    @State private var tasks: [IssueSourceID: Task<Void, Never>] = [:]

    private var available: [IssueSourceID] { (repo == nil ? [] : [.github]) + enabled }
    private var active: [IssueSourceID] { picked.map { [$0] } ?? available }
    private var allRows: [Row] { active.flatMap { rows[$0] ?? [] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Импорт задач", systemImage: "arrow.down.circle.fill")
                .font(.title2.weight(.semibold))
            sourcePicker
            filters
            list
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Текст issue — недоверенный: он сохраняется в задаче как данные, задача остаётся «todo» и сама не запускается.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Закрыть") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Обновить выбранные") { updateSelected() }
                    .buttonStyle(.glass)
                    .disabled(writing || !allRows.contains { selected.contains($0.id) && isChanged($0) })
                Button("Импортировать выбранные") { importSelected() }
                    .buttonStyle(.glassProminent)
                    .disabled(writing || !allRows.contains { selected.contains($0.id) && $0.plan == .create })
            }
        }
        .padding(24)
        .frame(width: 720, height: 600)
        .onAppear(perform: start)
        .onDisappear { tasks.values.forEach { $0.cancel() } }
        .sheet(item: $pending) { p in PendingSheet(pending: p) { run($0) } }
    }

    @ViewBuilder private var sourcePicker: some View {
        if available.count > 1 {
            Picker("Источник", selection: $picked) {
                Text("Все включённые").tag(IssueSourceID?.none)
                ForEach(available, id: \.self) { Text($0.name).tag(IssueSourceID?.some($0)) }
            }
            .pickerStyle(.segmented)
        }
        if active.contains(.github), let repo {
            Text("GitHub: \(repo.slug)").font(.callout).foregroundStyle(.secondary)
        }
        let fields = active.filter { $0 != .github }
        if !fields.isEmpty {
            HStack {
                ForEach(fields, id: \.self) { id in
                    TextField(Self.scopeTitle(id), text: Binding(get: { scopes[id] ?? "" }, set: {
                        scopes[id] = $0
                        IssueSourceStore.setScope(id, project: project.url.path, $0.trimmingCharacters(in: .whitespaces))
                    }))
                    .onSubmit { load([id]) }
                }
            }
        }
        if active.contains(.sentry), !filter.label.isEmpty {
            Text("Sentry: фильтр по метке не учитывается.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func scopeTitle(_ id: IssueSourceID) -> String {
        switch id {
        case .linear: "Linear: команда (ENG), пусто — все"
        case .jira: "Jira: ключ проекта"
        case .gitlab: "GitLab: группа/проект"
        default: "\(id.name): проект, пусто — все"
        }
    }

    private var filters: some View {
        HStack {
            Picker("Состояние", selection: $filter.state) {
                ForEach(IssueFilter.State.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 150)
            TextField("Метка", text: $filter.label).frame(width: 110)
            TextField("Исполнитель", text: $filter.assignee).frame(width: 110)
            TextField("Поиск", text: $filter.search)
            Button { load(active) } label: { Label("Загрузить", systemImage: "arrow.clockwise") }
                .buttonStyle(.glass)
                .disabled(active.isEmpty || writing)
        }
    }

    private var list: some View {
        List {
            ForEach(active, id: \.self) { id in
                Section {
                    ForEach(rows[id] ?? []) { rowView($0) }
                } header: {
                    HStack {
                        Text(id.name)
                        if loading.contains(id) { ProgressView().controlSize(.small) }
                        if let e = errors[id] { Text(e).foregroundStyle(.red).lineLimit(3).textSelection(.enabled) }
                        else if let n = notes[id] { Text(n).foregroundStyle(.secondary) }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func rowView(_ r: Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("", isOn: Binding(get: { selected.contains(r.id) },
                                         set: { if $0 { selected.insert(r.id) } else { selected.remove(r.id) } }))
                    .labelsHidden()
                    .disabled(r.plan == .unchanged || r.plan == .noBlock)
                VStack(alignment: .leading) {
                    Text(r.issue.ref + " " + IssueImport.cleanTitle(r.issue)).lineLimit(2)
                    Text(([r.issue.isOpen ? "открыт" : "закрыт"] + r.issue.labels).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                badge(r)
                if r.issue.source == .github, r.existing != nil, let ref = IssueRef.parse(r.issue.url) {
                    Menu {
                        Button("Комментарий…") { pending = Pending(kind: .comment, ref: ref) }
                        if r.issue.isOpen { Button("Закрыть issue…") { pending = Pending(kind: .close, ref: ref) } }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            if shownDiff == r.id, case .changed(let d) = r.plan { diffView(d) }
        }
    }

    @ViewBuilder private func badge(_ r: Row) -> some View {
        switch r.plan {
        case .create: Text("новый").font(.caption).foregroundStyle(.green)
        case .unchanged: Text("импортирован").font(.caption).foregroundStyle(.secondary)
        case .noBlock: Text("блок удалён вручную").font(.caption).foregroundStyle(.orange)
        case .changed:
            Button(shownDiff == r.id ? "Скрыть различия" : "Изменён — различия") { shownDiff = shownDiff == r.id ? nil : r.id }
                .buttonStyle(.link).font(.caption)
        }
    }

    private func diffView(_ d: [IssueDiffLine]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(d.enumerated()), id: \.offset) { _, l in
                    Text((l.kind == .added ? "+ " : l.kind == .removed ? "− " : "  ") + l.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(l.kind == .added ? Color.green : l.kind == .removed ? Color.red : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: 180)
        .padding(6)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private func isChanged(_ r: Row) -> Bool { if case .changed = r.plan { return true } else { return false } }

    // MARK: Actions

    private func start() {
        enabled = IssueSourceStore.enabled
        for id in enabled { scopes[id] = IssueSourceStore.scope(id, project: project.url.path) }
        let dir = project.url
        Task.detached {
            let url = Worktrees.git(["remote", "get-url", "origin"], in: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let r = GitHubRepo.parse(url)
            await MainActor.run {
                repo = r
                message = available.isEmpty ? "Нет источников: у проекта нет remote origin на GitHub, остальные трекеры включаются в Настройках." : ""
                // The others wait for a click: fields must not send requests by themselves.
                if r != nil { load([.github]) }
            }
        }
    }

    private func load(_ ids: [IssueSourceID]) {
        for id in ids { loadOne(id) }
    }

    private func loadOne(_ id: IssueSourceID) {
        let token = (loadTokens[id] ?? 0) + 1
        loadTokens[id] = token
        loading.insert(id)
        errors[id] = nil
        tasks[id]?.cancel()
        let filter = filter, dir = project.url, folder = project.tasksURL, repo = repo, scope = scopes[id] ?? ""
        tasks[id] = Task.detached {
            // Keychain is read here, off the main thread.
            let source: IssueSource? = id == .github ? repo.map { GitHubSource(repo: $0, dir: dir) }
                : IssueSourceStore.connection(id).source(id, scope: scope)
            guard let source else {
                await MainActor.run {
                    guard token == loadTokens[id] else { return }
                    loading.remove(id)
                    errors[id] = IssueSourceError.notConfigured("источник недоступен").message
                }
                return
            }
            let result = await IssueLoader.one(source, filter: filter)
            if Task.isCancelled { return }
            let existing = IssueImport.existing(in: folder)
            await MainActor.run {
                guard token == loadTokens[id] else { return }
                loading.remove(id)
                switch result {
                case .failure(let e): errors[id] = e.message   // rows loaded before stay
                case .success(let list):
                    let old = Set((rows[id] ?? []).map(\.id))
                    let new = list.issues.map { Self.row($0, existing) }
                    rows[id] = new
                    selected.subtract(old.subtracting(new.map(\.id)))
                    notes[id] = (list.issues.isEmpty ? "не найдено" : "найдено: \(list.issues.count)") + (list.hasMore ? ", есть ещё — уточните фильтр" : "")
                        + (list.skipped > 0 ? ", пропущено непонятных: \(list.skipped)" : "")
                }
            }
        }
    }

    nonisolated private static func row(_ i: IssueInfo, _ existing: [String: TaskFile]) -> Row {
        let e = existing[IssueRef.key(i.url)]
        return Row(issue: i, existing: e, plan: IssueImport.plan(i, existing: e))
    }

    private func importSelected() {
        let todo = allRows.filter { selected.contains($0.id) && $0.plan == .create }.map(\.issue)
        let tasks = project.tasksURL
        writing = true
        message = "Импорт…"
        Task.detached {
            // A fresh look at the folder: a repeated click or another window must not create a second file.
            let existing = IssueImport.existing(in: tasks)
            var created = 0, skipped = 0, failed: [String] = []
            for i in todo where existing[IssueRef.key(i.url)] == nil {
                do {
                    // The check runs under the folder lock: two windows cannot both create the file.
                    _ = try TaskFile.create(text: IssueImport.taskText(i, today: Codec.today()),
                                            slugOf: IssueImport.cleanTitle(i), in: tasks) {
                        if IssueImport.existing(in: tasks)[IssueRef.key(i.url)] != nil { throw IssueImport.AlreadyImported() }
                    }
                    created += 1
                } catch is IssueImport.AlreadyImported { skipped += 1
                } catch { failed.append("\(i.ref): \(error)") }
            }
            let summary = "Создано задач: \(created)" + (skipped > 0 ? ", уже были: \(skipped)" : "") + (failed.isEmpty ? "" : ". Не удалось: " + failed.joined(separator: "; "))
            await MainActor.run { finishWrite(summary) }
        }
    }

    private func updateSelected() {
        let todo = allRows.filter { selected.contains($0.id) && isChanged($0) }
        let tasks = project.tasksURL
        writing = true
        message = "Обновление…"
        Task.detached {
            var done = 0, failed: [String] = []
            for r in todo {
                // Only a file whose issue block is still what the diff showed gets rewritten.
                let f = IssueImport.existing(in: tasks)[IssueRef.key(r.issue.url)]
                guard let f, IssueImport.plan(r.issue, existing: f) == r.plan,
                      let new = IssueImport.updated(f.text, with: r.issue) else {
                    failed.append("\(r.issue.ref): файл изменился, загрузите заново"); continue
                }
                do { try f.write(new); done += 1 } catch { failed.append("\(r.issue.ref): \(error)") }
            }
            let summary = "Обновлено: \(done)" + (failed.isEmpty ? "" : ". Не удалось: " + failed.joined(separator: "; "))
            await MainActor.run { finishWrite(summary) }
        }
    }

    /// Only the folder changed: rows are compared again without a request.
    private func finishWrite(_ summary: String) {
        store.reloadProject(project.id)
        selected = []
        message = summary
        let folder = project.tasksURL
        Task.detached {
            let existing = IssueImport.existing(in: folder)
            await MainActor.run {
                rows = rows.mapValues { $0.map { Self.row($0.issue, existing) } }
                writing = false
            }
        }
    }

    private func run(_ p: Pending) {
        let args = p.kind == .comment ? IssueImport.commentArguments(p.ref) : IssueImport.closeArguments(p.ref, comment: p.text)
        let input = p.kind == .comment ? p.text : nil
        let dir = project.url
        message = "Отправка в GitHub…"
        Task.detached {
            let r = GitHubCLI.run(args, in: dir, input: input)
            await MainActor.run {
                message = r.ok ? (p.kind == .comment ? "Комментарий отправлен" : "Issue закрыт")
                                : (r.err.isEmpty ? "gh не сработал" : r.err)
                if r.ok && p.kind == .close { load([.github]) }
            }
        }
    }
}

/// The exact text that goes to GitHub, and a button that sends it.
private struct PendingSheet: View {
    @State var pending: ImportIssuesSheet.Pending
    let send: (ImportIssuesSheet.Pending) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.kind == .comment ? "Комментарий к #\(pending.ref.number)" : "Закрыть issue #\(pending.ref.number)")
                .font(.title3.weight(.semibold))
            Text("\(pending.ref.repo.slug) — это увидят все, у кого есть доступ к репозиторию.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $pending.text)
                .font(.body)
                .frame(height: 140)
                .padding(4)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            if pending.kind == .close {
                Text("Комментарий необязателен.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button(pending.kind == .comment ? "Отправить" : "Закрыть issue") { send(pending); dismiss() }
                    .buttonStyle(.glassProminent)
                    .disabled(pending.kind == .comment && pending.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
