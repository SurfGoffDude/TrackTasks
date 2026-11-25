import SwiftUI
import TrackTasksCore

/// One board across all projects: what's in progress, what's important, what waits for you.
struct TodayView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let doing = store.doingTasks
        let high = store.highTasks
        let needsYou = store.jobs.waitingForYou
        let running = store.jobs.jobs.filter { $0.isActive && $0.parentID == nil && !$0.awaitingPlan && store.jobs.pipelineHold($0) == nil }

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Сегодня")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "ru_RU"))))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { store.morningDigest() } label: { Label("Сводка дня", systemImage: "sun.max") }
                        .buttonStyle(.glass)
                        .fixedSize()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                    column("Ждёт тебя", icon: "hand.raised.fill", color: .orange, empty: needsYou.isEmpty ? "Ничего не ждёт решения" : nil) {
                        ForEach(JobGuide.Need.allCases) { n in
                            let group = needsYou.filter { $0.need == n }
                            if !group.isEmpty {
                                Text("\(n.title) · \(group.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            ForEach(group, id: \.job.id) { w in
                                jobRow(w.job, w.guide)
                                JobQuestionsCard(job: w.job)
                                PlanApprovalCard(job: w.job, showPlan: false, prominent: w.guide.card == .plan)
                            }
                        }
                    }
                    column("В работе", icon: "circle.lefthalf.filled", color: .blue, empty: doing.isEmpty ? "Нет задач в работе" : nil) {
                        ForEach(doing, id: \.task.id) { item in
                            taskRow(item.project, item.task)
                        }
                    }
                    column("Важное", icon: "flag.fill", color: .red, empty: high.isEmpty ? "Нет задач с высоким приоритетом" : nil) {
                        ForEach(high.prefix(20), id: \.task.id) { item in
                            taskRow(item.project, item.task)
                        }
                    }
                    column("Claude работает", icon: "sparkles", color: .purple, empty: running.isEmpty ? "Очередь пуста" : nil) {
                        ForEach(running) { j in
                            jobRow(j, store.jobs.brief(j))
                        }
                    }
                }
            }
            .padding(28)
        }
        .background(Backdrop(tint: .blue))
        .navigationTitle("Сегодня")
    }

    private func column<C: View>(_ title: String, icon: String, color: Color, empty: String?,
                                 @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(color)
            if let empty {
                Text(empty).font(.callout).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .glassEffect(.regular.tint(color.opacity(0.06)), in: .rect(cornerRadius: 18))
    }

    private func taskRow(_ p: Project, _ t: TaskItem) -> some View {
        Button { store.reveal(t, in: p) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(t.priority.color).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).lineLimit(2)
                    Text(p.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let j = store.jobs.job(forTask: t.id) {
                    Image(systemName: j.state == .running ? "bolt.fill" : "clock")
                        .font(.caption).foregroundStyle(.blue)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.04), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func jobRow(_ j: Job, _ g: JobGuide) -> some View {
        Button { store.showJob(j) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(j.title).lineLimit(2)
                Text("\(j.projectName) · \(g.status)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if g.need == .pipeline, !g.reason.isEmpty {
                    Text(g.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.04), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Показать карточку в очереди")
    }
}
