import SwiftUI
import TrackTasksCore

extension JobQueue {
    struct Waiting {
        let job: Job
        let guide: JobGuide
        let need: JobGuide.Need
    }

    /// The card of a job: a follow-up is shown in its task's.
    func cardJob(_ job: Job) -> Job { self.job(job.parentID) ?? job }

    /// Cards that wait for the person, most urgent first.
    var waitingForYou: [Waiting] {
        let all = jobs.compactMap { j -> Waiting? in
            guard cardJob(j) === j else { return nil }
            let g = brief(j)
            return g.need.map { Waiting(job: j, guide: g, need: $0) }
        }
        return JobGuide.Need.allCases.flatMap { n in all.filter { $0.need == n } }
    }

    /// How a job looks in a list: without the planner and the buttons.
    func brief(_ job: Job) -> JobGuide { JobGuide.of(facts(job, brief: true)) }
}

extension Store {
    /// Opens the queue at the job's card; only the queue when it isn't there.
    func showJob(_ job: Job) {
        mode = .work
        focusJob = jobs.job(job.id).map { jobs.cardJob($0).id }
        selectedID = Store.queueID
    }
}

/// «Ждёт тебя» over the queue: what is wanted and from where; a click leads to the card.
struct WaitingForYouView: View {
    @Environment(Store.self) private var store
    @AppStorage("waitingForYouOpen") private var open = true

    var body: some View {
        let items = store.jobs.waitingForYou
        if !items.isEmpty {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(JobGuide.Need.allCases) { n in
                        let group = items.filter { $0.need == n }
                        if !group.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(n.title) · \(group.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(group, id: \.job.id) { row($0) }
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("Ждёт тебя · \(items.count)", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.orange.opacity(0.10)), in: .rect(cornerRadius: 16))
        }
    }

    private func row(_ w: JobQueue.Waiting) -> some View {
        Button { store.showJob(w.job) } label: {
            HStack(spacing: 8) {
                Text(w.job.title).lineLimit(1)
                Text("\(w.job.projectName) · \(w.guide.status)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Показать карточку задачи")
    }
}

/// Number of cards that wait for the person.
struct WaitingBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Label("\(count)", systemImage: "hand.raised.fill")
                .labelStyle(CompactLabel())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.orange)
                .help("Ждёт тебя: \(count)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Ждёт тебя: \(count)")
        }
    }
}
