import SwiftUI
import TrackTasksCore

/// «Готово к слиянию»: review, check, diff size and files shared with other unmerged branches.
/// git runs only while the list is open: on opening and after merges.
struct MergeReadyView: View {
    @Environment(Store.self) private var store
    @State private var open = false
    @State private var facts: [UUID: Facts] = [:]
    @State private var overlaps: [UUID: [MergeReadiness.Overlap]] = [:]

    private struct Facts: Sendable {
        var stat = ""
        var check = MergeReadiness.CheckState.none
    }

    var body: some View {
        let ready = store.jobs.mergeable
        if !ready.isEmpty {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ready.flatMap(\.members).filter(\.ownAwaitsMerge)) { row($0) }
                }
                .padding(.top, 6)
            } label: {
                Label("Готово к слиянию · \(ready.count)", systemImage: "arrow.triangle.merge").font(.headline)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.purple.opacity(0.08)), in: .rect(cornerRadius: 16))
            .task(id: key) { if open { await load() } }
        }
    }

    /// Changes when the list opens or a branch, its check or the set of branches does.
    private var key: [String] {
        [open ? "open" : ""] + branches.map { "\($0.id) \($0.baseCommit) \($0.mergeCheck?.branchCommit ?? "") \($0.diffStat) \($0.home.taskCheckRefusal?.id ?? "")" }
    }

    /// All unmerged branches: one that isn't ready yet still overlaps.
    private var branches: [Job] { store.jobs.allMembers.filter { $0.ownAwaitsMerge && !$0.isFollowUp && $0.kind != .review } }

    private func row(_ job: Job) -> some View {
        let f = facts[job.id]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(job.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(job.projectName).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(review(job.home)).font(.caption).foregroundStyle(job.home.verdict == nil ? Color.secondary : .green)
                if let f {
                    Text(f.check.title).font(.caption).foregroundStyle(f.check.color)
                    Text(f.stat).font(.caption.monospaced()).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            ForEach(overlaps[job.id] ?? [], id: \.other) { o in
                Label("Те же файлы, что в «\(store.jobs.allMembers.first { $0.id == o.other }?.title ?? "другой ветке")»: \(DirtyFiles.summary(o.files))",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .help(o.files.joined(separator: "\n"))
            }
        }
    }

    private func review(_ job: Job) -> String {
        switch job.verdict {
        case nil: "без ревью"
        case .ok: "ревью: ОК"
        case .issues: "ревью: исправлено"
        }
    }

    private func load() async {
        let list = branches.compactMap { j in j.worktree.map { (j.id, $0, j.mergeCheck, store.jobs.taskGate(j)) } }
        let (f, o) = await Task.detached(priority: .utility) { () -> ([UUID: Facts], [UUID: [MergeReadiness.Overlap]]) in
            var facts: [UUID: Facts] = [:], files: [MergeReadiness.Branch] = []
            func text(_ args: [String], _ dir: URL) -> String {
                Worktrees.git(args, in: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for (id, w, check, gate) in list {
                let task = gate?.decide() ?? .none
                let ref = "refs/heads/\(w.branch)"
                let names = Worktrees.git(["diff", "--name-only", "-z", "HEAD...\(ref)"], in: w.main).out
                files.append(.init(id: id, project: TaskRepos.canonical(w.main), files: Set(names.split(separator: "\0").map(String.init))))
                facts[id] = Facts(stat: text(["diff", "--shortstat", "HEAD...\(ref)"], w.main),
                                  check: task.refusal != nil ? .blocked : MergeReadiness.state(check, tip: text(["rev-parse", ref], w.main), main: text(["rev-parse", "HEAD"], w.main),
                                                              mainBranch: text(["symbolic-ref", "--short", "-q", "HEAD"], w.main),
                                                              command: MergeRunner.command(w), taskCommand: task.command))
            }
            return (facts, MergeReadiness.overlaps(files))
        }.value
        guard !Task.isCancelled else { return }
        facts = f
        overlaps = o
    }
}

private extension MergeReadiness.CheckState {
    var title: String {
        switch self {
        case .none: "с main не проверена"
        case .fresh: "проверена"
        case .stale: "проверка устарела"
        case .red: "проверка красная"
        case .timedOut: "таймаут проверки"
        case .unverified: "не проверяется"
        case .blocked: "проверка задачи не подтверждена"
        }
    }
    var color: Color {
        switch self {
        case .fresh: .green
        case .red: .red
        case .timedOut, .blocked: .orange
        default: .secondary
        }
    }
}
