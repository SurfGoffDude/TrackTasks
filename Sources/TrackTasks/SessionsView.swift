import SwiftUI

/// All Claude Code sessions of this Mac: list, full-text search, link to a task, resume in the terminal.
struct SessionsView: View {
    @Environment(Store.self) private var store
    private static let pageSize = 200
    @State private var limit = SessionsView.pageSize

    private var browser: SessionBrowser { .shared }

    var body: some View {
        @Bindable var browser = browser
        let rows = makeRows()
        let shown = rows.filter {
            browser.sourceFilter.matches($0.sources)
                && (browser.projectFilter == nil || $0.project?.id == browser.projectFilter)
        }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Сессии Claude")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("\(shown.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if let p = browser.progress {
                    ProgressView(value: Double(p.done), total: Double(p.total)) {
                        Text("Индексация \(p.done) из \(p.total)").font(.caption).monospacedDigit()
                    }
                    .frame(width: 180)
                }
            }
            HStack {
                TextField("Слова из разговора", text: $browser.query)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                Picker("Источник", selection: $browser.sourceFilter) {
                    ForEach(SessionFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Мои — из терминала и чата TrackTasks, TrackTasks — запущенные приложением, Другие — остальные программы")
                Picker("Проект", selection: $browser.projectFilter) {
                    Text("Все проекты").tag(String?.none)
                    ForEach(filterProjects(rows)) { Text($0.displayName).tag(String?.some($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if shown.isEmpty {
                if browser.loaded {
                    ContentUnavailableView(
                        browser.query.isEmpty ? "Сессий нет" : "Ничего не найдено", systemImage: "text.magnifyingglass",
                        description: Text(!rows.isEmpty ? "Есть в других источниках или проектах — смени фильтр"
                                          : browser.query.isEmpty ? "Ищу в ~/.claude/projects" : "Должны встретиться все слова запроса"))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(shown.prefix(limit)) { SessionRow(row: $0) }
                        if shown.count > limit {
                            Button("Показать ещё (\(shown.count - limit))") { limit += Self.pageSize }
                                .buttonStyle(.glass)
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .padding([.horizontal, .top], 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Backdrop(tint: .purple))
        .navigationTitle("Сессии Claude")
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .onChange(of: browser.sourceFilter) { limit = Self.pageSize }
        .onChange(of: browser.projectFilter) { limit = Self.pageSize }
        .task(id: browser.query) {
            limit = Self.pageSize
            // Typing: search when the user pauses.
            try? await Task.sleep(for: .milliseconds(200))
            if !Task.isCancelled { await browser.search() }
        }
    }

    private func makeRows() -> [SessionRow.Model] {
        let projects = Dictionary(store.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let paths = Array(projects.keys)
        let wtRoot = Worktrees.root.path
        var byCwd: [String: String?] = [:]
        var jobTask: [String: String] = [:]
        var busy = Set<String>()
        // Sessions from before the app kept its own list are known from the queue.
        var known = AppSessions.shared.ids
        let chats = AppSessions.chats.ids
        for j in store.jobs.jobs {
            for h in j.handoffs where h.from.agent == .claude {
                guard let sid = h.session else { continue }
                known.insert(sid)
                if let t = j.taskPath { jobTask[sid] = t }
            }
            guard j.agentID == .claude, let sid = j.sessionID else { continue }
            known.insert(sid)
            if let t = j.taskPath { jobTask[sid] = t }
            if j.isActive { busy.insert(sid) }
        }
        let links = SessionLinks.shared.items
        let forkParent = SessionForks.shared.children
        var forkCount: [String: Int] = [:]
        for p in forkParent.values { forkCount[p, default: 0] += 1 }
        // Forks made by the queue: the parent is the session of the source job.
        var jobParent: [String: String] = [:]
        for j in store.jobs.jobs {
            if let sid = j.sessionID, let src = j.forkSession { jobParent[sid] = src; forkCount[src, default: 0] += 1 }
        }
        let titles = Dictionary(browser.results.map { ($0.id, $0.title.isEmpty ? Self.shortPrompt($0.firstPrompt) : $0.title) },
                                uniquingKeysWith: { a, _ in a })
        return browser.results.map { s in
            let pid: String?
            if let known = byCwd[s.cwd] { pid = known } else {
                pid = SessionProject.find(cwd: s.cwd, projects: paths, worktreesRoot: wtRoot)
                byCwd[s.cwd] = .some(pid)
            }
            let project = pid.flatMap { projects[$0] }
            func task(_ path: String?) -> TaskItem? { path.flatMap { project?.task(path: $0) } }
            let manual = task(links[s.id])
            let linked = manual ?? task(jobTask[s.id])
                ?? s.taskFile.flatMap { f in project?.task(path: f) }
            let sources = SessionSource.of(entrypoints: s.entrypoints, known: known.contains(s.id),
                                           chat: chats.contains(s.id),
                                           inWorktree: SessionSource.isInWorktree(cwd: s.cwd, root: wtRoot))
            return .init(session: s, sources: sources, project: project, task: linked, manual: manual != nil,
                         busy: busy.contains(s.id), canResume: browser.folders.contains(s.cwd),
                         forkParent: (forkParent[s.id] ?? jobParent[s.id]).map { ($0, titles[$0] ?? String($0.prefix(8)) + "…") },
                         forks: forkCount[s.id] ?? 0)
        }
    }

    private static func shortPrompt(_ s: String) -> String {
        String(s.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
    }

    /// Projects that have sessions, plus the chosen one (so the picker always has its value).
    private func filterProjects(_ rows: [SessionRow.Model]) -> [Project] {
        var ids = Set(rows.compactMap { $0.project?.id })
        if let f = browser.projectFilter { ids.insert(f) }
        return store.projects.filter { ids.contains($0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

struct SessionRow: View {
    struct Model: Identifiable {
        let session: ClaudeSessionInfo
        let sources: Set<SessionSource>
        let project: Project?
        let task: TaskItem?
        /// The task was linked by hand.
        let manual: Bool
        /// A queue job is working in this session now.
        let busy: Bool
        let canResume: Bool
        /// The session this one was forked from: id and title.
        let forkParent: (id: String, title: String)?
        /// How many forks were made from this session.
        let forks: Int
        /// The file path: the same session id may exist in two folders.
        var id: String { session.path }
    }

    @Environment(Store.self) private var store
    let row: Model

    var body: some View {
        let s = row.session
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headline).font(.headline).lineLimit(1)
                if !s.title.isEmpty, !s.firstPrompt.isEmpty {
                    Text(Self.oneLine(s.firstPrompt)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    ForEach(SessionSource.allCases.filter(row.sources.contains), id: \.self) { src in
                        Image(systemName: src.icon).help(src.help).accessibilityLabel(src.help)
                    }
                    Label(projectName, systemImage: "folder").help(s.cwd)
                    Text(s.updated.formatted(.dateTime.day().month().year().hour().minute().locale(Locale(identifier: "ru_RU"))))
                    Text("реплик: \(s.turns)")
                    if let p = row.forkParent {
                        Label("Ответвление от «\(p.title)»", systemImage: "arrow.triangle.branch")
                            .foregroundStyle(.purple)
                            .help("Сессия \(p.id) — исходная не менялась")
                    }
                    if row.forks > 0 {
                        Label("ответвлений: \(row.forks)", systemImage: "arrow.triangle.branch")
                    }
                    if let t = row.task, let p = row.project {
                        Button { store.reveal(t, in: p) } label: {
                            Label(t.title, systemImage: row.manual ? "link" : t.status.icon).lineLimit(1)
                        }
                        .buttonStyle(.link)
                        .help(row.manual ? "Привязана вручную" : "Открыть задачу")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            linkMenu
            Button { fork() } label: { Image(systemName: "arrow.triangle.branch") }
                .buttonStyle(.glass)
                .disabled(!row.canResume || row.busy)
                .help(row.canResume ? "Fork: новая сессия с той же историей в терминале, эта остаётся как есть (claude --resume --fork-session)"
                      : resumeHelp)
            Button { resume() } label: { Label("Продолжить", systemImage: "apple.terminal.on.rectangle") }
                .buttonStyle(.glass)
                .fixedSize()
                .disabled(!row.canResume || row.busy)
                .help(resumeHelp)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: 12))
        .contextMenu {
            Button("Скопировать команду") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("cd \(Shell.quote(s.cwd)) && \(store.claudeCommand(resume: s.id))", forType: .string)
            }
            Button("Скопировать команду fork") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("cd \(Shell.quote(s.cwd)) && \(store.claudeCommand(resume: s.id, fork: true))", forType: .string)
            }
            Button("Показать файл сессии в Finder") { store.revealInFinder(URL(fileURLWithPath: s.path)) }
        }
    }

    @ViewBuilder private var linkMenu: some View {
        if let p = row.project, !p.tasks.isEmpty {
            Menu {
                if row.manual {
                    Button("Отвязать") { SessionLinks.shared.set(nil, for: row.session.id) }
                    Divider()
                }
                // Newest first: file names start with the creation time.
                ForEach(p.tasks.sorted { $0.fileName > $1.fileName }) { t in
                    Button { SessionLinks.shared.set(t.id, for: row.session.id) } label: {
                        Label(t.title, systemImage: t.id == row.task?.id ? "checkmark" : t.status.icon)
                    }
                }
            } label: {
                Image(systemName: "link")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .fixedSize()
            .help("Привязать к задаче")
        }
    }

    private var headline: String {
        let s = row.session
        if !s.title.isEmpty { return s.title }
        return s.firstPrompt.isEmpty ? "Без реплик" : Self.oneLine(s.firstPrompt)
    }

    private var projectName: String {
        row.project?.displayName ?? (row.session.cwd.isEmpty ? "—" : (row.session.cwd as NSString).lastPathComponent)
    }

    private var resumeHelp: String {
        if row.busy { return "Сейчас в этой сессии работает очередь" }
        return row.canResume ? "claude --resume в терминале" : "Папки сессии больше нет: \(row.session.cwd)"
    }

    private func resume() {
        store.openTerminal(at: URL(fileURLWithPath: row.session.cwd, isDirectory: true),
                           command: store.claudeCommand(resume: row.session.id))
    }

    private func fork() {
        SessionForks.shared.started(row.session)
        store.openTerminal(at: URL(fileURLWithPath: row.session.cwd, isDirectory: true),
                           command: store.claudeCommand(resume: row.session.id, fork: true))
    }

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension SessionFilter {
    var title: String {
        switch self {
        case .all: "Все"
        case .mine: "Мои"
        case .app: "TrackTasks"
        case .other: "Другие"
        }
    }
}

extension SessionSource {
    var icon: String {
        switch self {
        case .mine: "person"
        case .app: "checklist"
        case .other: "puzzlepiece.extension"
        }
    }

    var help: String {
        switch self {
        case .mine: "Моя: велась в терминале или в чате"
        case .app: "Запущена TrackTasks"
        case .other: "Запущена другой программой"
        }
    }
}
