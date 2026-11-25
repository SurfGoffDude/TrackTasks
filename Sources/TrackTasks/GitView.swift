import SwiftUI
import TrackTasksCore

/// History with the branch graph, branches, fetch / pull / push. No force anywhere.
struct GitView: View {
    static let windowID = "git"

    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    let project: Project

    @State private var snap: GitOps.Snapshot?
    @State private var limit = GitHistory.page
    @State private var reloads = 0
    @State private var loading = false
    @State private var selected: String?
    @State private var working: String?
    @State private var note = ""
    @State private var failed = false
    @State private var question: Question?

    private enum Question {
        case switchTo(GitBranch, dirty: [String], unmerged: Int)
        case push(GitBranches.PushPlan)

        var title: String {
            switch self {
            case .switchTo(let b, _, _): "Переключиться на «\(b.localName)»?"
            case .push(let p): "Отправить \(p.title)?"
            }
        }
        var button: String {
            switch self {
            case .switchTo(_, let dirty, _): dirty.isEmpty ? "Переключить" : "Переключить с правками"
            case .push: "Отправить"
            }
        }
        var text: String {
            switch self {
            case .switchTo(_, let dirty, let unmerged):
                var parts: [String] = []
                if !dirty.isEmpty {
                    let list = dirty.prefix(12).joined(separator: "\n") + (dirty.count > 12 ? "\n…и ещё \(dirty.count - 12)" : "")
                    parts.append("Незакоммичено файлов: \(dirty.count). Они перейдут на другую ветку; если мешают, git откажет и ничего не тронет.\n\n\(list)")
                }
                if unmerged > 0 { parts.append("Неслитых веток задач: \(unmerged) — их слияние пойдёт уже в новую ветку.") }
                return parts.joined(separator: "\n\n")
            case .push(let p):
                return "Ветка: \(p.branch)\nRemote: \(p.remote)\nКоммитов: \(p.commits)"
                    + (p.setUpstream ? "\nУ ветки нет upstream — он будет создан." : "")
            }
        }
    }

    private struct LoadKey: Equatable {
        let reloads: Int
        let limit: Int
        let git: GitInfo?
    }

    var body: some View {
        NavigationSplitView {
            branchList
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 460)
        } detail: {
            VStack(spacing: 0) {
                banner
                history
                if let c = commit { Divider(); details(c) }
            }
        }
        .navigationTitle(project.displayName)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .alert(question?.title ?? "", isPresented: Binding(get: { question != nil }, set: { if !$0 { question = nil } }),
               presenting: question) { q in
            Button("Отмена", role: .cancel) {}
            Button(q.button) { confirmed(q) }
        } message: { Text($0.text) }
        .task(id: LoadKey(reloads: reloads, limit: limit, git: store.git[project.id])) { await load() }
    }

    // MARK: Data

    private var state: GitState { snap?.state ?? GitState() }
    private var commit: GitCommit? { snap?.page.commits.first { $0.id == selected } }
    private var current: GitBranch? { state.branches.first(where: \.isCurrent) }

    private var subtitle: String {
        guard snap != nil else { return "" }
        guard let name = state.branch else { return "detached HEAD" }
        guard let b = current else { return name }
        guard let up = b.upstream else { return "\(name) · без upstream" }
        if b.gone { return "\(name) · upstream \(up) удалён" }
        return "\(name) · \(up) · ↑\(b.ahead) ↓\(b.behind)"
    }

    private func load() async {
        loading = true
        let s = await GitOps.load(project.url, limit: limit)
        // A newer load is already running and will set the result.
        guard !Task.isCancelled else { return }
        loading = false
        snap = s
    }

    /// Why the main folder can't be touched now.
    private var blocked: String? { working.map { _ in "Идёт операция" } ?? store.jobs.gitBlocked(project.url) }

    // MARK: Actions

    private func run(_ title: String, _ body: @escaping @MainActor () async -> GitOps.Outcome<String>) {
        guard working == nil else { return }
        working = title
        note = ""
        Task {
            let r = await body()
            switch r {
            case .success(let t): show(t)
            case .failure(let e): show(e.message, failed: true)
            }
            finish()
        }
    }

    private func show(_ text: String, failed bad: Bool = false) {
        note = text
        failed = bad
    }

    private func finish() {
        working = nil
        reloads += 1
        store.refreshGit(project.id)
    }

    private func askSwitch(_ b: GitBranch) {
        guard blocked == nil else { return }
        working = "Проверяю папку…"
        Task {
            let r = await GitOps.dirty(project.url)
            working = nil
            switch r {
            case .failure(let e): show(e.message, failed: true)
            case .success(let dirty):
                let unmerged = store.jobs.unmergedWorktrees(project.url)
                if dirty.isEmpty, unmerged == 0 { doSwitch(b, dirty: []) }
                else { question = .switchTo(b, dirty: dirty, unmerged: unmerged) }
            }
        }
    }

    private func doSwitch(_ b: GitBranch, dirty: [String]) {
        guard working == nil else { return }
        working = "Переключаю на \(b.localName)…"
        note = ""
        Task {
            switch await GitOps.switchTo(b, in: project.url, confirmed: Set(dirty), jobs: store.jobs) {
            case .done: show("Открыта ветка \(b.localName)")
            case .failed(let m): show(m, failed: true)
            // Edited since the question.
            case .ask(let files): question = .switchTo(b, dirty: files, unmerged: store.jobs.unmergedWorktrees(project.url))
            }
            finish()
        }
    }

    private func askPush() {
        guard working == nil else { return }
        working = "Смотрю, что отправлять…"
        Task {
            let r = await GitOps.pushPlan(project.url)
            working = nil
            switch r {
            case .failure(let e): show(e.message, failed: true)
            case .success(let p): question = .push(p)
            }
        }
    }

    private func confirmed(_ q: Question) {
        switch q {
        case .switchTo(let b, let dirty, _): doSwitch(b, dirty: dirty)
        case .push(let p): run("Push…") { await GitOps.push(p, in: project.url) }
        }
    }

    private func openDiff(_ c: GitCommit) {
        Task {
            if let s = await GitOps.diff(c, project: project.displayName, folder: project.url) {
                openWindow(id: DiffView.windowID, value: s)
            } else {
                show("Не удалось открыть diff коммита", failed: true)
            }
        }
    }

    // MARK: Branches

    private var branchList: some View {
        let state = state, blocked = blocked
        return List {
            Section("Ветки") {
                ForEach(state.branches.filter { $0.remote == nil }) { branchRow($0, state, blocked) }
            }
            ForEach(state.remotes, id: \.self) { r in
                let list = state.branches.filter { $0.remote == r }
                if !list.isEmpty { Section(r) { ForEach(list) { branchRow($0, state, blocked) } } }
            }
            if let e = state.error { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    private func branchRow(_ b: GitBranch, _ state: GitState, _ blocked: String?) -> some View {
        let why = GitBranches.denied(b, state) ?? blocked
        return HStack(spacing: 6) {
            Image(systemName: b.isCurrent ? "checkmark.circle.fill" : b.worktree != nil ? "folder.badge.gearshape" : "arrow.triangle.branch")
                .foregroundStyle(b.isCurrent ? Color.green : .secondary)
            Text(b.localName).lineLimit(1).truncationMode(.middle).fontWeight(b.isCurrent ? .semibold : .regular)
            Spacer(minLength: 4)
            if b.ahead > 0 { Text("↑\(b.ahead)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if b.behind > 0 { Text("↓\(b.behind)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if b.gone { Text("нет upstream").font(.caption2).foregroundStyle(.orange) }
        }
        .contentShape(.rect)
        .gesture(TapGesture(count: 2).onEnded { if why == nil { askSwitch(b) } }
            .exclusively(before: TapGesture().onEnded { selected = b.tip }))
        .help(b.worktree.map { "Открыта в другой папке: \($0)" } ?? "Двойной щелчок — переключиться. " + (why ?? ""))
        .contextMenu {
            Button("Переключиться") { askSwitch(b) }.disabled(why != nil)
            if let why, !b.isCurrent { Text(why) }
        }
    }

    // MARK: History

    @ViewBuilder
    private var banner: some View {
        let lines = [state.operation.map { "Не закончена операция git: \($0)" }, store.jobs.gitBlocked(project.url)].compactMap { $0 }
        if working != nil || !note.isEmpty || !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let working { HStack { ProgressView().controlSize(.small); Text(working) } }
                if working == nil { ForEach(lines, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
                if !note.isEmpty {
                    HStack(alignment: .top) {
                        Text(note).foregroundStyle(failed ? .red : .green).textSelection(.enabled).lineLimit(8)
                        Spacer()
                        Button { note = "" } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            Divider()
        }
    }

    @ViewBuilder
    private var history: some View {
        if let page = snap?.page {
            if let e = page.error {
                ContentUnavailableView("Не удалось получить историю", systemImage: "exclamationmark.triangle", description: Text(e))
                    .frame(maxHeight: .infinity)
            } else if page.commits.isEmpty {
                ContentUnavailableView("Коммитов ещё нет", systemImage: "clock").frame(maxHeight: .infinity)
            } else {
                let width = GitGraphCell.width(page.rows)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(zip(page.commits, page.rows)), id: \.0.id) { c, row in
                            GitCommitRow(commit: c, row: row, graphWidth: width, selected: c.id == selected)
                                .onTapGesture(count: 2) { openDiff(c) }
                                .onTapGesture { selected = c.id }
                                .contextMenu {
                                    Button("Diff коммита") { openDiff(c) }
                                    Button("Скопировать хеш") { copy(c.id) }
                                }
                        }
                        if page.more {
                            Button("Показать ещё") { limit += GitHistory.page }
                                .disabled(loading)
                                .padding(12)
                        }
                    }
                }
            }
        } else {
            ProgressView("git log…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func details(_ c: GitCommit) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.subject).font(.headline).lineLimit(2)
                Text("\(c.id.prefix(12)) · \(c.author) · \(c.date.formatted(date: .abbreviated, time: .shortened))"
                     + (c.isMerge ? " · слияние" : ""))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            Spacer()
            Button { openDiff(c) } label: { Label("Diff", systemImage: "plusminus") }
                .help(c.isMerge ? "Слияние сравнивается с первым родителем" : "Изменения коммита")
        }
        .padding(12)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { run("Fetch…") { await GitOps.fetch(project.url) } } label: { Label("Fetch", systemImage: "arrow.down.circle.dotted") }
                .disabled(working != nil || state.remotes.isEmpty)
                .help("Fetch: получить новое, не меняя файлы")
            Button { run("Pull…") { await GitOps.pull(project.url, jobs: store.jobs) } } label: { Label("Pull", systemImage: "arrow.down.circle") }
                .disabled(blocked != nil || current?.upstream == nil)
                .help(blocked ?? "Pull: только перемотка вперёд (--ff-only)")
            Button { askPush() } label: { Label("Push", systemImage: "arrow.up.circle") }
                .disabled(working != nil || state.branch == nil || state.remotes.isEmpty)
                .help("Push с подтверждением, без force")
        }
        ToolbarItem {
            Button { reloads += 1 } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                .disabled(loading)
                .help("Перечитать историю и ветки")
        }
    }
}
