import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Group {
                if store.mode == .personal { PersonalSidebar() } else { SidebarView() }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if store.mode == .personal {
                PersonalDetail()
            } else {
                workDetail
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                StorageIssuesBanner()
                OldAllowAllBanner()
            }
        }
        .onAppear {
            let open = openWindow
            store.openMainWindow = { open(id: "main") }
        }
        .searchable(text: $store.search, placement: .sidebar, prompt: store.mode == .personal ? "Поиск напоминаний" : "Поиск проектов")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ModeSwitcher()
            }
            if store.mode == .work {
                ToolbarItem(placement: .navigation) {
                    WeeklyLimitBadge()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshMetaIfStale()
            store.jobs.refreshPRs()
        }
        .sheet(isPresented: $store.showQuickAdd) {
            QuickAddSheet()
        }
        .sheet(isPresented: $store.showQuickOpen) {
            QuickOpenSheet()
        }
        .sheet(item: $store.commitProject) { p in
            CommitSheet(project: p)
        }
        .sheet(item: $store.importIssuesProject) { p in
            ImportIssuesSheet(project: p)
        }
        .sheet(item: $store.prJob) { j in
            PullRequestSheet(job: j)
        }
        .sheet(item: $store.snapshotJob) { j in
            SnapshotSheet(job: j)
        }
        .sheet(item: $store.handoffJob) { j in
            HandoffSheet(job: j)
        }
        .sheet(isPresented: $store.showNewProject) {
            NewProjectSheet()
        }
        // Closing in any way is «Пропустить».
        .sheet(isPresented: $store.showOnboarding, onDismiss: { LaunchGate.shared.finish() }) {
            OnboardingView()
        }
        .alert(store.enqueueAlert?.title ?? "", isPresented: Binding(
            get: { store.enqueueAlert != nil }, set: { if !$0 { store.enqueueAlert = nil } }
        ), presenting: store.enqueueAlert) { a in
            if let confirm = a.confirm {
                Button("Добавить") { confirm() }
                Button("Отмена", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
        .alert("Не получилось", isPresented: Binding(
            get: { store.taskError != nil }, set: { if !$0 { store.taskError = nil } }
        ), presenting: store.taskError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }

    @ViewBuilder
    private var workDetail: some View {
            switch store.selectedID {
            case Store.timelineID:
                TimelineView()
            case Store.queueID:
                QueueView()
            case Store.todayID:
                TodayView()
            case Store.statsID:
                StatsView()
            case Store.sessionsID:
                SessionsView()
            case Store.automationsID:
                AutomationsView()
            default:
                if let p = store.selectedProject {
                    ProjectDetailView(project: p)
                        .id(p.id)
                } else {
                    DashboardView()
                }
            }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        // Once for the whole list: a row must not go through the queue.
        let waiting = store.jobs.waitingForYou
        let waitingIn = Dictionary(grouping: waiting.compactMap(\.job.projectID)) { $0 }.mapValues(\.count)
        List(selection: $store.selectedID) {
            Section {
                HStack {
                    Label("Сегодня", systemImage: "sun.max")
                    Spacer()
                    WaitingBadge(count: waiting.count)
                }
                    .tag(Store.todayID)
                Label("Все проекты", systemImage: "square.grid.2x2")
                    .tag(Store.dashboardID)
                Label("Хроника", systemImage: "clock.arrow.circlepath")
                    .tag(Store.timelineID)
                HStack {
                    Label("Очередь Claude", systemImage: "list.bullet.rectangle.portrait")
                    Spacer()
                    WaitingBadge(count: waiting.count)
                    if store.jobs.activeCount > 0 {
                        Text("\(store.jobs.activeCount)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.blue.opacity(0.25), in: .capsule)
                            .help("В очереди и в работе: \(store.jobs.activeCount)")
                            .accessibilityLabel("В очереди и в работе: \(store.jobs.activeCount)")
                    }
                }
                .tag(Store.queueID)
                Label("Расписания", systemImage: "calendar.badge.clock")
                    .tag(Store.automationsID)
                Label("Сессии Claude", systemImage: "text.magnifyingglass")
                    .tag(Store.sessionsID)
                Label("Расходы", systemImage: "chart.bar.xaxis")
                    .tag(Store.statsID)
            }

            let matches = store.taskMatches
            if !matches.isEmpty {
                Section("Найдено в задачах: \(matches.count)") {
                    ForEach(matches.prefix(30), id: \.task.id) { m in
                        Button { store.reveal(m.task, in: m.project) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: m.task.status.icon).foregroundStyle(m.task.status.color).font(.caption)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(m.task.title).lineLimit(1)
                                    Text(m.project.displayName).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !store.pinnedProjects.isEmpty {
                Section("Закреплённые") {
                    ForEach(store.pinnedProjects) { p in
                        SidebarRow(project: p, git: store.git[p.id], waiting: waitingIn[p.id] ?? 0).tag(p.id)
                    }
                }
            }

            ForEach(store.grouped(excludingPinned: true), id: \.category) { group in
                Section {
                    ForEach(group.projects) { p in
                        SidebarRow(project: p, git: store.git[p.id], waiting: waitingIn[p.id] ?? 0).tag(p.id)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(Palette.color(for: group.category)).frame(width: 7, height: 7)
                        Text(group.category)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.isLoading && store.projects.isEmpty { ProgressView() }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Menu {
                    Button("Новый проект…") { store.showNewProject = true }
                    Button("Добавить папку проекта…") { store.chooseProjectFolder() }
                    Divider()
                    Button("Папка с проектами…") { store.chooseRootFolder() }
                    Text(store.rootPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .fixedSize()
                .help("Добавить проект или сменить папку")
                .accessibilityLabel("Добавить проект или сменить папку")
                StatusFilterBar()
            }
            .padding(10)
        }
    }
}

struct SidebarRow: View {
    @Environment(Store.self) private var store
    let project: Project
    let git: GitInfo?
    var waiting = 0

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(project.status.color.gradient)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(project.displayName)
                    .lineLimit(1)
                if store.sortMode == .recent {
                    Text("\(project.category) · \(store.lastActivity(project))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            WaitingBadge(count: waiting)
            if let git, git.dirty > 0 {
                Image(systemName: "pencil.circle.fill").font(.caption2).foregroundStyle(.orange)
                    .help("Незакоммичено: \(git.dirty)")
                    .accessibilityLabel("Незакоммичено: \(git.dirty)")
            }
            if project.doingCount > 0 {
                Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.blue)
                    .help("Задач в работе: \(project.doingCount)")
                    .accessibilityLabel("Задач в работе: \(project.doingCount)")
            }
            if project.openCount > 0 {
                Text("\(project.openCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Открытых задач: \(project.openCount)")
            }
        }
        .help(project.summary)
        .contextMenu { ProjectMenu(project: project) }
    }
}

struct ProjectMenu: View {
    @Environment(Store.self) private var store
    let project: Project

    var body: some View {
        Button(store.pinned.contains(project.id) ? "Открепить" : "Закрепить") { store.togglePin(project) }
        Divider()
        Button("Открыть в Finder") { store.revealInFinder(project.url) }
        Button("Открыть в терминале") { store.openTerminal(at: project.url) }
        Button("Claude Code в терминале") { store.openTerminal(at: project.url, command: store.claudeCommand()) }
        if store.git[project.id] == nil {
            Divider()
            Button("Добавить git") { store.ensureGit(project.id, force: true) }
        }
        if store.isExtra(project) {
            Divider()
            Button("Убрать из трекера") { store.removeExtra(project) }
        }
    }
}

struct StatusFilterBar: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        // Segmented control compresses to the column width instead of pushing the list wider.
        Picker("Статус", selection: $store.statusFilter) {
            Text("Все").tag(ProjectStatus?.none)
            Text("Актив").tag(ProjectStatus?.some(.active))
            Text("Пауза").tag(ProjectStatus?.some(.paused))
            Text("Архив").tag(ProjectStatus?.some(.archived))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Backdrop

struct Backdrop: View {
    var tint: Color = .accentColor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            if dark {
                // Deep near-black base so glass reads as glass, not grey.
                LinearGradient(colors: [Color(white: 0.07), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
            LinearGradient(
                colors: [tint.opacity(dark ? 0.30 : 0.22), .clear, Color.purple.opacity(dark ? 0.18 : 0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(colors: [tint.opacity(dark ? 0.22 : 0.16), .clear], center: .topTrailing, startRadius: 20, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Small components

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .glassEffect(.regular.tint(color.opacity(0.15)), in: .capsule)
    }
}

struct GitBadges: View {
    let git: GitInfo?

    var body: some View {
        if let git {
            HStack(spacing: 8) {
                Label(git.branch.isEmpty ? "—" : git.branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                if git.dirty > 0 {
                    Label("\(git.dirty)", systemImage: "pencil").foregroundStyle(.orange)
                        .help("Незакоммиченных файлов: \(git.dirty)")
                }
                if git.ahead > 0 {
                    Label("\(git.ahead)", systemImage: "arrow.up").foregroundStyle(.purple)
                        .help("Не запушено коммитов: \(git.ahead)")
                }
                if git.behind > 0 {
                    Label("\(git.behind)", systemImage: "arrow.down").foregroundStyle(.teal)
                        .help("Отстаёт от удалённой ветки: \(git.behind)")
                }
            }
            .labelStyle(CompactLabel())
        }
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

