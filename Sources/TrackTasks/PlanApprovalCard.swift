import SwiftUI
import TrackTasksCore

/// Plan written by the agent: read it, then «Одобрить» or «Доработать» with a comment.
/// Used in the queue and on «Сегодня»; a view of its own, so typing doesn't redraw the row.
struct PlanApprovalCard: View {
    @Environment(Store.self) private var store
    let job: Job
    var showPlan = true
    var prominent = true
    @State private var reworking = false
    @State private var comment = ""

    private var plan: String {
        guard let path = job.taskPath,
              let body = store.project(job.projectID)?.tasks.first(where: { $0.id == path })?.body else { return "" }
        return MD.plan(body)
    }

    var body: some View {
        if job.state == .pending, job.awaitingPlan {
            VStack(alignment: .leading, spacing: 8) {
                if showPlan {
                    if plan.isEmpty {
                        Text("План лежит в файле задачи («## План»).").font(.caption).foregroundStyle(.secondary)
                    } else {
                        MarkdownView(text: plan)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                    }
                }
                if reworking {
                    TextField("Что поправить в плане…", text: $comment, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendRework)
                }
                PlanFilesSuggestion(job: job, plan: plan)
                HStack(spacing: 8) {
                    let asks = job.questions?.open.isEmpty == false
                    Button(asks ? "Одобрить без ответов" : "Одобрить") { store.jobs.approvePlan(job) }
                        .buttonStyle(prominent ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
                        .help(asks ? "Вопросы останутся без ответа: агент выполнит задачу по плану, как есть"
                              : "Агент выполнит задачу по плану, в той же сессии, если её можно продолжить")
                    if reworking {
                        Button("Отправить", action: sendRework)
                            .buttonStyle(.glass)
                            .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Отмена") { reworking = false; comment = "" }
                            .buttonStyle(.glass)
                    } else {
                        Button("Доработать") { reworking = true }
                            .buttonStyle(.glass)
                            .help("Вернуть план агенту с комментарием")
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func sendRework() {
        store.jobs.reworkPlan(job, comment: comment)
        reworking = false
        comment = ""
    }
}
