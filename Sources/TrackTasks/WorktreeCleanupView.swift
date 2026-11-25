import SwiftUI
import TrackTasksCore

/// Queue → «Уборка worktree»: what is on disk, why it stays, removal with a preview, snapshots.
struct WorktreeCleanupView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CleanupItem]?
    @State private var saved: [RemovedWorktrees] = []
    @State private var unreadable: [String] = []
    /// Kept while the window is open: big folders take long.
    @State private var sizes: [String: Int64] = [:]
    @State private var shown: CleanupItem?
    @State private var dropping: RemovedWorktrees?
    @State private var busy = Set<String>()
    @State private var notes: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Уборка worktree").font(.title2.weight(.semibold))
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Обновить")
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !store.jobs.cleanupNote.isEmpty {
                Text(store.jobs.cleanupNote).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let items {
                        if items.isEmpty { Text("Worktree на диске нет").foregroundStyle(.secondary) }
                        ForEach(items) { row($0) }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Divider().padding(.vertical, 6)
                    Text("Снимки убранных").font(.headline)
                    Text("Коммиты, индекс и файлы лежат в git проекта (\(WorktreeSnapshot.prefix)…). Игнорируемых git файлов в них нет. Восстановленный worktree получает новую папку, сессия агента в нём не продолжается, setup запускается заново вручную.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if saved.isEmpty { Text("Снимков нет").font(.callout).foregroundStyle(.secondary) }
                    ForEach(saved) { snapshotRow($0) }
                    ForEach(unreadable, id: \.self) { n in
                        Label("\(n) не читается — файл не тронут", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .task { await load() }
        .sheet(item: $shown) { item in
            CleanupConfirm(item: item) { overriding in remove(item, overriding) }
        }
        .confirmationDialog("Удалить снимок «\(dropping?.label ?? "")»?", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
                            presenting: dropping) { r in
            Button("Удалить снимок", role: .destructive) { drop(r) }
        } message: { _ in Text("Восстановить этот worktree после этого нельзя.") }
    }

    private func row(_ i: CleanupItem) -> some View {
        let g = i.group
        let bytes = g.infos.compactMap { sizes[$0.id] }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.title.isEmpty ? "Ветка без задачи" : g.title).lineLimit(1)
                    ForEach(g.infos) { w in
                        Text("\(w.main.lastPathComponent) · \(w.branch.isEmpty ? w.path.lastPathComponent : w.branch)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(bytes.count == g.infos.count ? bytes.reduce(0, +).formatted(.byteCount(style: .file)) : "…").monospacedDigit()
                    Text(i.state.activity.map { $0.formatted(.relative(presentation: .named)) } ?? "возраст неизвестен").font(.caption).foregroundStyle(.secondary)
                }
                let pinned = !(store.jobs.pinnedWorktrees ?? []).isDisjoint(with: g.paths)
                Button {
                    store.jobs.pin(g.paths, !pinned)
                    Task { await load() }
                } label: { Image(systemName: pinned ? "pin.fill" : "pin") }
                    .help(pinned ? "Открепить" : "Закрепить: сам не уберётся")
                Button(role: .destructive) { shown = i } label: { Image(systemName: "trash") }
                    .disabled(busy.contains(i.id) || store.jobs.cleaning)
                    .help("Убрать со снимком…")
            }
            Text(notes[i.id] ?? (i.verdict.removes ? "Будет убран: " : "Остаётся: ") + i.verdict.reason)
                .font(.caption).foregroundStyle(i.verdict.removes ? .orange : .secondary).textSelection(.enabled)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    private func snapshotRow(_ r: RemovedWorktrees) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.label).lineLimit(1)
                    Text("\(r.project) · \(r.date.formatted(date: .abbreviated, time: .shortened)) · \(r.reason)" + expiry(r)).font(.caption).foregroundStyle(.secondary)
                    let lost = r.parts.reduce(0) { $0 + $1.ignoredCount }
                    if lost > 0 {
                        Text("Не сохранено игнорируемых: \(lost) — \(DirtyFiles.summary(r.parts.flatMap(\.ignored)))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Восстановить") { restore(r) }
                Button(role: .destructive) { dropping = r } label: { Image(systemName: "trash") }.help("Удалить снимок")
            }
            .disabled(busy.contains(r.id.uuidString) || r.stage != .done)
            if let n = notes[r.id.uuidString] { Text(n).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    private func expiry(_ r: RemovedWorktrees) -> String {
        let d = WorktreeSnapshots.days
        return d > 0 ? " · хранится до \(r.date.addingTimeInterval(Double(d) * 86400).formatted(date: .abbreviated, time: .omitted))" : ""
    }

    private func load() async {
        loadSnapshots()
        let list = await store.jobs.cleanupItems()
        items = list
        for w in list.flatMap(\.group.infos) where sizes[w.id] == nil {
            sizes[w.id] = await Task.detached(priority: .utility) { JobQueue.size(of: w.path) }.value
            if Task.isCancelled { return }
        }
    }

    private func loadSnapshots() {
        let s = store.jobs.snapshots
        Task {
            let l = await Task.detached(priority: .utility) { s.list() }.value
            saved = l.items
            unreadable = l.unreadable
        }
    }

    private func remove(_ i: CleanupItem, _ overriding: Set<WorktreeCleanup.Protection>) {
        busy.insert(i.id)
        notes[i.id] = "Убираю…"
        Task {
            notes[i.id] = await store.jobs.cleanUp(i.group, overriding: overriding)
            busy.remove(i.id)
            await load()
        }
    }

    private func restore(_ r: RemovedWorktrees) {
        let key = r.id.uuidString
        busy.insert(key)
        Task {
            switch await store.jobs.restoreWorktrees(r) {
            case .success(let l): notes[key] = "Восстановлен и закреплён: \(l.map(\.branch).joined(separator: ", ")) — в «Ветки без задачи»"
            case .failure(let e): notes[key] = "Не восстановлен: \(e.localizedDescription)"
            }
            busy.remove(key)
            await load()
        }
    }

    private func drop(_ r: RemovedWorktrees) {
        let s = store.jobs.snapshots
        Task {
            let e = await Task.detached { () -> String? in do { try s.delete(r); return nil } catch { return error.localizedDescription } }.value
            notes[r.id.uuidString] = e.map { "Не удалён: \($0)" }
            loadSnapshots()
        }
    }
}

/// What goes to the snapshot, what is lost, and what the person confirms.
struct CleanupConfirm: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: CleanupItem
    let confirm: (Set<WorktreeCleanup.Protection>) -> Void
    @State private var preview: [CleanupPreview]?
    @State private var agreed = false

    var body: some View {
        let hard = WorktreeCleanup.blocks(item.state, overriding: [.unmerged, .pinned])
        let soft = WorktreeCleanup.blocks(item.state).filter { $0.known && $0.protection.overridable }
        VStack(alignment: .leading, spacing: 12) {
            Text("Убрать worktree").font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let preview { ForEach(preview) { part($0) } } else { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Папка, ветка и чекпоинты удаляются. Перед удалением выполняется подтверждённый teardown.").font(.caption).foregroundStyle(.secondary)
            if !hard.isEmpty {
                Label("Убрать нельзя: \(WorktreeCleanup.text(hard))", systemImage: "lock").foregroundStyle(.orange)
            } else if !soft.isEmpty {
                Toggle("Убрать, хотя \(WorktreeCleanup.text(soft))", isOn: $agreed)
            }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Убрать со снимком", role: .destructive) {
                    confirm(Set(soft.map(\.protection)))
                    dismiss()
                }
                .disabled(!hard.isEmpty || (!soft.isEmpty && !agreed) || preview == nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .task { preview = await store.jobs.cleanupPreview(item.group) }
    }

    @ViewBuilder
    private func part(_ p: CleanupPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(p.info.main.lastPathComponent) · \(p.info.branch)").font(.callout.monospaced())
            if !p.error.isEmpty { Text(p.error).font(.caption).foregroundStyle(.red) }
            list("В снимок, кроме коммитов", p.uncommitted)
            list("Пропадёт — игнорируется git", p.ignored)
            list("Пропадёт — копии из .worktreeinclude", p.copies)
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ names: [String]) -> some View {
        if !names.isEmpty {
            Text("\(title) (\(names.count)):").font(.caption.weight(.semibold))
            Text(names.prefix(30).joined(separator: "\n") + (names.count > 30 ? "\n… ещё \(names.count - 30)" : ""))
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// Settings.
struct WorktreeCleanupSettings: View {
    @Environment(Store.self) private var store
    @AppStorage(JobQueue.cleanupMaxKey) private var count = 0
    @AppStorage(JobQueue.cleanupDaysKey) private var days = 0
    @AppStorage(WorktreeSnapshots.daysKey) private var keep = 30

    var body: some View {
        Section("Уборка worktree") {
            Picker("Не больше задач с worktree", selection: $count) {
                Text("Выключено").tag(0)
                ForEach([5, 10, 20, 50], id: \.self) { Text("\($0)").tag($0) }
            }
            .onChange(of: count) { store.jobs.scheduleCleanup() }
            Picker("Убирать старше", selection: $days) {
                Text("Выключено").tag(0)
                ForEach([7, 14, 30, 90], id: \.self) { Text("\($0) дн.").tag($0) }
            }
            .onChange(of: days) { store.jobs.scheduleCleanup() }
            Text("Сами убираются только слитые worktree, которыми никто не занят; сначала делается снимок, без него удаления нет. Игнорируемые git файлы (.build, .env) в снимок не входят и пропадают без вопроса — их имена остаются в списке снимков. Слитое через squash считается неслитым.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Хранить снимки", selection: $keep) {
                ForEach([7, 30, 90], id: \.self) { Text("\($0) дней").tag($0) }
                Text("не удалять").tag(0)
            }
            .onChange(of: keep) { store.jobs.scheduleCleanup() }
            Text("Список и восстановление — в очереди, «Уборка worktree».").font(.caption).foregroundStyle(.secondary)
        }
    }
}
