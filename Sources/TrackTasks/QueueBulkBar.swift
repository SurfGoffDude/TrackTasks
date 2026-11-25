import SwiftUI

/// Actions over the whole queue: review / fix / merge / resolve / allow / retry / cancel.
/// Each button shows how many jobs it touches and hides when there's nothing to do.
struct QueueBulkBar: View {
    @Environment(Store.self) private var store
    @State private var confirmAllow = false
    @State private var confirmCancel = false
    @State private var confirmMerge = false
    @State private var confirmRestart = false

    var body: some View {
        let q = store.jobs
        let review = q.reviewable.count, fix = q.fixable.count, merge = q.mergeable.count
        let resolve = q.resolvable.count, main = q.mainConflicts, allow = q.waitingApproval
        let retry = q.retryable.count, pending = q.pendingJobs.count
        let merging = q.mergeBatch != nil
        let blocked = q.notMergeable
        let restart = q.restartable(includingDone: false).count, restartAll = q.restartable(includingDone: true).count
        let counts: [Int] = [restartAll, review, fix, merge, resolve, main.count, allow, retry, pending, blocked.count]
        if counts.contains(where: { $0 > 0 }) || merging || q.lastMergeBatch != nil {
            if !blocked.isEmpty { NotMergeableList(items: blocked) }
            FlowLayout(spacing: 8) {
                if allow > 0 {
                    button("Разрешить все", allow, "checkmark.shield", .green) { confirmAllow = true }
                        .help("Разрешить все команды, которые Claude сейчас спрашивает (один раз, не «всегда»)")
                }
                if review > 0 {
                    button("Ревью все", review, "text.magnifyingglass", .blue) { q.reviewAll() }
                        .help("Код-ревью всех выполненных задач без ревью")
                }
                if fix > 0 {
                    button("Исправить все", fix, "wrench.and.screwdriver", .orange) { q.fixAll() }
                        .help("Исправить замечания ревью во всех задачах с вердиктом «ПРАВКИ»")
                }
                if merge == 0, !merging, !blocked.isEmpty {
                    button("Слить все · 0 из \(blocked.count)", 0, "arrow.triangle.merge", .gray) {}
                        .disabled(true)
                }
                if merge > 0 || merging {
                    button(q.mergeBatch.map { "Сливаю \(min($0.done + 1, $0.total)) из \($0.total)" } ?? "Слить все", merging ? 0 : merge, "arrow.triangle.merge", .purple, prominent: true) { confirmMerge = true }
                        .disabled(merging)
                        .help("Слить готовые ветки по очереди, начиная со старых: каждая проверяется вместе с основной веткой. Ветки с непоправленным ревью, красной проверкой и конфликтом пропускаются")
                }
                if merging {
                    button("Остановить", 0, "stop.fill", .gray) { q.stopMergeAll() }
                        .help("Прервать проверку и не начинать следующие ветки")
                }
                if let last = q.lastMergeBatch, !merging {
                    button("Слито \(last.merged) из \(last.total)", 0, "xmark", .gray) { q.lastMergeBatch = nil }
                        .help(last.summary)
                }
                if resolve > 0 {
                    button("Разрешить конфликты", resolve, "arrow.triangle.branch", .red) { q.resolveAll() }
                        .help("Агент вливает основную ветку в каждую конфликтную ветку (в её worktree) и разрешает конфликт. Потом — «Слить все»")
                }
                ForEach(q.canResolveMain ? main : []) { j in
                    button("Конфликты в основной папке: \(j.projectName)", 0, "exclamationmark.triangle", .red) { q.resolveMain(j) }
                        .help("В основной папке проекта висят неразрешённые конфликты — git не даёт сливать. Агент разрешит их")
                }
                if retry > 0 {
                    button("Повторить упавшие", retry, "arrow.clockwise", .gray) { q.retryAll() }
                }
                if restartAll > 0 {
                    button("Перезапустить все", restartAll, "arrow.clockwise.circle", .gray) { confirmRestart = true }
                        .help("Снова поставить в очередь все её задачи. Идущие, ожидающие и с неслитой веткой не трогаются")
                }
                if pending > 0 {
                    button("Отменить ожидающие", pending, "xmark.circle", .gray) { confirmCancel = true }
                }
            }
            .confirmationDialog("Разрешить \(allow) запрос(ов) Claude?", isPresented: $confirmAllow) {
                Button("Разрешить все") { q.allowAll() }
            } message: {
                Text(allowList)
            }
            .confirmationDialog("Отменить \(pending) ожидающих задач?", isPresented: $confirmCancel) {
                Button("Отменить", role: .destructive) { q.cancelPending() }
            }
            .confirmationDialog("Перезапустить задачи очереди?", isPresented: $confirmRestart) {
                if restart > 0 { Button("Только незавершённые · \(restart)") { q.restart(includingDone: false) } }
                if restartAll > restart {
                    Button("Все, и выполненные · \(restartAll)", role: .destructive) { q.restart(includingDone: true) }
                }
            } message: {
                Text(q.restartable(includingDone: true).map { "• \($0.projectName): \($0.title)" }.prefix(12).joined(separator: "\n")
                     + "\n\nНезавершённые — упавшие и отменённые. Выполненные пойдут заново с нуля и снова потратят лимит. Задачи с неслитой веткой, открытым PR и уже стоящие в очереди пропускаются.")
            }
            .confirmationDialog("Слить \(merge) веток в основные ветки проектов?", isPresented: $confirmMerge) {
                Button("Слить все") { Task { await q.mergeAll() } }
            } message: {
                Text(mergeText)
            }
        }
    }

    private var mergeText: String {
        let list = store.jobs.mergeable.map { "• \($0.projectName): \($0.title)" }.prefix(12).joined(separator: "\n")
        return list + "\n\nПо очереди, каждая — с проверкой вместе с основной веткой. Ветки, которые меняют файлы с незакоммиченными правками в основной папке, пропускаются: сначала закоммить их. Ветки с конфликтом останутся — для них «Разрешить конфликты»."
    }

    private var allowList: String {
        let items = store.jobs.jobs.flatMap { j in j.permissions.map { "• \(j.projectName): \($0.title)" } }
        return items.prefix(12).joined(separator: "\n") + (items.count > 12 ? "\n… ещё \(items.count - 12)" : "")
            + "\n\nПроверь список: это команды, которые Claude выполнит в твоих проектах."
    }

    private func button(_ title: String, _ n: Int, _ icon: String, _ color: Color, prominent: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(n > 0 ? "\(title) · \(n)" : title, systemImage: icon)
                .monospacedDigit()
                .foregroundStyle(prominent ? .white : color)
        }
        .buttonStyle(prominent ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
        .tint(prominent ? color : nil)
        .fixedSize()
    }
}

/// Why «Слить все» doesn't take a branch.
struct NotMergeableList: View {
    let items: [(job: Job, why: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items.prefix(6), id: \.job.id) { b in
                Text("Не готова к слиянию: \(b.job.projectName) · \(b.job.title) — \(b.why)").lineLimit(1)
            }
            if items.count > 6 { Text("… ещё \(items.count - 6)") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Type-erased button style so one helper can pick glass or glassProminent.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
