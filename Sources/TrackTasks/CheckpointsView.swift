import SwiftUI
import TrackTasksCore

/// Checkpoints of a worktree job: compare and roll back.
struct CheckpointsList: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    let job: Job
    @State private var items: [Checkpoints.Checkpoint]?
    @State private var error: String?
    @State private var asking: Checkpoints.Checkpoint?
    @State private var reloads = 0

    var body: some View {
        let blocked = store.jobs.rollbackBlocked(job)
        VStack(alignment: .leading, spacing: 10) {
            Text("Чекпоинты").font(.headline)
            Text("Состояние перед каждым ходом. Откат меняет только файлы worktree: ветка остаётся на месте, игнорируемые git файлы не трогаются.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let blocked { Text("Откат недоступен: \(blocked)").font(.caption).foregroundStyle(.orange) }
            if let items {
                if items.isEmpty { Text("Чекпоинтов нет").font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(items.reversed()) { c in row(c, next: items.first { $0.number > c.number }, blocked: blocked) }
                    }
                }
                .frame(maxHeight: 380)
            } else if error == nil {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 460, alignment: .leading)
        .task(id: reloads) { await load() }
        .alert("Откатить к чекпоинту №\(asking?.number ?? 0)?",
               isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), presenting: asking) { c in
            Button("Отмена", role: .cancel) {}
            Button("Только код", role: .destructive) { rollback(c, talk: false) }
            if store.jobs.canRewind(job, c) {
                Button("Код и разговор", role: .destructive) { rollback(c, talk: true) }
            }
        } message: { c in
            Text("«\(c.meta.label)»\n\nФайлы worktree вернутся к этому состоянию, новые файлы удалятся. Текущее состояние сохранится чекпоинтом — к нему можно вернуться.\n\n"
                 + (store.jobs.canRewind(job, c)
                    ? "«Код и разговор» — следующее сообщение агенту начнёт новую сессию с этой точки; прежняя сессия не меняется."
                    : "Разговор к этой точке вернуть нельзя: её нет в файле сессии."))
        }
    }

    private func row(_ c: Checkpoints.Checkpoint, next: Checkpoints.Checkpoint?, blocked: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: c.meta.kind == .turn ? "circle.fill" : "arrow.uturn.backward")
                .font(.caption2).foregroundStyle(c.meta.kind == .turn ? .blue : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("№\(c.number) · \(c.meta.label)").font(.callout).lineLimit(2)
                Text(c.meta.date.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Menu {
                Button(next.map { "До чекпоинта №\($0.number)" } ?? "До текущего состояния") { diff(c, to: next) }
                if next != nil { Button("До текущего состояния") { diff(c, to: nil) } }
            } label: { Label("Изменения", systemImage: "plusminus") }
                .menuStyle(.button).buttonStyle(.glass).controlSize(.small).fixedSize()
                .help("Изменения после этого чекпоинта")
            Button("Откатить") { asking = c }
                .buttonStyle(.glass).controlSize(.small)
                .disabled(blocked != nil)
        }
    }

    private func load() async {
        guard let w = job.worktree else { items = []; return }
        switch await store.jobs.checkpoints(w) {
        case .success(let l): items = l
        case .failure(let e): error = e.message
        }
    }

    private func diff(_ c: Checkpoints.Checkpoint, to next: Checkpoints.Checkpoint?) {
        guard let w = job.worktree else { return }
        let title = "№\(c.number) → " + (next.map { "№\($0.number)" } ?? "сейчас")
        openWindow(id: DiffView.windowID, value: DiffSource(
            title: "\(job.projectName) · \(job.title) · \(title)", folder: w.path, jobID: job.id,
            span: .init(from: c.oid, to: next?.oid, title: title), spanBranch: w.branch))
    }

    private func rollback(_ c: Checkpoints.Checkpoint, talk: Bool) {
        Task {
            error = await store.jobs.rollback(job, to: c, talk: talk)
            reloads += 1
        }
    }
}

/// What a rollback left to decide: commit it, or keep the old conversation.
struct RollbackBanner: View {
    @Environment(Store.self) private var store
    let job: Job
    var prominent = false
    @State private var error: String?

    var body: some View {
        if job.worktree != nil, !job.isActive {
            let rolled = job.members.first { !$0.rolledBack.isEmpty && $0.committed }
            if let rolled {
                HStack(spacing: 8) {
                    Label("Откат к \(rolled.rolledBack) не закоммичен", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                    Button("Закоммитить откат") { Task { error = await store.jobs.commitRollback(job) } }
                        .buttonStyle(prominent ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass)).controlSize(.small)
                        .disabled(store.jobs.rollbackBlocked(job) != nil)
                        .help("Отдельный коммит в ветку задачи — без него слияние недоступно")
                }
                if let why = store.jobs.rollbackBlocked(job) {
                    Text("Закоммитить пока нельзя: \(why)").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            if let r = job.rewind {
                HStack(spacing: 8) {
                    Label(r.session == nil ? "Следующее сообщение начнёт задачу заново в новой сессии"
                          : "Следующее сообщение продолжит разговор с точки отката в новой сессии", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Оставить прежний разговор") { store.jobs.cancelRewind(job) }
                        .buttonStyle(.glass).controlSize(.small)
                }
            }
        }
    }
}
