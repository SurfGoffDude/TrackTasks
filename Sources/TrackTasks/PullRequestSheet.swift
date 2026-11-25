import SwiftUI
import TrackTasksCore

/// Preview of a pull request. Opening it uses no network; push and creation only on the confirm button.
struct PullRequestSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let job: Job

    @State private var preview: PullRequestPreview?
    @State private var remote: String?
    @State private var base = ""
    @State private var commits: [String] = []
    @State private var title = ""
    @State private var text = ""
    @State private var drafting = false
    @State private var working = false
    @State private var error = ""
    @State private var proc: ClaudeProcess?
    @State private var closed = false

    private var open: PullRequest? { job.pullRequest.flatMap { $0.pr.state == .open ? $0.pr : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label((open.map { "Обновить PR #\($0.number)" } ?? "Новый PR") + " · \(job.projectName)", systemImage: "arrow.triangle.pull")
                .font(.title3.bold())
            if let p = preview {
                if let problem = p.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if !p.remote.isEmpty { target(p) }
                if !p.dirty.isEmpty {
                    Label("Не войдут незакоммиченные правки в worktree: \(DirtyFiles.summary(p.dirty))", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if p.problem == nil {
                    commitList
                    if open == nil { draftFields }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if !error.isEmpty {
                Text(error).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled).lineLimit(8)
            }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(open == nil ? "Запушить и создать PR" : "Запушить") { publish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPublish)
            }
        }
        .padding(20)
        .frame(width: 620)
        .interactiveDismissDisabled(working)
        .task(id: remote) { await load() }
        .task(id: "\(preview?.tip ?? "") \(preview?.remote ?? "") \(base)") { await loadCommits() }
        .onDisappear { closed = true; proc?.stop() }
    }

    private var canPublish: Bool {
        guard let p = preview, p.problem == nil, !working, !drafting, !commits.isEmpty else { return false }
        return open != nil || (!base.isEmpty && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func target(_ p: PullRequestPreview) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Remote").foregroundStyle(.secondary)
                HStack {
                    if p.remotes.count > 1, open == nil {
                        Picker("Remote", selection: Binding(get: { p.remote }, set: { remote = $0 })) {
                            ForEach(p.remotes, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().fixedSize().disabled(working)
                    } else {
                        Text(p.remote)
                    }
                    Text(p.remoteURL).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            GridRow {
                Text("Ветка").foregroundStyle(.secondary)
                Text("\(job.worktree?.branch ?? "") · \(p.tip.prefix(8))").font(.callout.monospaced()).textSelection(.enabled)
            }
            GridRow {
                Text("Влить в").foregroundStyle(.secondary)
                if let open {
                    Text(open.base).font(.callout.monospaced())
                } else {
                    Picker("Влить в", selection: $base) {
                        ForEach(p.bases, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize().disabled(working)
                }
            }
        }
    }

    private var commitList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Коммиты, которых ещё нет в \(base) на remote: \(commits.count >= 200 ? "200+" : "\(commits.count)")").font(.headline)
            ScrollView {
                Text(commits.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 80)
            .padding(8)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            Text("По локальным данным о remote. Сюда входят и незапушенные коммиты основной ветки — они тоже уйдут.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var draftFields: some View {
        HStack {
            Text("Заголовок и описание").font(.headline)
            if drafting { ProgressView().controlSize(.small) }
            Spacer()
            Button { draft() } label: { Label("Написать с Claude", systemImage: "sparkles") }
                .buttonStyle(.glass).controlSize(.small)
                .disabled(drafting || working)
                .help("Diff ветки уйдёт в Claude. На GitHub ничего не отправляется")
        }
        TextField("Заголовок", text: $title).textFieldStyle(.roundedBorder).disabled(drafting || working)
        TextEditor(text: $text)
            .font(.body.monospaced())
            .frame(height: 140)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            .disabled(drafting || working)
    }

    private func load() async {
        guard let w = job.worktree else { error = "Worktree уже удалён"; return }
        let wanted = open != nil ? job.pullRequest?.remote : remote
        let p = await Task.detached(priority: .userInitiated) { PullRequestPreview.load(w, remote: wanted) }.value
        guard !Task.isCancelled else { return }
        commits = []
        base = open?.base ?? p.base
        preview = p
        if title.isEmpty, open == nil {
            let path = job.taskPath
            let file = await Task.detached { path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "" }.value
            let d = PullRequestDraft.local(title: job.title, taskText: file)
            title = d.title
            text = d.body
        }
    }

    private func loadCommits() async {
        guard let w = job.worktree, let p = preview, p.problem == nil, !base.isEmpty else { return }
        let b = base
        commits = []
        let list = await Task.detached(priority: .userInitiated) {
            PullRequestPreview.commits(w, tip: p.tip, remote: p.remote, base: b)
        }.value
        if !Task.isCancelled { commits = list }
    }

    private func draft() {
        guard !drafting, let w = job.worktree, let p = preview else { return }
        drafting = true
        error = ""
        let from = job.baseCommit, list = commits, name = job.title, summary = text
        Task {
            let diff = await Task.detached(priority: .userInitiated) {
                let range = "\(from)..\(p.tip)"
                let d = Worktrees.git(["diff", "--stat", range], in: w.main).out + "\n" + Worktrees.git(["diff", range], in: w.main).out
                return d.count > 24_000 ? String(d.prefix(24_000)) + "\n…(обрезано)" : d
            }.value
            // Closed while git ran: don't start (and pay for) a run nobody can stop.
            guard !closed else { return }
            let prompt = """
            Напиши заголовок и описание pull request для изменений ниже на языке истории проекта.
            Первая строка — заголовок до 72 символов, затем пустая строка и описание: что и зачем, 2–6 пунктов «- …».
            Ответь только этим текстом, без кавычек и пояснений.

            Задача: \(name)
            \(summary)
            Коммиты:
            \(list.joined(separator: "\n"))
            Diff:
            \(diff)
            """
            let c = ClaudeProcess()
            c.onExit = { s in
                drafting = false
                proc = nil
                Spend.shared.add(s, project: job.projectName, kind: "Описание PR")
                if !s.failed, let d = PullRequestDraft.parse(s.resultText) {
                    title = d.title
                    text = d.body
                } else if !s.stopped {
                    error = "Claude не ответил — напиши описание вручную"
                }
            }
            do {
                try c.start(ClaudeOptions.oneShot(cwd: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                                                  prompt: prompt, model: .haiku))
                proc = c
            } catch {
                drafting = false
                self.error = error.localizedDescription
            }
        }
    }

    private func publish() {
        guard let p = preview else { return }
        proc?.stop()
        working = true
        error = ""
        Task {
            let e = await store.jobs.publishPR(job, preview: p, base: base,
                                               title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: text)
            working = false
            if let e { error = e } else { dismiss() }
        }
    }
}

/// State of the job's pull request in its card.
struct PullRequestBadge: View {
    @Environment(Store.self) private var store
    let job: Job
    let link: PullRequestLink

    @State private var showStatus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            if let warning = link.ciWarning, link.pr.state != .merged {
                Label("Не сливай: " + warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .sheet(isPresented: $showStatus) { PullRequestStatusSheet(job: job) }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Label("PR #\(link.pr.number) · \(state)", systemImage: "arrow.triangle.pull").foregroundStyle(color)
            if let u = URL(string: link.pr.url) { Link("Открыть", destination: u) }
            if job.worktree != nil {
                Button { showStatus = true } label: {
                    Label(link.ci.title, systemImage: link.ci.icon)
                        .foregroundStyle(link.ci.color)
                }
                .help((link.ci.hint.map { $0 + "\n" } ?? "") + "Проверки, деплои, рецензии, чек-лист и комментарии PR")
                if link.pr.state == .merged, !link.leftover, job.isGroup { // one repository: the card has the button
                    Button("Подтянуть \(link.pr.base)") { store.jobs.pullBase(job) }
                        .help("git fetch и merge --ff-only в основной папке; потом worktree удалится и зависимые задачи стартуют")
                        .disabled(job.worktreeBusy)
                }
                Button { store.jobs.refreshPR(job, report: true) } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .help("Обновить состояние PR и проверки")
                    .disabled(job.worktreeBusy)
            }
        }
        .font(.caption)
        .buttonStyle(.glass)
        .controlSize(.small)
    }

    private var state: String {
        switch link.pr.state {
        case .open: link.pr.isDraft ? "черновик" : "открыт"
        case .merged: "слит"
        case .closed: "закрыт"
        }
    }

    private var color: Color {
        switch link.pr.state {
        case .open: .green
        case .merged: .purple
        case .closed: .red
        }
    }
}
