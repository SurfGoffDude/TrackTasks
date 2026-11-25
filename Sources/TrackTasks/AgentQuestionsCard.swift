import SwiftUI
import TrackTasksCore

/// Answers being prepared, by task file: the same in all places, kept when a screen or a card is closed.
@MainActor @Observable final class QuestionDrafts {
    static let shared = QuestionDrafts()

    struct Entry: Equatable {
        var draft = QuestionDraft()
        /// The card is folded; the questions stay.
        var closed = false
        var sending = false
        var note = ""
    }
    private var entries: [String: Entry] = [:]

    subscript(path: String) -> Entry {
        get { entries[path] ?? Entry() }
        set {
            if newValue == Entry() { entries[path] = nil; return }
            if entries[path] == nil { dropStale() }
            entries[path] = newValue
        }
    }
    var paths: Set<String> { Set(entries.keys) }

    /// Nobody will answer: the task is deleted, moved to the archive or done.
    private func dropStale() {
        for (path, e) in entries where !e.sending {
            let gone = !FileManager.default.fileExists(atPath: path)
            // A file that can't be read now keeps its draft.
            if gone || Codec.task(at: URL(fileURLWithPath: path))?.status == .done { entries[path] = nil }
        }
    }

    /// Typed answers are dropped only when they are in the file.
    func finish(_ path: String, _ outcome: JobQueue.AnswerOutcome, submitted: Bool) {
        var e = self[path]
        e.sending = false
        switch outcome {
        case .saved(let left):
            if submitted { e.draft = QuestionDraft() }
            e.note = left > 0 ? "Ответы сохранены. Появились новые вопросы: \(left)" : ""
        case .continued:
            e = Entry()
        case .refused(let why):
            if submitted { e.draft = QuestionDraft() }
            e.note = (submitted ? "Ответы записаны в файл, но агент не продолжил: " : "Агент не продолжил: ") + why
        case .writeFailed(let why):
            e.note = "Не записано: \(why)"
        case .busy:
            e.note = "Не отправлено: агент работает или ответы уже отправляются"
        }
        self[path] = e
    }
}

/// «Claude спрашивает»: one question at a time, as in the CLI.
struct AgentQuestionsCard: View {
    struct Item {
        var text: String
        var options: [AgentQuestions.Option]
        var details = ""

        init(_ q: AgentQuestions.Question) { (text, options, details) = (q.text, q.options, q.details) }
        init(_ i: JobQuestions.Item) {
            text = i.text
            options = i.options.indices.map { .init(text: i.options[$0], recommended: i.recommended.contains($0)) }
        }
    }

    @Environment(Store.self) private var store
    let taskPath: String
    let projectID: String?
    let status: QuestionStatus
    let items: [Item]
    /// No run of the agent goes on after this: the answers are only written.
    let saveOnly: Bool
    var agent = "Claude"

    private var drafts: QuestionDrafts { .shared }

    var body: some View {
        let e = drafts[taskPath]
        VStack(alignment: .leading, spacing: 10) {
            header(e)
            if !e.closed, case .ask = status, !items.isEmpty { question(e) }
            if !e.note.isEmpty {
                Label(e.note, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status == .send {
                Button("Передать ответы агенту", action: resend)
                    .buttonStyle(.glassProminent).controlSize(.small)
                    .disabled(e.sending)
                    .help("Ответы уже в файле задачи")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: .rect(cornerRadius: 12))
    }

    private func header(_ e: QuestionDrafts.Entry) -> some View {
        HStack(spacing: 8) {
            Label("\(agent) спрашивает", systemImage: "questionmark.bubble.fill").font(.headline).foregroundStyle(.orange)
            Text(status.line).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if e.sending { ProgressView().controlSize(.small).accessibilityLabel("Ответы отправляются") }
            if case .ask = status {
                if e.closed {
                    Button("Ответить") { drafts[taskPath].closed = false }
                        .buttonStyle(.glassProminent).controlSize(.small)
                        .accessibilityLabel("Ответить на вопросы")
                } else {
                    Button { drafts[taskPath].closed = true } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Свернуть: вопросы и введённое останутся")
                        .accessibilityLabel("Свернуть вопросы")
                }
            }
        }
    }

    @ViewBuilder
    private func question(_ e: QuestionDrafts.Entry) -> some View {
        let keys = QuestionDraft.keys(items.map(\.text))
        let i = e.draft.current(keys)
        let key = keys[i], q = items[i], pick = e.draft.pick(key)
        VStack(alignment: .leading, spacing: 8) {
            if items.count > 1 {
                Text("Вопрос \(i + 1) из \(items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            MD.inline(q.text).font(.body.weight(.medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !q.details.isEmpty { MarkdownView(text: q.details).foregroundStyle(.secondary) }
            ForEach(Array(q.options.enumerated()), id: \.offset) { _, o in
                choice(selected: pick == .option(o.text), label: o.text + (o.recommended ? ", рекомендую" : "")) {
                    MD.inline(o.text).fixedSize(horizontal: false, vertical: true)
                    if o.recommended { Pill(text: "рекомендую", color: .green) }
                } action: { drafts[taskPath].draft.choose(key, .option(o.text)) }
            }
            TextField("Свой ответ", text: Binding(get: { drafts[taskPath].draft.ownText(key) },
                                                  set: { drafts[taskPath].draft.type(key, $0) }), axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .overlay { if pick == .own { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1.5) } }
                .accessibilityLabel("Свой ответ на вопрос: \(q.text)")
                .accessibilityValue(drafts[taskPath].draft.ownText(key))
                .accessibilityAddTraits(pick == .own ? .isSelected : [])
            // A typed answer put aside by an option can be picked again.
            if pick != .own, !e.draft.ownText(key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                choice(selected: false, label: "Взять свой ответ") { Text("Взять свой ответ") } action: {
                    drafts[taskPath].draft.choose(key, .own)
                }
            }
            choice(selected: pick == .decide, label: "Решай сам") { Text("Решай сам") } action: {
                drafts[taskPath].draft.choose(key, .decide)
            }
            .help("Агент выберет сам и запишет решение в «Заметки»")
            navigation(e, keys, i)
        }
        .disabled(e.sending)
    }

    private func navigation(_ e: QuestionDrafts.Entry, _ keys: [String], _ i: Int) -> some View {
        let last = i == keys.count - 1
        return HStack(spacing: 8) {
            if keys.count > 1 {
                Button("Назад") { drafts[taskPath].draft.go(-1, keys) }
                    .buttonStyle(.glass).disabled(i == 0)
                    .accessibilityLabel("Назад, к предыдущему вопросу")
            }
            if !last {
                Button("Далее") { drafts[taskPath].draft.go(1, keys) }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Далее, к следующему вопросу")
            } else {
                Button(saveOnly ? "Сохранить ответы" : "Ответить и продолжить", action: submit)
                    .buttonStyle(.glassProminent)
                    .disabled(!e.draft.isReady(keys))
                    .help(saveOnly ? "Записать ответы в файл задачи" : "Записать ответы в файл задачи и передать агенту")
                if let m = e.draft.missing(keys) {
                    Text(keys.count > 1 ? "Нет ответа на вопрос \(m + 1)" : "Выбери вариант или напиши свой")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .controlSize(.small)
    }

    private func choice<L: View>(selected: Bool, label: String, @ViewBuilder _ content: () -> L, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                content()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.15) : .primary.opacity(0.05), in: .rect(cornerRadius: 9))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func submit() {
        let texts = items.map(\.text)
        let draft = drafts[taskPath].draft
        guard !drafts[taskPath].sending, draft.isReady(QuestionDraft.keys(texts)) else { return }
        start()
        Task {
            let r = await store.jobs.submitAnswers(taskPath: taskPath, draft.answers(texts))
            done(r, submitted: true)
        }
    }

    private func resend() {
        guard !drafts[taskPath].sending, let job = store.jobs.latestJob(forTask: taskPath) else { return }
        start()
        done(store.jobs.continueWithAnswers(job), submitted: false)
    }

    private func start() {
        drafts[taskPath].sending = true
        drafts[taskPath].note = ""
    }

    private func done(_ r: JobQueue.AnswerOutcome, submitted: Bool) {
        // Before the folder is scanned: the answered questions must not be asked again.
        if let projectID, let t = Codec.task(at: URL(fileURLWithPath: taskPath)) { store.patch(t, projectID: projectID) }
        drafts.finish(taskPath, r, submitted: submitted)
    }
}

/// The card of a job in the queue and on «Сегодня».
struct JobQuestionsCard: View {
    @Environment(Store.self) private var store
    let job: Job

    var body: some View {
        let status = store.jobs.questionStatus(job)
        if status.needsPerson, let path = job.taskPath {
            AgentQuestionsCard(taskPath: path, projectID: job.projectID, status: status, items: items(path), saveOnly: false,
                               agent: store.jobs.agentTitle(job))
        }
    }

    /// The queue knows what is open; the file has the text around it.
    private func items(_ path: String) -> [AgentQuestionsCard.Item] {
        let parsed = (store.project(job.projectID)?.tasks.first { $0.id == path }).map { AgentQuestions.parse($0.body) } ?? []
        return (job.questions?.open ?? []).map { q in
            parsed.first { $0.text == q.text }.map { AgentQuestionsCard.Item($0) } ?? .init(q)
        }
    }
}

/// «Вопросы» of an open task: the card for the open ones, then the answered ones.
struct TaskQuestions: View {
    @Environment(Store.self) private var store
    let task: TaskItem
    let projectID: String
    let questions: [AgentQuestions.Question]

    var body: some View {
        let job = store.jobs.latestJob(forTask: task.id)
        let working = job.map(store.jobs.agentWorks) ?? false
        let asks = task.status != .done && task.folder != .archive
        let open = asks ? questions.filter(\.isOpen) : []
        // Waits for a slot, not for the plan's approval: the run will read the file.
        let notStarted = job.map { $0.state == .pending && !$0.awaitingPlan } ?? false
        // After a refusal the answers are in the file, the agent doesn't have them.
        let status = !open.isEmpty ? QuestionStatus.ask(open.count)
            : asks ? job.map(store.jobs.questionStatus) ?? .none : .none
        let card = !working && (status == .send || !open.isEmpty)
        VStack(alignment: .leading, spacing: 10) {
            let preamble = AgentQuestions.preamble(task.body)
            if !preamble.isEmpty { MarkdownView(text: preamble) }
            if card {
                AgentQuestionsCard(taskPath: task.id, projectID: projectID, status: status, items: open.map { .init($0) },
                                   saveOnly: job == nil || notStarted,
                                   agent: job.map(store.jobs.agentTitle) ?? "Claude")
            } else if !open.isEmpty {
                Text("Ответить можно, когда агент закончит").font(.caption).foregroundStyle(.secondary)
            }
            // The card has the open ones.
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                if !q.isOpen || !card { row(q) }
            }
        }
    }

    private func row(_ q: AgentQuestions.Question) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MD.inline(q.text).fontWeight(.medium)
            if !q.details.isEmpty { MarkdownView(text: q.details).foregroundStyle(.secondary) }
            ForEach(Array(q.options.enumerated()), id: \.offset) { _, o in
                MD.inline("• " + o.text + (o.recommended ? " (рекомендую)" : "")).font(.callout).foregroundStyle(.secondary)
            }
            if let a = q.answer {
                Label { MD.inline(a).textSelection(.enabled) } icon: { Image(systemName: "arrowshape.turn.up.left.fill") }
                    .font(.callout)
                    .accessibilityLabel("Ответ: \(a)")
            } else {
                Text("без ответа").font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
