import SwiftUI
import TrackTasksCore

extension CIVerdict {
    var title: String {
        switch self {
        case .red: "CI красный"
        case .green: "CI зелёный"
        case .running: "CI идёт"
        case .none: "Нет проверок"
        case .confirming: "CI подтверждается"
        case .wrongCommit: "CI: не тот коммит"
        case .unknown: "CI неизвестен"
        }
    }
    var icon: String {
        switch self {
        case .red: "xmark.circle.fill"
        case .green: "checkmark.circle.fill"
        case .running: "clock.arrow.circlepath"
        case .none: "minus.circle"
        case .confirming: "checkmark.circle.dotted"
        case .wrongCommit: "arrow.triangle.branch"
        case .unknown: "questionmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .red: .red
        case .green: .green
        case .running, .confirming, .wrongCommit: .orange
        case .none, .unknown: .secondary
        }
    }
    var hint: String? {
        switch self {
        case .confirming: "Проверки зелёные, но нужен ещё один такой же ответ GitHub не раньше чем через \(Int(CIConfirmation.pause)) с"
        case .wrongCommit: "Ответ GitHub относится не к коммиту, который отправило приложение"
        case .red, .green, .running, .none, .unknown: nil
        }
    }
}

/// Readiness of a pull request and its comments. Nothing goes to the agent until the person ticks comments and sends them.
struct PullRequestStatusSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let job: Job

    @State private var comments: [PullRequestComment]?
    @State private var cut = false
    @State private var loading = false
    @State private var error = ""
    /// Whole comments, not ids: one edited on GitHub since it was ticked is no longer chosen.
    @State private var chosen: Set<PullRequestComment> = []
    @State private var note = ""
    @State private var fixing = false

    private var link: PullRequestLink? { job.pullRequest }
    private var status: PullRequestStatus? { link?.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PR #\(link?.pr.number ?? 0) · готовность").font(.title3.bold())
                if let link, let s = status {
                    Label(link.ci.title, systemImage: link.ci.icon).foregroundStyle(link.ci.color).help(link.ci.hint ?? "")
                    Text("на \(s.updated.formatted(date: .omitted, time: .shortened)) · \(String(s.headOid.prefix(8)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if status?.ci == .red {
                    Button("Исправить CI", systemImage: "wrench.and.screwdriver") { fixing = true }
                        .buttonStyle(.glass)
                        .disabled(fixBlocked != nil)
                        .help(fixBlocked ?? "Показать логи упавших проверок и отправить их агенту")
                }
                if loading { ProgressView().controlSize(.small) }
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass).disabled(loading).help("Обновить")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    checks("Проверки", status?.checks, empty: "Проверок нет", unknown: "Проверки получить не удалось — обнови")
                    checks("Деплои", status?.deployments, empty: "Деплоев нет", unknown: "Деплои неизвестны")
                    commentList
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(4) }
            footer
        }
        .padding(20)
        .frame(width: 680, height: 620)
        .task { reload() }
        .sheet(isPresented: $fixing) { CIFixSheet(job: job) }
    }

    private var fixBlocked: String? {
        link?.ci == .red ? store.jobs.ciFixBlocked(job) : link?.ci.hint ?? "CI неизвестен"
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if status?.ci == .red, link?.ci == .red, let why = fixBlocked {
                Text("Исправить CI сейчас нельзя: " + why).font(.caption).foregroundStyle(.secondary)
            }
            if let hint = link?.ci.hint { Text(hint).font(.caption).foregroundStyle(.orange) }
            switch status?.review {
            case .approved: Label("Рецензия: одобрено", systemImage: "hand.thumbsup.fill").foregroundStyle(.green)
            case .changesRequested: Label("Рецензия: просят правки", systemImage: "hand.raised.fill").foregroundStyle(.red)
            case .required: Label("Рецензия: ждёт одобрения", systemImage: "hourglass").foregroundStyle(.orange)
            case nil: Label(status == nil ? "Рецензии неизвестны" : "Решения по рецензии нет", systemImage: "person.2").foregroundStyle(.secondary)
            }
            if status?.conflict == true {
                Label("Конфликт с \(link?.pr.base ?? "основной веткой")", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if let t = store.project(job.home.projectID)?.tasks.first(where: { $0.url.standardizedFileURL.path == taskPath }) {
                let items = MD.checklist(t.body) + MD.checklist(t.body, in: .criteria)
                let left = items.filter { !$0.done }
                if !items.isEmpty {
                    Label("Чек-листы задачи: \(items.count - left.count) из \(items.count)", systemImage: "checklist")
                        .foregroundStyle(left.isEmpty ? .green : .orange)
                        .help(left.map(\.text).joined(separator: "\n"))
                    ForEach(left, id: \.n) { Text("☐ \($0.text)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var taskPath: String? { job.taskPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } }

    @ViewBuilder
    private func checks(_ title: String, _ list: [PullRequestCheck]?, empty: String, unknown: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let list {
                if list.isEmpty { Text(empty).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(list.enumerated()), id: \.offset) { _, c in
                    HStack {
                        icon(c.state)
                        Text(verbatim: c.name).lineLimit(1)
                        Spacer()
                        if let l = c.link, let u = URL(string: l) { Link("Лог", destination: u).help(l) }
                    }
                    .font(.callout)
                }
            } else {
                Text(unknown).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func icon(_ s: PullRequestCheck.State) -> some View {
        switch s {
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Прошла")
        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Не прошла")
        case .pending: Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange).help("Идёт")
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary).help("Пропущена")
        }
    }

    @ViewBuilder
    private var commentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Комментарии").font(.headline)
            Text("Чужой текст: агент получит только отмеченное, как данные. Прочитай, прежде чем отправлять.")
                .font(.caption).foregroundStyle(.secondary)
            if cut { Text("Показаны не все комментарии — остальные смотри на GitHub.").font(.caption).foregroundStyle(.orange) }
            if let comments {
                if comments.isEmpty { Text("Комментариев нет").font(.caption).foregroundStyle(.secondary) }
                ForEach(comments) { row($0) }
            }
        }
    }

    private func row(_ c: PullRequestComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { chosen.contains(c) }, set: { if $0 { chosen.insert(c) } else { chosen.remove(c) } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: c.author).bold()
                    if let p = c.path { Text(verbatim: p + (c.line.map { ":\($0)" } ?? "")).monospaced().lineLimit(1) }
                    if c.verdict == "CHANGES_REQUESTED" { Text("просит правки").foregroundStyle(.red) }
                    if c.verdict == "APPROVED" { Text("одобрено").foregroundStyle(.green) }
                    if c.resolved { Text("решено").foregroundStyle(.secondary) }
                    if c.outdated { Text("устарело").foregroundStyle(.orange) }
                    Spacer()
                    if let l = c.url, let u = URL(string: l) { Link("Открыть", destination: u) }
                }
                .font(.caption)
                // Plain text, in full: what is shown is what is sent (Markdown could hide parts of it).
                Text(verbatim: c.body).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .opacity(c.resolved ? 0.6 : 1)
    }

    private var footer: some View {
        let blocked = store.jobs.replyBlocked(job.home)
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Указание агенту от себя (необязательно)", text: $note, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
            if let blocked { Text(blocked).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Отправить агенту (\(chosen.count))") { send() }
                    .buttonStyle(.glassProminent)
                    .disabled(chosen.isEmpty || blocked != nil)
            }
        }
    }

    private func reload() {
        guard !loading, let link, let w = job.worktree else { return }
        loading = true
        error = ""
        store.jobs.refreshPR(job)
        Task {
            let r = await Task.detached(priority: .userInitiated) { GitHubCLI.comments(link.pr.url, in: w.main) }.value
            loading = false
            guard let list = r.list else { error = "Комментарии не получены: " + r.error; return }
            comments = list
            cut = r.cut
            chosen.formIntersection(list)
        }
    }

    private func send() {
        guard let link, let comments else { return }
        let text = PullRequestComment.message(comments.filter(chosen.contains), note: note, pr: link.pr.number)
        guard FileManager.default.fileExists(atPath: job.home.runDir.path) else { error = "Папка сессии удалена: \(job.home.runDir.path)"; return }
        if store.jobs.sendReply(job.home, text: (job.owner == nil ? "" : "Репозиторий «\(job.repoName)». ") + text) { dismiss() } else { error = "Сейчас отправить нельзя" }
    }
}
