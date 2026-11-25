import SwiftUI
import TrackTasksCore

/// Pipeline of a task in the queue: where it is, what it cost and the person's decisions.
struct JobRowPipeline: View {
    @Environment(Store.self) private var store
    let job: Job
    var prominent = true
    @State private var confirmFinish = false

    var body: some View {
        if let s = job.pipeline {
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 6) {
                    Label(s.workflow.title.isEmpty ? s.name : s.workflow.title, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption.weight(.medium))
                    ForEach(s.workflow.steps.indices, id: \.self) { i in
                        let here = i == s.current && s.status != .ready && s.isOpen
                        Text(s.workflow.steps[i].title + (s.visits[i] > 1 ? " ×\(s.visits[i])" : "")
                             + (s.workflow.steps[i].repeats.map { " (до \($0))" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(here ? Color.accentColor : s.visits[i] > 0 ? .primary : .secondary)
                            .fontWeight(here ? .semibold : .regular)
                    }
                    if let c = s.costText {
                        Text(c).font(.caption.monospacedDigit()).foregroundStyle(s.overBudget ? .red : .secondary)
                            .help("Все запуски задачи. Бюджет сверяется перед каждым шагом: один идущий шаг может его превысить")
                    }
                }
                if let g = s.gate, !job.awaitingPlan, job.state == .done || job.state == .pending {
                    let why = store.jobs.pipelineBlocked(job)
                    Label(g.reason, systemImage: "hand.raised.fill").font(.callout).foregroundStyle(.orange)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        if let n = g.next {
                            Button("Продолжить") { store.jobs.pipelineContinue(job) }
                                .buttonStyle(prominent ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
                                .help(nextTitle(n, s))
                        }
                        if g.kind == .trouble || (g.kind == .after && s.step?.type != .plan) {
                            Button("Повторить шаг") { store.jobs.pipelineRepeat(job) }.buttonStyle(.glass)
                        }
                        if job.state == .done {
                            Button("Завершить пайплайн") { confirmFinish = true }
                                .buttonStyle(.glass)
                                .help("Оставшиеся шаги не выполняются; ветку можно будет слить")
                                .confirmationDialog("Завершить пайплайн без оставшихся шагов?", isPresented: $confirmFinish) {
                                    Button("Завершить") { store.jobs.pipelineFinish(job) }
                                } message: { Text("Ветку после этого можно слить. Само слияние — отдельной кнопкой.") }
                        }
                    }
                    .controlSize(.small)
                    .disabled(why != nil)
                    .help(why ?? "")
                    if let why { Text("Недоступно: \(why)").font(.caption).foregroundStyle(.secondary) }
                } else if !s.isOpen, job.awaitsMerge {
                    Text("Пайплайн завершён — слить можешь только ты").font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    private func nextTitle(_ t: Workflow.Target, _ s: PipelineState) -> String {
        switch t {
        case .end: "Завершить пайплайн"
        case .step(let i): s.workflow.steps.indices.contains(i) ? "Дальше: «\(s.workflow.steps[i].title)»" : ""
        }
    }
}
