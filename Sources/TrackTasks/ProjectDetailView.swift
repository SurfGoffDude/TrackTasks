import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TrackTasksCore

struct ProjectDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    let project: Project
    @State private var aboutExpanded = false
    @State private var editing: TaskItem?
    @State private var editingDoc: ProjectDoc?

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                aboutCard
                SpecCard(project: project) { editingDoc = $0 }
                WorkflowsCard(project: project)
                ProjectExpensesCard(project: project)
                TaskProblemsCard(project: project)
                TaskBoard(project: project, editing: $editing)
            }
            .padding(28)
        }
        .background(Backdrop(tint: Palette.color(for: project.category)))
        .safeAreaInset(edge: .bottom) {
            if !store.selectedTasks.isEmpty { selectionBar }
        }
        .navigationTitle(project.displayName)
        .navigationSubtitle(project.category)
        .toolbar { toolbarContent }
        .inspector(isPresented: $store.showClaude) { claudePanel }
        .sheet(item: $editing) { t in
            TaskEditor(task: t, project: project)
        }
        .sheet(item: $editingDoc) { d in
            ProjectDocEditor(doc: d, projectID: project.id)
        }
        .onAppear {
            store.selectedTasks.removeAll()
            openFocused()
        }
        .onChange(of: store.focusTask) { openFocused() }
        // Files and git are watched via FSEvents in Store; one fresh git status on open is enough.
        .task(id: project.id) { store.refreshGit(project.id) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
            ToolbarItemGroup {
                if let g = store.git[project.id], g.dirty > 0 || g.ahead > 0 {
                    Button { store.commitProject = project } label: {
                        Label("Коммит", systemImage: "checkmark.diamond").labelStyle(.titleAndIcon)
                    }
                    .help("Коммит с сообщением от Claude и пуш")
                }
                if store.git[project.id] != nil {
                    Button { openWindow(id: DiffView.windowID, value: DiffSource(project: project)) } label: {
                        Label("Diff", systemImage: "plusminus").labelStyle(.titleAndIcon)
                    }
                    .help("Просмотр незакоммиченных изменений")
                    Button { openWindow(id: GitView.windowID, value: project.id) } label: {
                        Label("История git", systemImage: "point.3.connected.trianglepath.dotted").labelStyle(.titleAndIcon)
                    }
                    .help("История, ветки, fetch, pull и push")
                }
                Menu {
                    Button { store.togglePin(project) } label: {
                        Label(store.pinned.contains(project.id) ? "Открепить" : "Закрепить наверху",
                              systemImage: store.pinned.contains(project.id) ? "pin.fill" : "pin")
                    }
                    Divider()
                    Button { store.revealInFinder(project.url) } label: { Label("Показать в Finder", systemImage: "folder") }
                    Button { store.openTerminal(at: project.url) } label: { Label("Терминал в папке проекта", systemImage: "terminal") }
                    Button { store.openTerminal(at: project.url, command: store.claudeCommand()) } label: {
                        Label("Claude Code в терминале", systemImage: "apple.terminal.on.rectangle")
                    }
                    Divider()
                    Section("Экспорт доски") {
                        Button("Скопировать markdown") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(boardMarkdown, forType: .string)
                        }
                        Button("Сохранить в файл…") { saveBoard() }
                    }
                } label: { Label("Ещё", systemImage: "ellipsis.circle").labelStyle(.titleAndIcon) }
                .help("Закрепить, Finder, терминал, экспорт доски")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button { store.showClaude.toggle() } label: { Label("Claude", systemImage: "sparkles").labelStyle(.titleAndIcon) }
                    .help("Панель Claude (⌘K)")
            }
    }

    private var boardMarkdown: String {
        BoardExport.markdown(name: project.displayName, tasks: project.tasks, archive: project.archive)
    }

    private func saveBoard() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.displayName) — доска.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try boardMarkdown.write(to: url, atomically: true, encoding: .utf8) }
        catch { NSAlert(error: error).runModal() }
    }

    private var claudePanel: some View {
        let intro = "Спроси Claude про «\(project.displayName)»: составить задачи, разобрать сделанное, спланировать."
        return ClaudePanel(session: store.session(for: project), intro: intro, actions: projectActions) {
            ChatTasks.markdown([(nil, project.tasks)])
        }
            .inspectorColumnWidth(min: 340, ideal: 420, max: 600)
    }

    /// Task picked in search / Today board.
    private func openFocused() {
        guard let f = store.focusTask, let t = project.task(path: f) else { return }
        store.focusTask = nil
        editing = t
    }

    private var projectActions: [QuickAction] {
        let s = store.session(for: project)
        return [
            QuickAction(title: "Предложи задачи", icon: "wand.and.stars") { s.send(ClaudePrompts.suggest, display: "Предложи задачи", model: .planning) },
            QuickAction(title: "Что сделано?", icon: "checklist") { s.send(ClaudePrompts.review, display: "Что сделано?") },
            QuickAction(title: "Что дальше?", icon: "signpost.right") { s.send(ClaudePrompts.next, display: "Что дальше?") },
            QuickAction(title: "Обнови about.md", icon: "doc.text") { s.send(ClaudePrompts.about, display: "Обнови about.md") },
            QuickAction(title: "Обнови spectrack.md", icon: "doc.text.magnifyingglass") { s.send(ClaudePrompts.spec, display: "Обнови spectrack.md", model: .planning) },
            QuickAction(title: "Задачи → новый формат", icon: "rectangle.3.group") { s.send(ClaudePrompts.restructure, display: "Привести задачи к новому формату", model: .planning) },
        ]
    }

    private var selectionBar: some View {
        let tasks = project.tasks.filter { store.selectedTasks.contains($0.id) }
        return HStack(spacing: 10) {
            Text("Выбрано: \(tasks.count)").font(.callout.weight(.medium))
            Button {
                store.enqueue(tasks, project: project)
            } label: { Label("В очередь Claude", systemImage: "play.fill") }
            .buttonStyle(.glassProminent)
            .help("Параллельно, насколько позволяет очередь")
            if tasks.count > 1 {
                Menu {
                    Button("Строго по порядку") { store.enqueue(tasks, project: project, chain: true) }
                        .help(QueueModeHelp.strict)
                } label: {
                    Label("Волнами по приоритету", systemImage: "square.stack.3d.up")
                } primaryAction: {
                    store.enqueue(tasks, project: project, waves: true)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
                .help(QueueModeHelp.waves)
            }
            Menu("Статус") {
                ForEach(TaskStatus.allCases) { s in
                    Button(s.title) {
                        for t in tasks { store.setStatus(taskPath: t.id, to: s, projectID: project.id) }
                        store.selectedTasks.removeAll()
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            Menu("Перенести") {
                Button("В архив") { store.move(tasks, to: .archive, projectID: project.id) }
                Button("В черновики") { store.move(tasks, to: .drafts, projectID: project.id) }
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            Button("Снять выделение") { store.selectedTasks.removeAll() }
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 14)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(project.displayName)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            FlowLayout(spacing: 8) {
                Pill(text: project.status.title, color: project.status.color, icon: "circle.fill")
                Pill(text: project.category, color: Palette.color(for: project.category), icon: "folder.fill")
                let last = store.lastActivity(project)
                if !last.isEmpty {
                    Pill(text: last, icon: "calendar")
                }
                if let g = store.git[project.id] {
                    Pill(text: g.branch.isEmpty ? "git" : g.branch, color: .indigo, icon: "arrow.triangle.branch")
                    if g.dirty > 0 {
                        Pill(text: "незакоммичено: \(g.dirty)", color: .orange, icon: "pencil")
                    }
                    if g.ahead > 0 {
                        Pill(text: "не запушено: \(g.ahead)", color: .purple, icon: "arrow.up")
                    }
                    if g.behind > 0 {
                        Pill(text: "отстаёт: \(g.behind)", color: .teal, icon: "arrow.down")
                    }
                }
                VerifyPill(project: project)
                WorktreePill(project: project)
                DangerPill(project: project)
                CIFixPill(project: project)
                DoDPill(project: project)
                ServerControl(folder: project.url, main: project.url)
            }
            if !project.stack.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(project.stack, id: \.self) { s in
                        Text(s)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary.opacity(0.6), in: .capsule)
                    }
                }
            }
        }
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if project.hasAbout {
                Text(project.summary)
                    .font(.title3)
                    .textSelection(.enabled)
                if aboutExpanded {
                    MarkdownView(text: project.aboutBody, hideH1: true)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                FlowLayout(spacing: 8) {
                    Button(aboutExpanded ? "Свернуть" : "Подробнее") {
                        withAnimation(.snappy) { aboutExpanded.toggle() }
                    }
                    .buttonStyle(.glass)
                    Button("Открыть about.md") { store.open(project.aboutURL) }
                        .buttonStyle(.glass)
                    Button { editingDoc = ProjectDoc(title: "about.md", url: project.aboutURL) } label: {
                        Label("Править", systemImage: "pencil")
                    }
                    .buttonStyle(.glass)
                    Button {
                        store.askClaude(project, prompt: ClaudePrompts.about, label: "Обнови about.md")
                    } label: { Label("Обновить с Claude", systemImage: "sparkles") }
                    .buttonStyle(.glass)
                }
            } else {
                Text("У проекта нет about.md").font(.title3)
                Button {
                    store.askClaude(project, prompt: "Создай about.md для этого проекта (формат из системного промпта, кратко, по-русски).", label: "Создай about.md")
                } label: { Label("Сгенерировать с Claude", systemImage: "sparkles") }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

// MARK: - Board

struct TaskBoard: View {
    @Environment(Store.self) private var store
    let project: Project
    @Binding var editing: TaskItem?
    @AppStorage("boardShowsGraph") private var showsGraph = false
    @State private var picked = MilestoneFilter.all
    @State private var folder = TaskFolder.active
    @State private var addFirst = false
    @State private var firstTitle = ""

    var body: some View {
        let milestones = Milestone.all(in: project[folder], archive: folder == .active ? project.archive : [])
        let filter = picked.valid(in: project[folder])
        VStack(alignment: .leading, spacing: 12) {
            if folder == .active, !milestones.isEmpty {
                MilestonesCard(project: project, milestones: milestones, filter: $picked)
            }
            HStack {
                Picker("Раздел", selection: $folder) {
                    Text("Задачи").tag(TaskFolder.active)
                    Text("Черновики (\(project.drafts.count))").tag(TaskFolder.drafts)
                    Text("Архив (\(project.archive.count))").tag(TaskFolder.archive)
                }
                .labelsHidden()
                .fixedSize()
                .help("Задачи, черновики (tasks/drafts) или архив (tasks/archive)")
                if folder == .active {
                    Picker("Вид", selection: $showsGraph) {
                        Label("Доска", systemImage: "rectangle.split.3x1").tag(false)
                        Label("Граф", systemImage: "point.3.connected.trianglepath.dotted").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Доска по статусам или граф зависимостей и волн")
                }
                if !milestones.isEmpty {
                    Picker("Веха", selection: Binding(get: { filter }, set: { picked = $0 })) {
                        Text("Все вехи").tag(MilestoneFilter.all)
                        ForEach(milestones) { Text($0.name).tag(MilestoneFilter.named($0.name)) }
                        Text("Без вехи").tag(MilestoneFilter.none)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                    .help("Показать задачи одной вехи")
                }
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    boardButtons.labelStyle(.titleAndIcon)
                    // Icons alone would have to be guessed.
                    Menu("Claude") { boardActions }.menuStyle(.button).buttonStyle(.glass).fixedSize()
                }
            }
            Text(folder == .archive ? "Только для чтения. «Восстановить» возвращает задачу в «Задачи» с тем же именем файла"
                 : folder == .drafts ? "Черновики не ставятся в очередь. «В задачи» делает черновик обычной задачей"
                 : showsGraph
                 ? "Колонки — волны «Волнами по приоритету», стрелки — depends. Клик — открыть, ⌘-клик — выбрать"
                 : "⌘-клик — выбрать несколько задач, перетаскивание — сменить статус")
                .font(.caption).foregroundStyle(.tertiary)
            if folder == .active, project.tasks.isEmpty, filter == .all { empty }
            if folder != .active {
                ParkedTasks(project: project, folder: folder, editing: $editing, filter: filter)
            } else if showsGraph {
                TaskGraphView(project: project, editing: $editing, filter: filter)
            } else {
                GlassEffectContainer(spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(TaskStatus.allCases) { status in
                            TaskColumn(project: project, status: status, editing: $editing, filter: filter)
                        }
                    }
                }
            }
        }
        // The selection bar must not act on tasks that are no longer shown.
        .onChange(of: filter) { store.selectedTasks.removeAll() }
        .onChange(of: folder) { store.selectedTasks.removeAll() }
        .onChange(of: project.id) { picked = .all; folder = .active }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Задач пока нет", systemImage: "checklist")
        } description: {
            Text("Начни с первой задачи или попроси Claude предложить. Потом её можно поставить в очередь — Claude выполнит её в фоне.")
        } actions: {
            Button { addFirst = true } label: { Label("Новая задача", systemImage: "plus") }
                .buttonStyle(.glassProminent)
                .popover(isPresented: $addFirst) { firstTask }
            Button {
                store.askClaude(project, prompt: ClaudePrompts.suggest, label: "Предложи задачи", model: .planning)
            } label: { Label("Предложить задачи", systemImage: "wand.and.stars") }
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var firstTask: some View {
        HStack(spacing: 8) {
            TextField("Что нужно сделать", text: $firstTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(createFirst)
            Button("Создать", action: createFirst)
                .buttonStyle(.glassProminent)
                .disabled(firstTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14)
    }

    private func createFirst() {
        let title = firstTitle
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        firstTitle = ""
        addFirst = false
        Task {
            if await store.createTask(in: project, title: title, template: .blank, milestone: "") == nil { firstTitle = title }
        }
    }

    private var boardButtons: some View {
        HStack(spacing: 8) { boardActions }
            .buttonStyle(.glass)
            .fixedSize()
    }

    @ViewBuilder
    private var boardActions: some View {
            Button {
                store.askClaude(project, prompt: ClaudePrompts.suggest, label: "Предложи задачи", model: .planning)
            } label: { Label("Предложить задачи", systemImage: "wand.and.stars") }
            .help("Предложить задачи")
            Button {
                store.askClaude(project, prompt: ClaudePrompts.review, label: "Что уже сделано?")
            } label: { Label("Что сделано?", systemImage: "checklist") }
            .help("Что сделано?")
    }
}

struct TaskColumn: View {
    @Environment(Store.self) private var store
    let project: Project
    let status: TaskStatus
    @Binding var editing: TaskItem?
    var filter = MilestoneFilter.all
    @State private var newTitle = ""
    @State private var template: TaskTemplate = .blank
    @State private var targeted = false

    private var items: [TaskItem] { project.tasks.filter { $0.status == status && filter.matches($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: status.icon).foregroundStyle(status.color)
                Text(status.title).font(.headline)
                Text("\(items.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if status == .todo && !items.isEmpty {
                    Menu {
                        Button("Все параллельно") { store.enqueue(items, project: project) }
                        Button("Волнами по приоритету") { store.enqueue(items, project: project, waves: true) }
                            .help(QueueModeHelp.waves)
                        Button("Строго по порядку") { store.enqueue(items, project: project, chain: true) }
                            .help(QueueModeHelp.strict)
                    } label: { Label("В очередь", systemImage: "play.circle").labelStyle(.titleAndIcon) }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("Все показанные задачи «К выполнению» — в очередь Claude")
                }
            }
            .padding(.horizontal, 4)

            if status == .todo {
                HStack(spacing: 8) {
                    Menu {
                        Picker("Шаблон", selection: $template) {
                            ForEach(TaskTemplate.allCases) { t in
                                Label(t.title, systemImage: t.icon).tag(t)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Шаблон", systemImage: template == .blank ? "plus" : template.icon).labelStyle(.titleAndIcon)
                            .accessibilityLabel("Шаблон: \(template.title)")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Шаблон: \(template.title)")
                    TextField(template == .blank ? "Новая задача" : "Новая задача · \(template.title)", text: $newTitle)
                        .textFieldStyle(.plain)
                        .onSubmit(add)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
            }

            ForEach(items) { t in
                TaskCard(task: t, project: project, selected: store.selectedTasks.contains(t.id))
                    .onTapGesture {
                        if NSEvent.modifierFlags.contains(.command) {
                            store.toggleSelection(t)
                        } else {
                            editing = t
                        }
                    }
            }

            if items.isEmpty {
                Text(status == .done ? "Пока ничего" : "Перетащи задачу сюда")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .top)
        .glassEffect(.regular.tint(status.color.opacity(targeted ? 0.25 : 0.04)), in: .rect(cornerRadius: 20))
        .dropDestination(for: String.self) { paths, _ in
            for p in paths { store.setStatus(taskPath: p, to: status, projectID: project.id) }
            return true
        } isTargeted: { targeted = $0 }
    }

    private func add() {
        let title = newTitle, kind = template
        // Cleared at once, so that a second Return makes no second task.
        newTitle = ""
        template = .blank
        Task {
            let made = await store.createTask(in: project, title: title, template: kind, milestone: filter.newTaskMilestone)
            if made == nil, newTitle.isEmpty { newTitle = title; template = kind }
        }
    }
}

struct TaskCard: View {
    @Environment(Store.self) private var store
    let task: TaskItem
    let project: Project
    var selected = false

    var body: some View {
        let job = store.jobs.job(forTask: task.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(task.priority.color.gradient).frame(width: 7, height: 7)
                    .help("Приоритет: \(task.priority.title)")
                Text(task.title)
                    .font(.body.weight(.medium))
                    .strikethrough(task.status == .done, color: .secondary)
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
                    .lineLimit(3)
                if !task.problems.isEmpty {
                    Spacer(minLength: 0)
                    Text("⚠︎")
                        .foregroundStyle(.orange)
                        .help(task.problems.map(\.message).joined(separator: "\n"))
                }
            }
            if let job {
                HStack(spacing: 4) {
                    if job.state == .running { ProgressView().controlSize(.mini) }
                    Text(job.state == .running ? (job.lastLine.isEmpty ? "Claude работает…" : job.lastLine) : "В очереди Claude")
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            } else if let preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                if let progress { Text(progress) }
                if !task.size.isEmpty { Text(task.size.uppercased()).fontWeight(.bold).help("Оценка") }
                if !task.depends.isEmpty { Label("\(task.depends.count)", systemImage: "arrow.turn.down.right").labelStyle(CompactLabel()).help("Зависит от задач: \(task.depends.count)") }
                if !task.milestone.isEmpty { Label(task.milestone, systemImage: "flag").labelStyle(CompactLabel()).lineLimit(1).help("Веха: \(task.milestone)") }
                Spacer()
                Text(task.status == .done && !task.completed.isEmpty ? "✓ \(task.completed)" : task.created)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .glassEffect(selected ? .regular.tint(.accentColor.opacity(0.35)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 14))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .draggable(task.id)
        .contextMenu {
            Menu("Статус") {
                ForEach(TaskStatus.allCases) { s in
                    Button { store.setStatus(taskPath: task.id, to: s, projectID: project.id) } label: {
                        Label(s.title, systemImage: s.icon)
                    }
                }
            }
            Divider()
            Button { store.enqueue([task], project: project) } label: {
                Label("В очередь Claude (фон)", systemImage: "list.bullet.rectangle.portrait")
            }
            .disabled(job != nil || task.status == .done)
            Button { store.runTaskInTerminal(task, project: project) } label: {
                Label("Выполнить в Claude Code (терминал)", systemImage: "play.fill")
            }
            Button { store.askClaude(project, prompt: ClaudePrompts.split(task), label: "Разбей: \(task.title)", model: .planning) } label: {
                Label("Разбить на подзадачи", systemImage: "square.split.2x2")
            }
            Button { store.askClaude(project, prompt: ClaudePrompts.refine(task), label: "Уточни: \(task.title)", model: .planning) } label: {
                Label("Уточнить с Claude", systemImage: "sparkles")
            }
            Divider()
            Button(selected ? "Снять выделение" : "Выделить") { store.toggleSelection(task) }
            Button("Открыть файл") { store.open(task.url) }
            Button("Показать в Finder") { store.revealInFinder(task.url) }
            Divider()
            Button("В архив") { store.move([task], to: .archive, projectID: project.id) }
            Button("В черновики") { store.move([task], to: .drafts, projectID: project.id) }
            Button("Удалить", role: .destructive) { store.delete(task, projectID: project.id) }
        }
    }

    private var preview: String? {
        Evidence.masked(task.body).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("- [") }
    }

    private var progress: String? {
        let lines = Evidence.masked(task.body).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let total = lines.filter { $0.hasPrefix("- [ ]") || $0.hasPrefix("- [x]") }.count
        guard total > 0 else { return nil }
        let done = lines.filter { $0.hasPrefix("- [x]") }.count
        return "☑ \(done)/\(total)"
    }
}

// MARK: - Archive and drafts

/// «Архив» or «Черновики» of the board: a plain list, nothing here goes to the queue.
struct ParkedTasks: View {
    @Environment(Store.self) private var store
    let project: Project
    let folder: TaskFolder
    @Binding var editing: TaskItem?
    var filter = MilestoneFilter.all
    @State private var newTitle = ""

    var body: some View {
        let items = project[folder].filter(filter.matches)
        VStack(alignment: .leading, spacing: 8) {
            if folder == .drafts {
                TextField("Новый черновик", text: $newTitle)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let title = newTitle
                        newTitle = ""
                        Task {
                            let made = await store.createTask(in: project, title: title, milestone: filter.newTaskMilestone, folder: .drafts)
                            if made == nil, newTitle.isEmpty { newTitle = title }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
            }
            ForEach(items) { row($0) }
            if items.isEmpty {
                Text(folder == .drafts ? "Черновиков нет" : "Архив пуст")
                    .font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
    }

    private func row(_ t: TaskItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: t.status.icon).foregroundStyle(t.status.color).help(t.status.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).fontWeight(.medium).lineLimit(2)
                Text(t.fileName).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !t.problems.isEmpty {
                Text("⚠︎").foregroundStyle(.orange).help(t.problems.map(\.message).joined(separator: "\n"))
            }
            Text(t.completed.isEmpty ? t.created : "✓ \(t.completed)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Button(folder == .archive ? "Восстановить" : "В задачи") { store.move([t], to: .active, projectID: project.id) }
                .buttonStyle(.glass)
        }
        .padding(12)
        .contentShape(.rect)
        .onTapGesture { editing = t }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .contextMenu {
            Button(folder == .archive ? "Восстановить" : "В задачи") { store.move([t], to: .active, projectID: project.id) }
            if folder == .drafts {
                Button("В архив") { store.move([t], to: .archive, projectID: project.id) }
            }
            Divider()
            Button("Открыть файл") { store.open(t.url) }
            Button("Показать в Finder") { store.revealInFinder(t.url) }
            if folder == .drafts {
                Divider()
                Button("Удалить", role: .destructive) { store.delete(t, projectID: project.id) }
            }
        }
    }
}

// MARK: - Milestones

/// Progress of the project's milestones; a click filters the board, the menu queues what is left.
struct MilestonesCard: View {
    @Environment(Store.self) private var store
    let project: Project
    let milestones: [Milestone]
    @Binding var filter: MilestoneFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Вехи", systemImage: "flag").font(.headline)
            ForEach(milestones) { row($0) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func row(_ m: Milestone) -> some View {
        let selected = filter == .named(m.name)
        let pending = project.tasks.filter {
            $0.milestone == m.name && $0.status != .done && store.jobs.job(forTask: $0.id) == nil
        }
        return HStack(spacing: 12) {
            Button { filter = selected ? .all : .named(m.name) } label: {
                HStack(spacing: 12) {
                    Text(m.name)
                        .fontWeight(selected ? .semibold : .regular)
                        .lineLimit(1)
                        .frame(width: 160, alignment: .leading)
                    ProgressView(value: m.progress).tint(m.done == m.total ? .green : .accentColor)
                    Text("\(m.done)/\(m.total) · \(m.percent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(selected ? "Показать все задачи" : "Показать только задачи вехи")
            Menu {
                Button("Все параллельно") { store.enqueue(pending, project: project) }
                Button("Волнами по приоритету") { store.enqueue(pending, project: project, waves: true) }
                    .help(QueueModeHelp.waves)
                Button("Строго по порядку") { store.enqueue(pending, project: project, chain: true) }
                    .help(QueueModeHelp.strict)
            } label: { Label("В очередь", systemImage: "play.circle").labelStyle(.titleAndIcon) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(pending.isEmpty)
            .help("Невыполненные задачи вехи — в очередь Claude")
        }
    }
}

// MARK: - Problems

/// Lint results for the project's task files (`TaskLint`), with quick fixes where they are safe.
struct TaskProblemsCard: View {
    @Environment(Store.self) private var store
    let project: Project

    var body: some View {
        let bad = (project.tasks + project.drafts).filter { !$0.problems.isEmpty }
        if !bad.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Проблемы в задачах: \(bad.reduce(0) { $0 + $1.problems.count })", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ForEach(bad) { t in
                    ForEach(t.problems, id: \.self) { p in row(t, p) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 18))
        }
    }

    private func row(_ t: TaskItem, _ p: TaskProblem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.message).font(.callout)
                Text(t.fileName).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            switch p.kind {
            case .brokenDepend(let name), .parkedDepend(let name):
                Button("Убрать ссылку") { store.removeDepend(name, from: t.id, projectID: project.id) }
                    .buttonStyle(.glass)
            case .missingCompleted:
                Button("Проставить completed") { store.fillCompleted(taskPath: t.id, projectID: project.id) }
                    .buttonStyle(.glass)
            default:
                EmptyView()
            }
            Button("Открыть") { store.open(t.url) }
                .buttonStyle(.glass)
        }
    }
}

// MARK: - Editor

struct TaskEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var task: TaskItem
    /// The file as it was when `task` was taken from it.
    @State private var base: TaskItem
    let project: Project
    @State private var editing = false
    @State private var saving = false
    @State private var failure: String?
    @State private var conflict: TaskMerge.Conflict?
    /// What was to follow the save stopped by `conflict`.
    @State private var afterConflict: () -> Void = {}
    @FocusState private var bodyFocused: Bool
    private var readOnly: Bool { task.folder == .archive }

    init(task: TaskItem, project: Project) {
        _task = State(initialValue: task)
        _base = State(initialValue: task)
        self.project = project
    }

    /// `then` runs only after a successful save; otherwise the window stays with everything typed.
    private func save(then: @escaping () -> Void = {}) {
        guard !saving else { return }
        saving = true
        let sent = task, seen = base
        Task {
            let r = await store.save(sent, base: seen, projectID: project.id)
            saving = false
            switch r {
            case .saved(let t):
                base = t
                task = t
                then()
            case .conflict(let c):
                afterConflict = then
                conflict = c
            case .failed(let m): failure = m
            }
        }
    }

    private func startEditing() {
        editing = true
        DispatchQueue.main.async { bodyFocused = true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Название", text: $task.title, axis: .vertical)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .disabled(readOnly)

            HStack(spacing: 16) {
                Picker("Статус", selection: $task.status) {
                    ForEach(TaskStatus.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Picker("Приоритет", selection: $task.priority) {
                    ForEach(Priority.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 200)
                Picker("Оценка", selection: $task.size) {
                    Text("—").tag("")
                    Text("S").tag("s")
                    Text("M").tag("m")
                    Text("L").tag("l")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Оценка: S — мелочь, L — большая. У Claude это и модель: S — Sonnet, L — Opus, M — выберет Haiku")
                let profiles = AgentProfileStore.current
                if !profiles.custom.isEmpty || !task.agent.isEmpty {
                    Picker("Агент", selection: $task.agent) {
                        Text("По умолчанию").tag("")
                        ForEach(profiles.all) { Text($0.title).tag($0.id) }
                        if !task.agent.isEmpty, profiles.resolve(task.agent) == nil {
                            Text("⚠︎ \(task.agent) — нет такого").tag(task.agent)
                        }
                    }
                    .fixedSize()
                    .help("Профиль агента из Настроек")
                }
                if !project.workflows.isEmpty || !task.workflow.isEmpty {
                    Picker("Пайплайн", selection: $task.workflow) {
                        Text("Нет").tag("")
                        ForEach(project.workflows) { Text($0.errors.isEmpty ? $0.name : "⚠︎ \($0.name)").tag($0.name) }
                        if !task.workflow.isEmpty, !project.workflows.contains(where: { $0.name == task.workflow }) {
                            Text("⚠︎ \(task.workflow) — нет такого").tag(task.workflow)
                        }
                    }
                    .fixedSize()
                    .help("workflows/*.md проекта: свой агент на каждом шаге, всегда в worktree")
                }
                Spacer()
                if task.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Menu("Шаблон") {
                        ForEach(TaskTemplate.allCases.filter { $0 != .blank }) { t in
                            Button { task.body = t.body; task.priority = t.priority; startEditing() } label: {
                                Label(t.title, systemImage: t.icon)
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            .disabled(readOnly)

            HStack(spacing: 8) {
                Label("Веха", systemImage: "flag").foregroundStyle(.secondary)
                TextField("нет", text: $task.milestone)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .help("Например v1.0; пусто — без вехи")
                let known = Milestone.all(in: project.tasks + project.drafts)
                if !known.isEmpty {
                    Menu("Выбрать") {
                        ForEach(known) { m in Button(m.name) { task.milestone = m.name } }
                        Divider()
                        Button("Без вехи") { task.milestone = "" }
                    }
                    .fixedSize()
                }
            }
            .disabled(readOnly)

            TaskFilesRow(task: $task, project: project)
                .disabled(readOnly)

            ZStack(alignment: .topTrailing) {
                if editing {
                    TextEditor(text: $task.body)
                        .font(.system(size: 13, design: .monospaced))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .focused($bodyFocused)
                } else {
                    ScrollView {
                        TaskSections(task: $task, project: project, save: { save() })
                            .padding(14)
                            .padding(.top, readOnly ? 0 : 34)
                            .disabled(readOnly)
                    }
                }
                if !readOnly {
                    Button { editing ? (editing = false) : startEditing() } label: {
                        Label(editing ? "Просмотр" : "Править", systemImage: editing ? "eye" : "pencil")
                            .font(.caption)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .keyboardShortcut("e", modifiers: .command)
                .help("⌘E — переключить просмотр и правку")
                .padding(8)
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .frame(minHeight: 300)

            HStack {
                Text("\(task.fileName) · создана \(task.created)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !readOnly {
                    Button("Удалить", role: .destructive) {
                        store.delete(task, projectID: project.id)
                        dismiss()
                    }
                    .buttonStyle(.glass)
                }
                if task.folder == .active {
                    Menu("Claude") {
                        Button("В очередь (фон)") {
                            save {
                                if let fresh = store.project(project.id)?.tasks.first(where: { $0.id == task.id }) {
                                    store.enqueue([fresh], project: project)
                                }
                                dismiss()
                            }
                        }
                        Button("Выполнить в терминале") {
                            save {
                                store.runTaskInTerminal(task, project: project)
                                dismiss()
                            }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                } else {
                    Button(readOnly ? "Восстановить" : "В задачи") {
                        // The move takes the file as it is on disk: unsaved edits of a draft go there first.
                        save {
                            store.move([task], to: .active, projectID: project.id)
                            dismiss()
                        }
                    }
                    .buttonStyle(.glass)
                }
                Button(readOnly ? "Закрыть" : "Отмена") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                if !readOnly {
                    Button("Сохранить") {
                        save { dismiss() }
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 780, height: 680)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .alert("Не сохранено", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }), presenting: failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text("\($0)\n\nВведённое осталось в окне.") }
        .alert("Файл задачи изменился", isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }), presenting: conflict) { c in
            Button("Записать моё", role: .destructive) {
                // Against the version that clashed: a still newer one is checked again.
                task = c.merged
                base = c.current
                save(then: afterConflict)
            }
            Button("Вернуться к правке", role: .cancel) {}
        } message: { c in
            Text("Пока окно было открыто, файл изменили (tt или агент). Не совпадает: \(c.fields.joined(separator: ", ")). Файл не тронут, введённое осталось в окне. «Записать моё» заменит в файле только это, остальные чужие правки сохранятся.")
        }
        // An alert of the main window doesn't show over this sheet.
        .onChange(of: store.taskError, initial: true) {
            guard let e = store.taskError else { return }
            failure = e
            store.taskError = nil
        }
        .onAppear {
            if !readOnly, task.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { startEditing() }
        }
    }
}

// MARK: - Flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            maxX = max(maxX, x)
            rowH = max(rowH, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// Shows/edits about.md `verify:` — the check run after background tasks.
struct VerifyPill: View {
    @Environment(Store.self) private var store
    let project: Project
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        Button {
            text = project.verify
            editing = true
        } label: {
            Pill(text: project.verify.isEmpty ? "проверка не задана" : project.verify,
                 color: project.verify.isEmpty ? .secondary : .green, icon: "checkmark.seal")
        }
        .buttonStyle(.plain)
        .help("Команда проверки после фоновых задач (about.md → verify)")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Проверка после задач").font(.headline)
                Text("Запускается после Claude в папке задачи. Если упала — Claude чинит, до \(JobQueue.maxVerifyAttempts) попыток.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("например: pnpm typecheck && pnpm test", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(save)
                HStack {
                    Button("Подобрать с Claude") {
                        editing = false
                        store.askClaude(project, prompt: "Посмотри проект и определи одну быструю команду проверки (сборка/типы/тесты, до ~2 минут), которую можно запускать без интерактива. Запиши её в frontmatter about.md полем `verify: <команда>` (не меняя остальное). Если проверки нет — так и скажи.", label: "Подобрать команду проверки")
                    }
                    Spacer()
                    Button("Сохранить", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 380)
        }
    }

    private func save() {
        store.setAboutField(project, key: "verify", value: text.trimmingCharacters(in: .whitespaces))
        editing = false
    }
}

/// Shows/edits about.md `worktree: always`.
struct WorktreePill: View {
    @Environment(Store.self) private var store
    @AppStorage(Worktrees.enabledKey) private var enabled = true
    let project: Project
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            Pill(text: project.inDocker ? "в Docker" : project.alwaysWorktree ? "всегда в worktree" : "worktree по занятости",
                 color: project.inDocker ? (DockerSetup.shared.host != nil ? .blue : .orange) : project.alwaysWorktree ? (enabled ? .purple : .orange) : .secondary, icon: "arrow.triangle.branch")
        }
        .buttonStyle(.plain)
        .help("Где идут новые задачи с кодом (about.md → worktree)")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Всегда в worktree", isOn: Binding(
                    get: { project.alwaysWorktree },
                    set: { store.setAboutField(project, key: "worktree", value: $0 ? "always" : "") }))
                Text("Каждая новая задача с кодом получает свой worktree, даже если основная папка свободна. Разумно 3–4 задачи параллельно; готовые ветки нужно сливать («Слить» в очереди). Незакоммиченный код в основной папке задержит задачи. Исключение для одной задачи — worktree: never в её файле.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Агент в контейнере Docker", isOn: Binding(
                    get: { project.inDocker },
                    set: { store.setAboutField(project, key: "executor", value: $0 ? Executor.docker.rawValue : "") }))
                Text("Claude, setup и verify видят только worktree задачи. Планов до кода, нескольких репозиториев, Codex и SSH в контейнере нет. Проверка на Swift/Xcode там не выполняется: такие ветки сливаются только вручную.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if project.inDocker, DockerSetup.shared.host == nil {
                    Label("Docker не настроен — задачи не запустятся (Настройки → Docker)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !enabled {
                    Label("Worktree выключены в Настройках — задачи будут ждать", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(16)
            .frame(width: 380)
        }
    }
}

/// Automatic «Исправить CI» of the project; off by default.
struct CIFixPill: View {
    let project: Project
    @State private var editing = false
    private var on: Bool { CIFixStore.shared.isOn(project.url) }

    var body: some View {
        Button { editing = true } label: {
            Pill(text: on ? "CI: автоисправление" : "CI вручную", color: on ? .orange : .secondary, icon: "wrench.and.screwdriver")
        }
        .buttonStyle(.plain)
        .help("Отправлять ли агенту логи красного CI без вопроса")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Исправлять красный CI автоматически", isOn: Binding(get: { on }, set: { CIFixStore.shared.set(project.url, $0) }))
                Text("Логи упавших проверок уходят в сессию задачи без твоего просмотра, до \(CIFix.maxAuto) раз на один PR и не чаще раза на коммит. Лог пишут посторонние программы: он передаётся как данные, известные виды ключей вычищаются, но секрет без узнаваемого вида может остаться. После такой отправки опасный режим и автопилот на задачу не действуют. Push делаешь только ты — «Обновить PR».")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 380)
        }
    }
}

/// Shows/edits about.md `## Definition of Done` — items added to the criteria of new tasks.
struct DoDPill: View {
    @Environment(Store.self) private var store
    let project: Project
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        Button {
            text = project.dod.joined(separator: "\n")
            editing = true
        } label: {
            Pill(text: project.dod.isEmpty ? "DoD не задан" : "DoD: \(project.dod.count)",
                 color: project.dod.isEmpty ? .secondary : .blue, icon: "checklist")
        }
        .buttonStyle(.plain)
        .help("Definition of Done (about.md): пункты добавляются в критерии новых задач")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Definition of Done").font(.headline)
                Text("По пункту в строке. Добавляются в «Критерии готовности» новых задач; существующие не меняются.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(.body)
                    .frame(height: 120)
                    .border(Color.secondary.opacity(0.3))
                HStack {
                    Spacer()
                    Button("Сохранить") {
                        store.setDefinitionOfDone(project, items: text.components(separatedBy: "\n"))
                        editing = false
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 380)
        }
    }
}

/// One wording for the queue modes in the selection bar and the «К выполнению» column menu.
enum QueueModeHelp {
    static let waves = "Сначала параллельно все high, потом medium, потом low; depends важнее приоритета"
    static let strict = "Строго по очереди: следующая стартует после выполнения (и слияния) предыдущей"
}
