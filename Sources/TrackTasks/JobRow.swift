import SwiftUI
import TrackTasksCore

struct JobRow: View {
    @Environment(Store.self) var store
    @Environment(\.openWindow) var openWindow
    let job: Job
    /// Opened from «Ждёт тебя».
    var highlighted = false
    @State private var expanded = false
    @State var showReview = false
    @State var panel: Panel?
    @State var showScripts = false
    @State var taskCheckShown: TaskVerify.Refusal?
    @State var forkText = ""

    var children: [Job] { store.jobs.jobs.filter { $0.parentID == job.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            card
                .contentShape(.rect)
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            // Outside the tap area: clicks belong to the terminal.
            if Terminals.shared.shown.contains(job.id) { TerminalPanel(job: job) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(stateColor.opacity(0.08)), in: .rect(cornerRadius: 16))
        .overlay {
            if highlighted { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 2) }
        }
        .onChange(of: highlighted, initial: true) { if highlighted { expanded = true } }
        .modifier(MergeQuestions(job: job))
    }

    private var card: some View {
        var facts = store.jobs.facts(job)
        if store.project(job.projectID) == nil { facts.offers[.commit] = nil }
        let guide = JobGuide.of(facts)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                stateIcon(job).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.headline).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(store.jobs.kindTitle(job.kind))
                        Text("·")
                        Text(job.projectName)
                        if let m = job.modelTitle, job.lane == .code {
                            Text("·")
                            Text(m)
                                .foregroundStyle(job.model == .opus ? .purple : .blue)
                                .help(job.modelReason.isEmpty ? "Модель задачи" : "Почему: \(job.modelReason)")
                        }
                        if let s = job.server {
                            Text("·")
                            Label(s.title, systemImage: "network").labelStyle(CompactLabel())
                                .help("Работает на сервере, результат возвращается в worktree")
                        }
                        if job.fullAccess {
                            Text("·")
                            Text("полный доступ").foregroundStyle(.red)
                                .help("Последний запуск шёл с --dangerously-skip-permissions (опасный режим)")
                        }
                        if let w = job.wave, let p = job.wavePriority {
                            Text("·")
                            HStack(spacing: 3) {
                                Circle().fill(p.color.gradient).frame(width: 7, height: 7)
                                Text("волна \(w)/\(job.waveCount ?? w) · \(p.rawValue)")
                            }
                            .help("Волнами по приоритету: волна \(w) из \(job.waveCount ?? w), приоритет «\(p.title)»")
                        }
                        let deps = job.dependsOn.compactMap { store.jobs.job($0) }
                            .filter { $0.wave == nil || $0.wave == job.wave }
                        if !deps.isEmpty {
                            Text("·")
                            Label("после " + deps.map { "«\($0.title)»" }.joined(separator: ", "), systemImage: "link")
                                .labelStyle(CompactLabel())
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                let cost = job.cost.text(digits: 3)
                if cost != nil || !job.summary.isEmpty {
                    Text(cost ?? job.summary)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help(job.summary)
                }
            }
            statusLine(guide)
            if job.state == .pending {
                let unblocks = store.jobs.unblocks(job)
                if unblocks > 0 {
                    Label("разблокирует \(unblocks)", systemImage: "lock.open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Столько незавершённых задач ждут эту, прямо или через другие: при равном приоритете она идёт раньше")
                }
            }
            actions(facts.offers, guide)
            ForEach(job.permissions) { r in
                PermissionCard(request: r, agent: store.jobs.agentTitle(job), prominent: r.id == firstPermission) { allow, always in
                    store.jobs.answer(job, r, allow: allow, always: always)
                }
            }
            JobRowPipeline(job: job, prominent: guide.card == .pipeline)
            JobQuestionsCard(job: job)
            PlanApprovalCard(job: job, prominent: guide.card == .plan)
            if !job.lastLine.isEmpty, job.lastLine != guide.reason {
                Text(job.lastLine)
                    .font(.callout)
                    .foregroundStyle(job.state == .failed ? .red : .secondary)
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
            }
            if let r = job.remote, RemoteStatus.shared.pendingStops.contains(r.id) {
                Label("Остановка на сервере не подтверждена, повторяю", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if job.remoteUnclaimed, !job.isActive {
                Label("Результат на сервере \(job.remote?.server.title ?? "") не забран: «\(facts.offers[.retry]?.title ?? "Повторить")» подключится к запуску", systemImage: "tray.and.arrow.down")
                    .font(.caption).foregroundStyle(.orange)
            }
            if job.executor == .docker {
                Label("Docker", systemImage: "shippingbox").font(.caption).foregroundStyle(.blue)
                    .help("Агент, setup и verify идут в контейнере: доступен только worktree")
            }
            if let w = job.worktree {
                Label(job.isActive ? "Параллельно, в отдельном worktree · \(w.branch)" : w.branch,
                      systemImage: "arrow.triangle.branch")
                    .font(.caption.monospaced())
                    .foregroundStyle(.purple)
            }
            forkLinks
            handoffLines
            JobReposView(job: job)
            if let link = job.pullRequest { PullRequestBadge(job: job, link: link) }
            if let w = job.worktree, !job.isActive, let why = ContainerStore.shared.refusal(w.path) {
                HStack(spacing: 8) {
                    Text(why).font(.caption).foregroundStyle(.orange)
                    Button("Проверить снова") { store.jobs.recheckContainer(job) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            if !job.worktreeNote.isEmpty {
                Text(job.worktreeNote)
                    .font(.caption)
                    .foregroundStyle(job.merged ? .green : job.mergeCheck?.state == .red ? .red : .secondary)
                    .textSelection(.enabled)
            }
            if let r = job.taskCheckRefusal, !job.verifyNote.hasPrefix(JobQueue.taskCheckRefused) {
                Label("Проверка задачи: " + r.why, systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
            }
            if !job.verifyNote.isEmpty {
                // Green only while nothing newer says otherwise: this is the branch alone, before main was merged in.
                let red = job.mergeCheck?.state == .red
                Label((red ? "Без свежего main · " : "") + job.verifyNote,
                      systemImage: job.verifyFailed ? "xmark.seal.fill" : red ? "checkmark.seal" : "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(job.verifyFailed ? .red : red ? .secondary : .green)
            }
            if let c = job.mergeCheck, c.state == .red {
                let errors = VerifyErrors.lines(c.output)
                if !errors.isEmpty {
                    Text(errors.prefix(3).joined(separator: "\n"))
                        .font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            if let c = job.mergeCheck, c.state == .red, !c.output.isEmpty, expanded {
                Text(c.output.suffix(2000)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !job.diffStat.isEmpty {
                Label(job.diffStat, systemImage: "plusminus").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            RollbackBanner(job: job, prominent: guide.card == .rollback)
            CriteriaEvidence(job: job)
            reviewBlock(facts.offers[.fixReview], main: guide.primary == .fixReview)
            JobReplyView(job: job)
            ForEach(children.filter(\.isActive)) { c in
                HStack(spacing: 6) {
                    stateIcon(c).controlSize(.mini)
                    Text("\(store.jobs.kindTitle(c.kind)): \(c.state == .pending ? store.jobs.waitReason(c) : c.lastLine)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { store.jobs.cancel(c) } label: { Label("Остановить", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                        .buttonStyle(.glass).controlSize(.small)
                }
                ForEach(c.permissions) { r in
                    PermissionCard(request: r, context: store.jobs.kindTitle(c.kind), agent: store.jobs.agentTitle(c),
                                   prominent: r.id == firstPermission) { allow, always in
                        store.jobs.answer(c, r, allow: allow, always: always)
                    }
                }
            }
            if expanded && !job.log.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(job.log.enumerated()), id: \.offset) { _, l in
                        if l.hasPrefix("⚙︎ ") {
                            Text(l).font(.caption.monospaced()).foregroundStyle(.secondary)
                        } else {
                            MarkdownView(text: l)
                        }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One request at a time has the main button and its shortcut.
    private var firstPermission: String? {
        (job.permissions.first ?? children.lazy.filter(\.isActive).compactMap(\.permissions.first).first).map(\.id)
    }

    /// What is going on, why, and what to do next.
    private func statusLine(_ g: JobGuide) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(g.status, systemImage: g.tone.icon).font(.callout.weight(.semibold)).foregroundStyle(g.tone.color)
                if g.need != nil { Pill(text: "ждёт тебя", color: .orange) }
            }
            if !g.reason.isEmpty {
                Text(g.reason).font(.callout).foregroundStyle(g.tone == .bad ? .red : .secondary)
                    .lineLimit(expanded ? nil : 2).textSelection(.enabled)
                    .help(job.dirtyMain.joined(separator: "\n"))
            }
            Text("Дальше: \(g.next)").font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var stateColor: Color {
        switch job.state {
        case .pending: .gray
        case .running: .orange
        case .done: job.verifyFailed ? .red : .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    @ViewBuilder
    private func stateIcon(_ j: Job) -> some View {
        switch j.state {
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(j.verifyFailed ? .orange : .green)
        case .failed: Image(systemName: j.interrupted ? "pause.circle.fill" : "xmark.octagon.fill").foregroundStyle(j.interrupted ? .orange : .red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

extension JobGuide.Tone {
    var color: Color {
        switch self {
        case .idle: .secondary
        case .working: .blue
        case .attention: .orange
        case .bad: .red
        case .good: .green
        }
    }
    var icon: String {
        switch self {
        case .idle: "clock"
        case .working: "bolt.fill"
        case .attention: "hand.raised.fill"
        case .bad: "exclamationmark.triangle.fill"
        case .good: "checkmark.circle.fill"
        }
    }
}
