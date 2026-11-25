import SwiftUI
import AppKit
import TrackTasksCore

/// Task view split into sections: description, depends on, checklist, blocks, files, Claude runs.
struct TaskSections: View {
    @Environment(Store.self) private var store
    @Binding var task: TaskItem
    let project: Project
    /// Saves the open task; errors are shown by the editor.
    let save: () -> Void
    @State private var newItem = ""
    @State private var newCriterion = ""
    @State private var newNote = ""
    @State private var newComment = ""
    @State private var hovered: Int?
    @State private var hoveredNote: Int?

    private var siblings: [TaskItem] {
        siblingsAndSelf.filter { $0.id != task.id }
    }
    private var siblingsAndSelf: [TaskItem] { (store.project(project.id) ?? project).allTasks }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let description = MD.withoutTasks(task.body)
            if !description.isEmpty {
                section("Описание", icon: "text.alignleft", color: .secondary) {
                    MarkdownView(text: description, roomy: true)
                }
            }
            questionsSection
            dependsSection
            checklistSection
            criteriaSection
            blocksSection
            notesSection
            commentsSection
            DecisionsSection(task: $task, project: project)
            filesSection
            runsSection
        }
    }

    // MARK: Questions

    @ViewBuilder
    private var questionsSection: some View {
        // As they are in the file: the window may be older.
        let saved = siblingsAndSelf.first { $0.id == task.id } ?? task
        let questions = AgentQuestions.parse(saved.body)
        if !questions.isEmpty {
            let open = AgentQuestions.open(in: saved.body, done: saved.status == .done).count
            section("Вопросы", icon: "questionmark.bubble", color: open > 0 ? .orange : .secondary,
                    trailing: open > 0 ? "ждут ответа: \(open)" : nil) {
                TaskQuestions(task: saved, projectID: project.id, questions: questions)
            }
        }
    }

    // MARK: Depends on

    @ViewBuilder
    private var dependsSection: some View {
        let deps = task.depends
        let all = siblings
        let open = deps.compactMap { d in all.first { $0.fileName == d } }.filter { !$0.satisfiesDepends }
        section("Зависит от", icon: "arrow.turn.down.right", color: open.isEmpty ? .secondary : .orange,
                trailing: open.isEmpty ? (deps.isEmpty ? nil : "всё готово") : "ждёт: \(open.count)") {
            FlowLayout(spacing: 6) {
                ForEach(deps, id: \.self) { d in
                    depChip(d, all.first { $0.fileName == d })
                }
                Menu {
                    let candidates = all.filter { $0.folder == .active && !deps.contains($0.fileName) }
                    if candidates.isEmpty { Text("Других задач нет") }
                    ForEach(TaskStatus.allCases) { st in
                        let group = candidates.filter { $0.status == st }
                        if !group.isEmpty {
                            Section(st.title) {
                                ForEach(group) { t in
                                    Button(t.title) { task.depends.append(t.fileName) }
                                }
                            }
                        }
                    }
                } label: {
                    Label(deps.isEmpty ? "Добавить зависимость" : "Ещё", systemImage: "plus")
                        .font(.callout)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .controlSize(.small)
                .fixedSize()
            }
            if !open.isEmpty {
                Text("Очередь Claude запустит эту задачу после зависимостей, если они тоже в очереди.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func depChip(_ file: String, _ t: TaskItem?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: t?.status.icon ?? "questionmark.circle")
                .foregroundStyle(t?.status.color ?? .secondary)
            Text(t?.title ?? file)
                .strikethrough(t?.status == .done, color: .secondary)
                .lineLimit(1)
            Button {
                task.depends.removeAll { $0 == file }
            } label: { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular.tint((t?.status.color ?? .gray).opacity(0.15)), in: .capsule)
        .help(t == nil ? "Задача не найдена: \(file)" : "\(t!.folder == .active ? "" : t!.folder.title + " · ")\(t!.status.title) · \(file)")
    }

    // MARK: Checklists

    private var checklistSection: some View {
        checklist(title: "Задачи", icon: "checklist", in: nil, placeholder: "Добавить пункт", text: $newItem, subtasks: true)
    }

    private var criteriaSection: some View {
        checklist(title: "Критерии готовности", icon: "flag.checkered", in: .criteria,
                  placeholder: "Добавить критерий — по нему Claude проверит работу", text: $newCriterion, subtasks: false)
    }

    private func checklist(title: String, icon: String, in part: MD.Section?, placeholder: String,
                           text: Binding<String>, subtasks: Bool) -> some View {
        let items = MD.checklist(task.body, in: part)
        let done = items.filter(\.done).count
        let complete = !items.isEmpty && done == items.count
        let unproven = part == .criteria
            ? Set(Evidence.missing(items, asked: store.jobs.evidenceAsked(task: task.id)).map(\.n)) : []
        return section(title, icon: icon, color: complete ? .green : .accentColor,
                       trailing: items.isEmpty ? nil : "\(done) из \(items.count)") {
            if !items.isEmpty {
                ProgressView(value: Double(done), total: Double(items.count))
                    .tint(complete ? .green : .accentColor)
                VStack(spacing: 4) {
                    ForEach(items, id: \.n) { item in
                        checkRow(item, subtasks: subtasks, unproven: unproven.contains(item.n))
                    }
                }
            }
            if part == .criteria, !items.isEmpty, let check = store.jobs.trackerCheck(task: task.id) { TrackerCheckLabel(check: check) }
            HStack(spacing: 8) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        withAnimation(.snappy) { task.body = MD.appendTask(task.body, text.wrappedValue, in: part) }
                        text.wrappedValue = ""
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func checkRow(_ item: MD.CheckItem, subtasks: Bool, unproven: Bool) -> some View {
        let n = item.n
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                withAnimation(.snappy) { task.body = MD.toggleTask(task.body, n) }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                MD.inline(item.text)
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture { withAnimation(.snappy) { task.body = MD.toggleTask(task.body, n) } }
                AgentEvidenceLabel(text: item.evidence, missing: unproven)
            }
            if hovered == n {
                if subtasks && !item.done {
                    Button { makeSubtask(item) } label: { Image(systemName: "arrow.up.forward.square").font(.caption) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Вынести в отдельную задачу — эта будет зависеть от неё")
                }
                Button {
                    withAnimation(.snappy) { task.body = MD.removeTask(task.body, n) }
                } label: { Image(systemName: "trash").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Удалить пункт")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.primary.opacity(item.done ? 0.025 : 0.05), in: .rect(cornerRadius: 9))
        .onHover { hovered = $0 ? n : (hovered == n ? nil : hovered) }
    }

    /// Checklist item → its own task file; this task now depends on it.
    private func makeSubtask(_ item: MD.CheckItem) {
        let title = item.text.trimmingCharacters(in: .whitespaces)
        Task {
            guard let sub = await store.createTask(in: project, title: title,
                                                   body: "Подзадача для «\(task.title)» (tasks/\(task.fileName)).") else { return }
            withAnimation(.snappy) {
                // The list may have changed while the file was being created.
                let same = MD.checklist(task.body).filter { $0.text == item.text }
                if let i = same.first(where: { $0.n == item.n }) ?? same.first { task.body = MD.removeTask(task.body, i.n) }
                if !task.depends.contains(sub.fileName) { task.depends.append(sub.fileName) }
            }
            save()
        }
    }

    // MARK: Notes

    private var notesSection: some View {
        let notes = MD.notes(task.body)
        return section("Заметки", icon: "text.bubble", color: .teal, trailing: notes.isEmpty ? nil : "\(notes.count)") {
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { k, note in
                        noteRow(k, note, last: k == notes.count - 1)
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "plus.bubble").foregroundStyle(.secondary)
                TextField("Что сделано, что решили…", text: $newNote)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        withAnimation(.snappy) { task.body = MD.appendNote(task.body, newNote) }
                        newNote = ""
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func noteRow(_ k: Int, _ note: String, last: Bool) -> some View {
        // "16.11 14:30 — text" → date + text
        let parts = note.components(separatedBy: " — ")
        let hasDate = parts.count > 1 && parts[0].count <= 14 && parts[0].first?.isNumber == true
        let date = hasDate ? parts[0] : ""
        let body = hasDate ? parts.dropFirst().joined(separator: " — ") : note
        let byClaude = body.hasPrefix("Claude")
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(byClaude ? Color.purple : Color.teal).frame(width: 8, height: 8).padding(.top, 5)
                if !last { Rectangle().fill(.secondary.opacity(0.3)).frame(width: 1.5).frame(maxHeight: .infinity) }
            }
            .frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                if !date.isEmpty {
                    Text(date).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                MD.inline(body).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 10)
            Spacer(minLength: 0)
            if hoveredNote == k {
                Button {
                    withAnimation(.snappy) { task.body = MD.removeNote(task.body, k) }
                } label: { Image(systemName: "trash").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .contentShape(.rect)
        .onHover { hoveredNote = $0 ? k : (hoveredNote == k ? nil : hoveredNote) }
    }

    // MARK: Comments

    private var commentsSection: some View {
        let comments = MD.comments(task.body)
        return section("Комментарии", icon: "bubble.left.and.bubble.right", color: .indigo,
                       trailing: comments.isEmpty ? nil : "\(comments.count)") {
            ForEach(Array(comments.enumerated()), id: \.offset) { k, c in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if !c.author.isEmpty { Text(c.author).font(.caption.weight(.semibold)) }
                            if !c.date.isEmpty { Text(c.date).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        Text(c.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.snappy) { task.body = MD.removeComment(task.body, k) }
                    } label: { Image(systemName: "trash").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus.bubble").foregroundStyle(.secondary)
                TextField("Комментарий…", text: $newComment)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        withAnimation(.snappy) {
                            task.body = MD.appendComment(task.body, author: NSFullUserName(), newComment)
                        }
                        newComment = ""
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: Blocks

    @ViewBuilder
    private var blocksSection: some View {
        let blocked = siblings.filter { $0.folder != .archive && $0.depends.contains(task.fileName) }
        if !blocked.isEmpty {
            section("Блокирует", icon: "arrow.turn.up.right", color: .secondary, trailing: "\(blocked.count)") {
                FlowLayout(spacing: 6) {
                    ForEach(blocked) { t in
                        HStack(spacing: 5) {
                            Image(systemName: t.status.icon).foregroundStyle(t.status.color)
                            Text(t.title).lineLimit(1)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                    }
                }
            }
        }
    }

    // MARK: Files & links

    @ViewBuilder
    private var filesSection: some View {
        let refs = MD.references(task.body)
        if !refs.isEmpty {
            section("Файлы и ссылки", icon: "paperclip", color: .secondary) {
                FlowLayout(spacing: 6) {
                    ForEach(refs, id: \.self) { r in
                        let isURL = r.hasPrefix("http")
                        let file = project.url.appendingPathComponent(r)
                        let exists = isURL || FileManager.default.fileExists(atPath: file.path)
                        Button {
                            if isURL, let u = URL(string: r) { NSWorkspace.shared.open(u) }
                            else if exists { NSWorkspace.shared.open(file) }
                        } label: {
                            Label(r, systemImage: isURL ? "link" : exists ? "doc.text" : "doc.badge.ellipsis")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .opacity(exists ? 1 : 0.55)
                        .help(isURL ? r : exists ? "Открыть \(r)" : "Файла пока нет: \(r)")
                        .contextMenu {
                            if !isURL && exists {
                                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                            }
                            Button("Скопировать") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(r, forType: .string)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Claude runs

    @ViewBuilder
    private var runsSection: some View {
        let runs = store.jobs.jobs.filter { $0.taskPath == task.id }
        if !runs.isEmpty {
            let total = runs.reduce(AgentCost()) { $0 + $1.cost }
            section("Запуски агента", icon: "sparkles", color: .purple,
                    trailing: total.text()) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(runs) { j in
                        HStack(spacing: 8) {
                            Image(systemName: icon(j.state)).foregroundStyle(color(j.state))
                            Text(j.created.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU"))))
                                .monospacedDigit()
                            if let m = j.modelTitle { Text(m).foregroundStyle(.secondary) }
                            if let v = j.verdict {
                                Text(v == .ok ? "ревью: ок" : "ревью: замечания")
                                    .foregroundStyle(v == .ok ? .green : .orange)
                            }
                            Spacer()
                            if let c = j.cost.text() { Text(c).monospacedDigit().foregroundStyle(.secondary) }
                        }
                        .font(.callout)
                    }
                    Button("Открыть очередь") { store.selectedID = Store.queueID }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    private func icon(_ s: Job.State) -> String {
        switch s {
        case .pending: "clock"
        case .running: "bolt.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private func color(_ s: Job.State) -> Color {
        switch s {
        case .pending: .secondary
        case .running: .blue
        case .done: .green
        case .failed: .red
        case .cancelled: .gray
        }
    }

    // MARK: Card

    private func section<C: View>(_ title: String, icon: String, color: Color, trailing: String? = nil,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.headline)
                Spacer()
                if let trailing {
                    Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: 14))
    }
}
