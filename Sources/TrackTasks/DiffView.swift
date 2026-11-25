import SwiftUI
import TrackTasksCore

/// Review window: changed files on the left, diff of the selected one on the right.
struct DiffView: View {
    static let windowID = "diff"

    @Environment(Store.self) private var store
    let source: DiffSource

    @AppStorage("diffSplit") private var split = false
    @State private var sections: [DiffSection]?
    @State private var loading = false
    @State private var reloads = 0
    @State private var selection: String?
    @State private var filter = ""
    @State private var hideViewed = false
    @State private var viewed: [String: String] = [:]
    @State private var table = DiffTable()
    @State private var tableVersion = 0
    @State private var picked = IndexSet()
    @State private var tableFile = ""
    @State private var tableFingerprint: String?
    @State private var lastReject: DiffReject.Undo?
    @State private var rejecting = false
    @State private var rejectError: String?
    @State private var editing: DiffComment?
    @State private var sendNote = ""
    /// Где комментарии стоят в текущем diff.
    @State private var places: [UUID: DiffComments.Place] = [:]
    @State private var goTo: DiffGoTo?
    @State private var confirmRepeat = false

    private struct TableKey: Equatable {
        let id: String?
        let fingerprint: String?
        let split: Bool
    }

    var body: some View {
        NavigationSplitView {
            fileList
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 520)
        } detail: {
            detail
        }
        .navigationTitle(source.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .sheet(item: $editing) { c in
            DiffCommentEditor(comment: c, isNew: !comments.contains { $0.id == c.id },
                              lines: places[c.id]?.comment.lines) { upsert($0, original: c) }
        }
        .alert("Не получилось", isPresented: Binding(get: { rejectError != nil }, set: { if !$0 { rejectError = nil } })) {
            Button("OK") {}
        } message: {
            Text(rejectError ?? "")
        }
        .confirmationDialog("Часть комментариев агент мог уже получить", isPresented: $confirmRepeat) {
            Button("Отправить все") { send(comments) }
            if comments.contains(where: { !$0.isBlank && $0.delivery?.state != .unclear }) {
                Button("Только остальные") { send(comments.filter { $0.delivery?.state != .unclear }) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Отмеченные «Возможно, уже отправлен» уйдут ещё раз.")
        }
        .onChange(of: selection) { if goTo?.fileID != selection { goTo = nil } }
        .onChange(of: comments, initial: true) { updatePlaces() }
        .task(id: reloads) { await load() }
        .task(id: TableKey(id: selection, fingerprint: selected?.fingerprint, split: split)) { await buildTable() }
    }

    // MARK: Data

    private var entries: [DiffSection.Entry] { (sections ?? []).flatMap(\.entries) }
    private var selected: DiffSection.Entry? { entries.first { $0.id == selection } }

    private func isViewed(_ e: DiffSection.Entry) -> Bool { viewed[e.id] == e.fingerprint }

    private func visible(_ s: DiffSection) -> [DiffSection.Entry] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return s.entries.filter { e in
            (q.isEmpty || e.file.path.localizedCaseInsensitiveContains(q)
                || (e.file.oldPath?.localizedCaseInsensitiveContains(q) ?? false))
                && (!hideViewed || !isViewed(e) || e.id == selection)
        }
    }

    private var subtitle: String {
        guard sections != nil else { return "" }
        let all = entries
        let add = all.reduce(0) { $0 + $1.file.additions }, del = all.reduce(0) { $0 + $1.file.deletions }
        return "Файлов: \(all.count) · +\(add) −\(del) · просмотрено \(all.count(where: isViewed))"
    }

    private func load() async {
        loading = true
        let r = await DiffLoader.load(source)
        let undo = await DiffLoader.lastReject(source)
        // A newer reload is already running and will set the result.
        guard !Task.isCancelled else { return }
        loading = false
        viewed = DiffViewed.load(source)
        store.jobs.openDrafts(source.key)
        sections = r
        updatePlaces()
        lastReject = undo
        let all = entries
        if !all.contains(where: { $0.id == selection }) {
            selection = (all.first { !isViewed($0) } ?? all.first)?.id
        }
    }

    private func buildTable() async {
        let file = selected?.file, fingerprint = selected?.fingerprint, id = selection ?? "", split = split
        let t = await Task.detached(priority: .userInitiated) {
            file.map { split ? DiffRows.split($0) : DiffRows.unified($0) } ?? DiffTable()
        }.value
        guard !Task.isCancelled else { return }
        table = t
        tableFile = id
        tableFingerprint = fingerprint
        tableVersion += 1
        picked = []
    }

    // MARK: Reject

    /// nil — можно.
    private var rejectBlocked: String? {
        if rejecting || loading { return "Подожди: обновляется diff" }
        return store.jobs.rejectBlocked(source)
    }

    private func reject(_ e: DiffSection.Entry, hunk: Int? = nil) {
        guard rejectBlocked == nil, let kind = sections?.first(where: { $0.entries.contains { $0.id == e.id } })?.kind else { return }
        // The menu could be opened over rows of the previous diff.
        if hunk != nil, tableFile != e.id || tableFingerprint != e.fingerprint { return }
        let source = source
        change(note: "Отклонено: \(e.file.path)" + (hunk.map { ", кусок \($0 + 1)" } ?? "")) {
            try DiffReject.reject(source, kind, e, hunk: hunk, git: DiffLoader.runRaw)
        }
    }

    private func undoReject() {
        guard rejectBlocked == nil, let last = lastReject else { return }
        let source = source
        change(note: "Отклонение отменено: \(last.label)") {
            try DiffReject.undoLast(source, git: DiffLoader.runRaw)
        }
    }

    private func change(note: String, _ body: @escaping @Sendable () throws -> Void) {
        rejecting = true
        Task {
            rejectError = await store.jobs.changeWorktree(source, note: note, body)
            rejecting = false
            reloads += 1
        }
    }

    // MARK: Comments

    private var comments: [DiffComment] { store.jobs.drafts.comments(source.key) }

    private func updatePlaces() { places = DiffComments.places(comments, in: sections ?? []) }

    /// A comment is outdated when its lines have no certain place in the diff.
    private var outdatedIDs: Set<UUID> { Set(comments.map(\.id)).subtracting(places.keys) }

    /// With the line numbers of the current diff.
    private var placed: [DiffComment] { comments.map { places[$0.id]?.comment ?? $0 } }

    private func marks(_ e: DiffSection.Entry) -> [String: Bool] {
        let here = placed.filter { c in c.path == e.file.path && places[c.id]?.entries.contains(e.id) != false }
        return DiffComments.marks(here, outdated: outdatedIDs)
    }

    /// Changes whenever drafts or the diff they are checked against change, so row markers redraw.
    private var marksVersion: Int {
        var h = Hasher()
        for c in placed { h.combine(c.id); h.combine(c.start); h.combine(c.end) }
        h.combine(outdatedIDs)
        h.combine(tableVersion)
        return h.finalize()
    }

    private var targetJob: Job? { source.jobID.flatMap { store.jobs.job($0) } }

    private var sendBlocked: String? {
        guard let job = targetJob else { return "Diff открыт не из задачи очереди — комментарии можно только скопировать" }
        return store.jobs.replyBlocked(job)
    }

    private var commentsPanel: some View {
        DiffCommentsPanel(
            comments: placed, outdated: outdatedIDs, blocked: sendBlocked, sendNote: sendNote,
            open: { c in
                if let id = places[c.id]?.entries.first {
                    selection = id
                    goTo = DiffGoTo(fileID: id, side: c.side, line: c.start)
                } else if let e = entries.first(where: { $0.file.path == c.path }) { selection = e.id }
            },
            // The draft itself: with moved lines it would be a different version.
            edit: { c in editing = comments.first { $0.id == c.id } },
            remove: { c in
                store.jobs.drafts.change(source.key) { $0.removeAll { $0.id == c.id } }
            },
            send: sendComments,
            copy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(DiffComments.format(placed, outdated: outdatedIDs), forType: .string)
                sendNote = "Скопировано"
            })
    }

    private func startComment(_ rows: IndexSet, in e: DiffSection.Entry) {
        let picked = rows.compactMap { table.rows.indices.contains($0) ? table.rows[$0] : nil }
        guard let a = DiffComments.anchor(picked),
              let c = DiffComment.make(file: e.file, side: a.side, start: a.start, end: a.end, text: "",
                                         section: sections?.first { $0.entries.contains { $0.id == e.id } }?.kind) else { return }
        editing = c
    }

    private func upsert(_ c: DiffComment, original: DiffComment) {
        var c = c
        c.text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
        sendNote = ""
        store.jobs.drafts.change(source.key) { DiffComments.upsert(c, original: original, in: &$0) }
    }

    private func sendComments() {
        if comments.contains(where: { $0.delivery?.state == .unclear }) { confirmRepeat = true } else { send(comments) }
    }

    private func send(_ all: [DiffComment]) {
        let list = all.filter { !$0.isBlank }
        guard let job = targetJob, sendBlocked == nil else { return }
        // The session runs in the project's worktree: name the other repository the paths belong to.
        let part = job.parts.first { $0.worktree?.path.standardizedFileURL.path == source.folder.standardizedFileURL.path }
        let text = (part.map { "Репозиторий «\($0.repoName)» (\(source.folder.path)).\n\n" } ?? "") + DiffComments.format(list.map { places[$0.id]?.comment ?? $0 }, outdated: outdatedIDs)
        guard !list.isEmpty, store.jobs.sendReply(job, text: text, comments: .init(key: source.key, list: list)) else {
            sendNote = "Не удалось отправить"
            return
        }
        // The rest is shown by the drafts themselves.
        sendNote = ""
    }

    private func setViewed(_ e: DiffSection.Entry, _ on: Bool) {
        viewed[e.id] = on ? e.fingerprint : nil
        // Forget files that are no longer in the diff.
        let ids = Set(entries.map(\.id))
        viewed = viewed.filter { ids.contains($0.key) }
        DiffViewed.save(viewed, for: source)
    }

    // MARK: Files

    private var fileList: some View {
        List(selection: $selection) {
            ForEach(sections ?? [], id: \.kind) { s in
                Section(source.span?.title ?? (source.branch == nil ? "Изменения" : s.kind == .branch ? "Ветка" : "Незакоммиченное")) {
                    if let e = s.error {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    } else if s.entries.isEmpty {
                        Text("Нет изменений").font(.caption).foregroundStyle(.secondary)
                    }
                    if s.truncated {
                        Label("Показано не всё" + (s.skippedFiles > 0 ? ": ещё файлов \(s.skippedFiles)" : " — diff слишком большой"),
                              systemImage: "scissors")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(visible(s)) { e in
                        DiffFileRow(entry: e, viewed: isViewed(e)) { setViewed(e, $0) }
                            .tag(e.id)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Фильтр файлов", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Toggle("Скрыть просмотренные", isOn: $hideViewed)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: Diff

    @ViewBuilder
    private var detail: some View {
        if let e = selected {
            VStack(spacing: 0) {
                header(e)
                if placeholder(e) == nil { lineActions(e) }
                Divider()
                if let note = placeholder(e) {
                    ContentUnavailableView(note, systemImage: e.file.isBinary ? "doc.zipper" : "doc")
                        .frame(maxHeight: .infinity)
                } else {
                    DiffTableView(table: table, version: tableVersion, fileID: tableFile,
                                  marks: marks(e),
                                  marksVersion: marksVersion, goTo: goTo, onComment: { startComment($0, in: e) },
                                  onSelect: { picked = $0 },
                                  onReject: rejectBlocked == nil ? { reject(e, hunk: $0) } : nil)
                }
                if !comments.isEmpty { commentsPanel }
            }
        } else if sections == nil {
            ProgressView("git diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = sections?.compactMap(\.error).first {
            ContentUnavailableView("Не удалось получить diff", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ContentUnavailableView("Нет изменений", systemImage: "checkmark.circle")
        }
    }

    private func header(_ e: DiffSection.Entry) -> some View {
        let f = e.file
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(f.path).font(.callout.monospaced().weight(.medium)).textSelection(.enabled)
                if let old = f.oldPath, f.status == .renamed || f.status == .copied {
                    Text((f.status == .renamed ? "переименован из " : "скопирован из ") + old)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if f.modeChanged {
                    Text("права: \(f.oldMode ?? "") → \(f.newMode ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                if f.truncated, !f.hunks.isEmpty {
                    Text("Файл показан не полностью — остальное в терминале").font(.caption).foregroundStyle(.orange)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 8)
            DiffCounts(file: f)
            Toggle("Просмотрено", isOn: Binding(get: { isViewed(e) }, set: { setViewed(e, $0) }))
                .toggleStyle(.checkbox)
            if source.branch != nil {
                Button("Отклонить файл", role: .destructive) { reject(e) }
                    .disabled(rejectBlocked != nil)
                    .help(rejectBlocked ?? "Вернуть файл к исходному в worktree. Один кусок — выбери его строку и нажми «Отклонить кусок»")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// The context menu of the lines, for the selected ones.
    private func lineActions(_ e: DiffSection.Entry) -> some View {
        let hunk = table.hunk(of: picked)
        return HStack(spacing: 8) {
            Button { startComment(picked, in: e) } label: { Label("Комментировать строки…", systemImage: "text.bubble") }
                .disabled(picked.isEmpty)
            if source.branch != nil {
                Button(role: .destructive) { if let hunk { reject(e, hunk: hunk) } } label: { Label("Отклонить кусок", systemImage: "arrow.uturn.backward") }
                    .disabled(hunk == nil || rejectBlocked != nil)
            }
            Text(picked.isEmpty ? "Выбери строки мышью" : source.branch == nil ? "" : rejectBlocked ?? (hunk == nil ? "Отклонить можно один кусок за раз" : ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// Instead of lines, when there are none to show.
    private func placeholder(_ e: DiffSection.Entry) -> String? {
        let f = e.file
        if f.isBinary { return "Двоичный файл" }
        guard f.hunks.isEmpty else { return nil }
        if f.truncated { return f.path.hasSuffix("/") ? "Вложенный репозиторий" : "Файл слишком большой для показа" }
        if f.status == .renamed { return "Переименован без изменений" }
        if f.status == .added || f.status == .deleted { return "Пустой файл" }
        return f.modeChanged ? "Изменились только права" : "Нет строк для показа"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Picker("Вид", selection: $split) {
                Label("Единый", systemImage: "rectangle").tag(false)
                Label("Раздельный", systemImage: "rectangle.split.2x1").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Единый или раздельный вид")
        }
        ToolbarItemGroup {
            if source.branch != nil {
                Button { undoReject() } label: { Label("Отменить отклонение", systemImage: "arrow.uturn.backward") }
                    .disabled(lastReject == nil || rejectBlocked != nil)
                    .help(lastReject.map { rejectBlocked ?? "Отменить отклонение: \($0.label)" } ?? "Отклонений нет")
            }
            Button { reloads += 1 } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                .disabled(loading)
                .help("Перечитать diff")
            Button { store.openTerminal(at: source.folder, command: source.terminalCommand) } label: {
                Label("Терминал", systemImage: "terminal")
            }
            .help("Тот же diff в терминале")
        }
    }
}

private struct DiffFileRow: View {
    let entry: DiffSection.Entry
    let viewed: Bool
    let setViewed: (Bool) -> Void

    var body: some View {
        let f = entry.file
        let path = f.path as NSString
        HStack(spacing: 8) {
            Toggle("Просмотрено", isOn: Binding(get: { viewed }, set: setViewed))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Просмотрено")
            Text(letter).font(.caption.monospaced().bold()).foregroundStyle(color).help(status)
            VStack(alignment: .leading, spacing: 1) {
                Text(path.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if !path.deletingLastPathComponent.isEmpty {
                    Text(path.deletingLastPathComponent)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            DiffCounts(file: f)
        }
        .opacity(viewed ? 0.55 : 1)
        .help(f.path)
    }

    private var letter: String {
        if entry.untracked { return "?" }
        return switch entry.file.status {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        }
    }

    private var status: String {
        if entry.untracked { return "Новый, ещё не в git" }
        return switch entry.file.status {
        case .modified: "Изменён"
        case .added: "Добавлен"
        case .deleted: "Удалён"
        case .renamed: "Переименован"
        case .copied: "Скопирован"
        }
    }

    private var color: Color {
        switch entry.file.status {
        case .modified: .orange
        case .added: .green
        case .deleted: .red
        case .renamed, .copied: .blue
        }
    }
}

private struct DiffCounts: View {
    let file: DiffFile

    var body: some View {
        HStack(spacing: 4) {
            if file.additions > 0 { Text("+\(file.additions)").foregroundStyle(.green) }
            if file.deletions > 0 { Text("−\(file.deletions)").foregroundStyle(.red) }
        }
        .font(.caption.monospacedDigit())
        .fixedSize()
    }
}
