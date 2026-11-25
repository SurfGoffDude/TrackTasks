import SwiftUI
import TrackTasksCore

/// Who gets the task, how much and the exact text. Nothing is sent without the button.
struct HandoffSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let job: Job

    @State private var draft: HandoffDraft?
    @State private var profile = ""
    @State private var note = ""
    /// Made when the draft or the note changes, not on every redraw.
    @State private var text = ""
    @State private var busy = false
    @State private var error = ""

    private var profiles: [AgentProfile] { store.jobs.profiles().all }
    private var chosen: AgentProfile? { profiles.first { $0.id == profile } }
    private var refusal: String? { chosen.map { store.jobs.handoffRefusal(job, to: $0) } ?? "Выбери профиль" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Передать другому агенту").font(.title3.bold())
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass).disabled(busy).help("Собрать текст заново")
            }
            Text(verbatim: "Сейчас: \(store.jobs.handoffTitle(job.handoffSide)). Его сессия не изменится.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Получатель", selection: $profile) {
                if chosen == nil { Text("—").tag(profile) }
                ForEach(profiles) { Text($0.title).tag($0.id) }
            }
            if let p = chosen {
                Text(verbatim: "Агент: \(store.jobs.agents[p.agent]?.title ?? p.agent.rawValue) · модель: \(p.model.isEmpty ? "по умолчанию" : p.model)"
                     + (p.server.map { " · сервер: \($0.title)" } ?? "") + (p.acp.map { " · \($0.title)" } ?? ""))
                    .font(.caption)
            }
            if let refusal { Label(refusal, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            Text("Текст с кодом уйдёт сервису этого агента. Агент сможет читать и остальные файлы папки задачи; к тексту трекер добавит обычный системный промпт с правилами и путями.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let draft {
                ForEach(draft.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                HStack {
                    Text("Уйдёт агенту: \(text.unicodeScalars.count) знаков").font(.headline)
                    if draft.text.removed > 0 { Text("вычищено ключей и путей: \(draft.text.removed)").font(.caption).foregroundStyle(.orange) }
                }
                Text(verbatim: draft.text.parts.map { p in
                    "\(p.title): " + (p.text.isEmpty ? "нет" : p.cut ? "\(p.size) из \(p.full), обрезано" : "\(p.size)")
                }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(draft.text.cut ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(verbatim: text).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            } else {
                Text(busy ? "Собираю текст…" : "Текст не собран").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !error.isEmpty { Text(verbatim: error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(4) }
            TextField("Указание агенту от себя (необязательно)", text: $note, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
                .onChange(of: note) { compose() }
            HStack {
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Передать") { send() }
                    .buttonStyle(.glassProminent)
                    .disabled(text.isEmpty || busy || refusal != nil || store.jobs.handoffBlocked(job) != nil)
            }
        }
        .padding(20)
        .frame(width: 720, height: 700)
        .task {
            profile = profiles.first { store.jobs.handoffRefusal(job, to: $0) == nil }?.id ?? ""
            load()
        }
    }

    private func compose() { text = draft?.text.message(note: note) ?? "" }

    private func load() {
        guard !busy else { return }
        busy = true
        error = ""
        draft = nil
        text = ""
        Task {
            let r = await store.jobs.prepareHandoff(job)
            busy = false
            switch r {
            case .failure(let e): error = e.message
            case .success(let d): draft = d
            }
            compose()
        }
    }

    private func send() {
        guard let draft, !busy else { return }
        busy = true
        error = ""
        let note = note
        Task {
            // The field may have changed in the same moment: only what is shown goes.
            guard draft.text.message(note: note) == text else {
                busy = false
                return compose()
            }
            let why = await store.jobs.handOff(job, draft, to: profile, note: note)
            busy = false
            if let why { error = why } else { dismiss() }
        }
    }
}

extension JobRow {
    /// Who had the task before.
    @ViewBuilder var handoffLines: some View {
        ForEach(Array(job.handoffs.enumerated()), id: \.offset) { _, h in
            HStack(spacing: 8) {
                Label((h.status == .failed ? "Не передано: " : h.status == .waiting ? "Передаётся: " : "Передано: ")
                      + "\(store.jobs.handoffTitle(h.from)) → \(store.jobs.handoffTitle(h.to)), \(h.date.formatted(date: .numeric, time: .shortened))"
                      + (h.session.map { " · прежняя сессия \($0)" } ?? ""),
                      systemImage: "arrow.left.arrow.right")
                    .font(.caption).foregroundStyle(h.status == .failed ? .orange : .secondary).textSelection(.enabled)
                // The failed one's session is the job's own again.
                if h.status == .accepted, h.from.agent == .claude, let sid = h.session, job.executor != .docker,
                   !ContainerStore.shared.isContainer(job.runDir), !job.hadWorktree || job.worktree != nil {
                    let why = store.jobs.terminalClaudeBlocked(job)
                    Button("Прежний диалог в терминале") { continueInTerminal(sid, embedded: Terminals.embedded) }
                        .buttonStyle(.glass).controlSize(.small)
                        .disabled(why != nil)
                        .help(why ?? store.claudeCommand(resume: sid))
                }
            }
        }
    }
}
