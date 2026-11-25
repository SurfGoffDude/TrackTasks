import SwiftUI

/// Top-bar switch between work projects and personal Reminders.
struct ModeSwitcher: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Picker("Режим", selection: $store.mode) {
            ForEach(AppMode.allCases) { m in
                Label(m.title, systemImage: m.icon).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("⌥⌘1 — Работа, ⌥⌘2 — Личное")
    }
}

enum PersonalRoot {
    static let todayID = "__p_today__"
    static let scheduledID = "__p_scheduled__"
    static let allID = "__p_all__"
    static let completedID = "__p_done__"
    static let smart: Set<String> = [todayID, scheduledID, allID, completedID]
}

struct PersonalBoard: View {
    @Environment(Store.self) private var store
    let filter: String
    @State private var newTitle = ""
    @State private var editing: PersonalTask?

    private var listID: String? {
        PersonalRoot.smart.contains(filter) ? nil : filter
    }

    private var title: String {
        switch filter {
        case PersonalRoot.todayID: "Сегодня"
        case PersonalRoot.scheduledID: "Запланировано"
        case PersonalRoot.allID: "Все"
        default: store.reminders.list(filter)?.title ?? "Список"
        }
    }

    private var tint: Color {
        listID.flatMap { store.reminders.list($0)?.color } ?? .orange
    }

    private var items: [PersonalTask] {
        let all = store.reminders.tasks
        let base: [PersonalTask] = switch filter {
        case PersonalRoot.todayID: all.filter { ($0.isDueToday || $0.isOverdue) || ($0.done && ($0.completedAt.map(Calendar.current.isDateInToday) ?? false)) }
        case PersonalRoot.scheduledID: all.filter { $0.due != nil }
        case PersonalRoot.allID: all
        default: all.filter { $0.listID == filter }
        }
        let q = store.search.trimmingCharacters(in: .whitespaces).lowercased()
        let found = q.isEmpty ? base : all.filter { $0.title.lowercased().contains(q) || $0.notes.lowercased().contains(q) }
        return found.sorted { a, b in
            let pa = rank(a.priority), pb = rank(b.priority)
            if pa != pb { return pa < pb }
            return (a.due ?? .distantFuture, a.created ?? .distantPast) < (b.due ?? .distantFuture, b.created ?? .distantPast)
        }
    }

    private func rank(_ p: Priority?) -> Int {
        switch p { case .high: 0; case .medium: 1; case .low: 2; case nil: 3 }
    }

    var body: some View {
        let rs = store.reminders
        let list = items
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 32, weight: .bold, design: .rounded))
                Text("\(list.filter { !$0.done }.count) открыто").foregroundStyle(.secondary)
                Spacer()
                if rs.loading { ProgressView().controlSize(.small) }
                Button { rs.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass)
                    .help("Синхронизировать с Напоминаниями")
            }
            if let e = rs.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(TaskStatus.allCases) { st in
                    column(st, list.filter { rs.status($0) == st })
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(24)
        .background(Backdrop(tint: tint))
        .navigationTitle(title)
        .sheet(item: $editing) { t in
            PersonalEditor(task: t, status: rs.status(t))
        }
    }

    @State private var targeted: TaskStatus?

    private func column(_ st: TaskStatus, _ items: [PersonalTask]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(st.title, systemImage: st.icon).font(.headline).foregroundStyle(st.color)
                Spacer()
                Text("\(items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if st == .todo {
                TextField("Новое напоминание", text: $newTitle)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .onSubmit {
                        let due: Date? = filter == PersonalRoot.todayID ? Date() : nil
                        if store.reminders.add(newTitle, listID: listID ?? store.reminders.defaultListID, due: due) { newTitle = "" }
                    }
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { t in
                        PersonalCard(task: t, showList: listID == nil) { editing = t }
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular.tint(st.color.opacity(targeted == st ? 0.25 : 0.04)), in: .rect(cornerRadius: 20))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { store.reminders.setStatus(id, st) }
            return true
        } isTargeted: { targeted = $0 ? st : (targeted == st ? nil : targeted) }
    }
}

struct PersonalCard: View {
    @Environment(Store.self) private var store
    let task: PersonalTask
    var showList = false
    let open: () -> Void

    var body: some View {
        let rs = store.reminders
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                withAnimation(.snappy) { rs.setStatus(task.id, task.done ? .todo : .done) }
            } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let p = task.priority, p != .low {
                        Text(p == .high ? "!!!" : "!!").font(.caption.bold()).foregroundStyle(p.color)
                    }
                    Text(task.title)
                        .strikethrough(task.done, color: .secondary)
                        .foregroundStyle(task.done ? .secondary : .primary)
                        .lineLimit(3)
                }
                let note = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let due = task.due {
                        Label(dueText(due), systemImage: "calendar")
                            .foregroundStyle(task.isOverdue ? .red : .secondary)
                    }
                    if showList, let l = rs.list(task.listID) {
                        HStack(spacing: 4) {
                            Circle().fill(l.color).frame(width: 6, height: 6)
                            Text(l.title)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .labelStyle(CompactLabel())
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .onTapGesture(perform: open)
        .draggable(task.id)
        .contextMenu {
            ForEach(TaskStatus.allCases) { s in
                Button { rs.setStatus(task.id, s) } label: { Label(s.title, systemImage: s.icon) }
            }
            Divider()
            Button("Удалить", role: .destructive) { rs.delete(task.id) }
        }
    }

    private func dueText(_ d: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: d)
        let time = task.dueHasTime && (c.hour != 0 || c.minute != 0) ? " " + d.formatted(date: .omitted, time: .shortened) : ""
        if cal.isDateInToday(d) { return "Сегодня" + time }
        if cal.isDateInTomorrow(d) { return "Завтра" + time }
        if cal.isDateInYesterday(d) { return "Вчера" + time }
        return d.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))) + time
    }
}

struct PersonalEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var task: PersonalTask
    @State var status: TaskStatus
    @State private var editingNotes = false

    var body: some View {
        let rs = store.reminders
        VStack(alignment: .leading, spacing: 14) {
            TextField("Название", text: $task.title, axis: .vertical)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
            HStack(spacing: 14) {
                Picker("Статус", selection: $status) {
                    ForEach(TaskStatus.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)
                Picker("Приоритет", selection: $task.priority) {
                    Text("Нет").tag(Priority?.none)
                    ForEach(Priority.allCases) { Text($0.title).tag(Priority?.some($0)) }
                }
                .frame(maxWidth: 200)
                Picker("Список", selection: $task.listID) {
                    ForEach(rs.lists) { l in Text(l.title).tag(l.id) }
                }
                .frame(maxWidth: 220)
            }
            HStack(spacing: 12) {
                Toggle("Срок", isOn: Binding(
                    get: { task.due != nil },
                    set: { task.due = $0 ? (task.due ?? Calendar.current.startOfDay(for: Date())) : nil }
                ))
                if task.due != nil {
                    DatePicker("", selection: Binding(get: { task.due ?? Date() }, set: { task.due = $0 }),
                               displayedComponents: task.dueHasTime ? [.date, .hourAndMinute] : [.date])
                        .labelsHidden()
                        .fixedSize()
                    Toggle("Время и напоминание", isOn: $task.dueHasTime)
                }
                Spacer()
            }
            ZStack(alignment: .topTrailing) {
                if editingNotes || task.notes.isEmpty {
                    TextEditor(text: $task.notes)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                } else {
                    ScrollView {
                        MarkdownView(text: task.notes, roomy: true) { n in
                            task.notes = MD.toggleTask(task.notes, n)
                        }
                        .padding(18)
                    }
                    .onTapGesture(count: 2) { editingNotes = true }
                }
                if !task.notes.isEmpty {
                    Button { editingNotes.toggle() } label: {
                        Label(editingNotes ? "Просмотр" : "Править", systemImage: editingNotes ? "eye" : "pencil").font(.caption)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .padding(8)
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .frame(minHeight: 200)
            HStack {
                Label("Синхронизируется с Напоминаниями", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Удалить", role: .destructive) { rs.delete(task.id); dismiss() }
                    .buttonStyle(.glass)
                Button("Отмена") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    task.done = status == .done
                    rs.save(task, status: status)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 720, height: 520)
    }
}

/// New project: <root>/<category>/<name>, or an existing folder.
struct NewProjectSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category = ""
    @State private var newCategory = ""
    @State private var summary = ""
    @State private var stack = ""
    @State private var git = true
    @State private var error: String?

    private let newTag = "__new__"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Новый проект").font(.title2.bold())
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(store.rootPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Button("Изменить…") { store.chooseRootFolder() }
                    .buttonStyle(.link)
            }
            Form {
                TextField("Название", text: $name)
                Picker("Категория", selection: $category) {
                    ForEach(store.categories, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Новая…").tag(newTag)
                }
                if category == newTag {
                    TextField("Название категории", text: $newCategory)
                }
                TextField("Коротко о проекте", text: $summary, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Стек (через запятую)", text: $stack)
                Toggle("Сразу git init", isOn: $git)
            }
            .formStyle(.grouped)
            if !name.isEmpty {
                let cat = category == newTag ? newCategory : category
                Text("Будет: \(cat)/\(Codec.slug(name).isEmpty ? "…" : Codec.slug(name))/ — about.md, spectrack.md, tasks/")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Добавить существующую папку…") {
                    dismiss()
                    DispatchQueue.main.async { store.chooseProjectFolder() }
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Создать") {
                    error = store.createProject(name: name, category: category == newTag ? newCategory : category,
                                                summary: summary, stack: stack, git: git)
                    if error == nil { dismiss() }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            let cats = store.categories
            category = store.selectedProject.map(\.category).flatMap { cats.contains($0) ? $0 : nil } ?? cats.first ?? newTag
        }
    }
}
