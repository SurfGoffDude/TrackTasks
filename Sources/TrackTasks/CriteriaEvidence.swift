import SwiftUI
import TrackTasksCore

extension JobQueue {
    private func runs(task path: String) -> [Job] { jobs.filter { $0.kind == .runTask && $0.taskPath == path } }

    func evidenceAsked(task path: String) -> Bool { runs(task: path).contains(where: \.evidenceAsked) }

    /// The tracker's own check of the last run of the task; nil = it never ran.
    func trackerCheck(task path: String) -> Evidence.Check? {
        runs(task: path).max { $0.created < $1.created }.map(trackerCheck)
    }

    func trackerCheck(_ job: Job) -> Evidence.Check {
        let note = job.verifyNote
        return .of(note: note, failed: job.verifyFailed,
                   active: job.isActive || job.verifying || jobs.contains { $0.parentID == job.id && $0.isActive && $0.isFollowUp },
                   notRun: note.hasPrefix(Self.taskCheckRefused) || note == Self.taskCheckApproved,
                   mergeRed: job.members.contains { $0.mergeCheck?.state == .red })
    }
}

/// What the agent wrote under a criterion: plain grey text, never a seal.
struct AgentEvidenceLabel: View {
    let text: String
    let missing: Bool

    var body: some View {
        if !text.isEmpty {
            Label { Text("Агент: " + text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                icon: { Image(systemName: "text.quote") }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Слова агента: трекер их не проверял")
        } else if missing {
            Label("без доказательства", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Пункт отмечен, но агент не указал, чем он подтверждён")
        }
    }
}

/// What the tracker ran itself.
struct TrackerCheckLabel: View {
    let check: Evidence.Check

    var body: some View {
        Label { Text("\(Evidence.Check.title): \(check.text)").textSelection(.enabled) } icon: { Image(systemName: icon) }
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .help("Результат команды verify, которую запускал трекер")
    }

    private var icon: String {
        switch check {
        case .working: "hourglass"
        case .notRun: "seal"
        case .passed: "checkmark.seal.fill"
        case .partial: "checkmark.seal"
        case .failed: "xmark.seal.fill"
        }
    }

    private var color: Color {
        switch check {
        case .working, .notRun, .partial: .secondary
        case .passed: .green
        case .failed: .red
        }
    }
}

/// Criteria of a finished task in its queue card, collapsed.
struct CriteriaEvidence: View {
    @Environment(Store.self) private var store
    let job: Job
    @State private var shown = false

    var body: some View {
        if job.state == .done, job.kind == .runTask, let path = job.taskPath,
           let task = store.project(job.projectID)?.allTasks.first(where: { $0.id == path }) {
            let items = MD.checklist(task.body, in: .criteria).filter(\.done)
            let missing = Evidence.missing(items, asked: store.jobs.evidenceAsked(task: path))
            let proven = items.filter { !$0.evidence.isEmpty }.count
            if !items.isEmpty, proven > 0 || !missing.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label("Доказательства агента: \(proven) из \(items.count)"
                                + (missing.isEmpty ? "" : " · без доказательства: \(missing.count)"), systemImage: "text.quote")
                            .font(.caption)
                            .foregroundStyle(missing.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        Spacer()
                        Button(shown ? "Скрыть" : "Показать") { withAnimation(.snappy) { shown.toggle() } }
                            .buttonStyle(.glass).controlSize(.small)
                    }
                    if shown {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(items, id: \.n) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    MD.inline(item.text).font(.caption.weight(.medium))
                                    AgentEvidenceLabel(text: item.evidence, missing: missing.contains(item))
                                }
                            }
                            TrackerCheckLabel(check: store.jobs.trackerCheck(job))
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                    }
                }
            }
        }
    }
}
