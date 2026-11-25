import SwiftUI
import TrackTasksCore

/// Messages to the finished job's agent and the field for the next one.
/// A view of its own, so typing doesn't redraw the whole row.
struct JobReplyView: View {
    @Environment(Store.self) private var store
    @Bindable var job: Job
    @State private var open = false
    @State private var sendError = ""

    private var canReply: Bool { job.sessionID != nil && (job.worktree != nil || job.kind != .runTask || !store.jobs.requiresWorktree(job)) && store.jobs.capabilities(job).contains(.resume) }

    var body: some View {
        if !job.replies.isEmpty || (!job.isActive && canReply) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(job.replies) { entry($0) }
                if !job.isActive, canReply { composer }
            }
        }
    }

    @ViewBuilder
    private func entry(_ r: AgentReply) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { Text(r.text).textSelection(.enabled) } icon: { Image(systemName: "person.fill") }
                .font(.callout)
            if !r.answer.isEmpty {
                MarkdownView(text: r.answer)
            }
            switch r.state {
            case .active, .done: EmptyView()
            case .failed, .cancelled:
                HStack(spacing: 8) {
                    Text(r.state == .cancelled ? "Остановлено" : "Ответ не выполнен: \(r.error)")
                        .font(.caption)
                        .foregroundStyle(r.state == .failed ? .red : .secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Повторить") { store.jobs.repeatReply(job, r) }
                        .buttonStyle(.glass).controlSize(.small)
                        .disabled(store.jobs.replyBlocked(job) != nil)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    @ViewBuilder
    private var composer: some View {
        let blocked = store.jobs.replyBlocked(job)
        if open || !job.replyDraft.isEmpty {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Сообщение агенту…", text: $job.replyDraft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) { Label("Отправить", systemImage: "paperplane.fill") }
                    .buttonStyle(.glass)
                    .disabled(blocked != nil || job.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Продолжить эту же сессию агента (\(store.jobs.agentTitle(job))) в той же папке")
            }
            // Keep the draft across restarts without writing the queue on every key.
            .task(id: job.replyDraft) {
                try? await Task.sleep(for: .milliseconds(700))
                if !Task.isCancelled { store.jobs.save() }
            }
            .onDisappear { store.jobs.save() }
        } else if blocked == nil {
            Button { open = true } label: { Label("Ответить агенту", systemImage: "arrowshape.turn.up.left") }
                .buttonStyle(.glass).controlSize(.small)
        }
        if let note = blocked ?? (sendError.isEmpty ? nil : sendError) {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func send() {
        guard store.jobs.replyBlocked(job) == nil else { return }
        guard FileManager.default.fileExists(atPath: job.runDir.path) else {
            sendError = "Ответить нельзя: папка сессии удалена (\(job.runDir.path))"
            return
        }
        sendError = ""
        if store.jobs.sendReply(job, text: job.replyDraft) {
            job.replyDraft = ""
            open = false
            store.jobs.save()
        }
    }
}
