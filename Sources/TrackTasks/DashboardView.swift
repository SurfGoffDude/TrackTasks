import SwiftUI

struct DashboardView: View {
    @Environment(Store.self) private var store

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 400), spacing: 14)]

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                if !store.pinnedProjects.isEmpty {
                    section(title: "Закреплённые", icon: "pin.fill", color: .yellow, projects: store.pinnedProjects)
                }

                if !store.doingTasks.isEmpty {
                    doingSection
                }

                ArchiveCandidates()

                ForEach(store.grouped(), id: \.category) { group in
                    section(title: group.category, icon: nil, color: Palette.color(for: group.category), projects: group.projects)
                }

                if store.grouped().isEmpty && !store.isLoading {
                    ContentUnavailableView.search(text: store.search)
                }
            }
            .padding(28)
        }
        .background(Backdrop())
        .navigationTitle("Проекты")
        .toolbar {
            ToolbarItemGroup {
                Picker(selection: $store.sortMode) {
                    ForEach(SortMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Сортировка", systemImage: "arrow.up.arrow.down")
                }
                .pickerStyle(.menu)
                .help("Сортировка проектов")
                Button { store.showQuickAdd = true } label: { Label("Быстрая задача", systemImage: "plus") }
                    .help("Быстрая задача (⌘⇧N)")
                Button { store.reload() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button { store.showClaude.toggle() } label: { Label("Claude", systemImage: "sparkles") }
                    .help("Claude по всем проектам (⌘K)")
            }
        }
        .inspector(isPresented: $store.showClaude) {
            ClaudePanel(session: store.globalSession(),
                        intro: "Claude видит список всех проектов: сводка, что забросил, где незакоммиченное.",
                        actions: globalActions) { ChatTasks.markdown(store.projects.filter { $0.status != .archived }.map { ($0.displayName, $0.tasks) }) }
                .inspectorColumnWidth(min: 340, ideal: 420, max: 600)
        }
    }

    private var globalActions: [QuickAction] {
        [
            QuickAction(title: "Сводка дня", icon: "sun.max") { store.morningDigest() },
            QuickAction(title: "Что я забросил?", icon: "tortoise") { store.askGlobal(ClaudePrompts.neglected, label: "Что я забросил?") },
            QuickAction(title: "Где незакоммиченное?", icon: "pencil.and.list.clipboard") { store.askGlobal(ClaudePrompts.dirty, label: "Где незакоммиченное?") },
        ]
    }

    private func section(title: String, icon: String?, color: Color, projects: [Project]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).foregroundStyle(color)
                } else {
                    Circle().fill(color.gradient).frame(width: 9, height: 9)
                }
                Text(title).font(.title3.weight(.semibold))
                Text("\(projects.count)").foregroundStyle(.secondary)
            }
            GlassEffectContainer(spacing: 14) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(projects) { p in
                        ProjectCard(project: p)
                    }
                }
            }
        }
    }

    private var header: some View {
        let all = store.projects
        let active = all.filter { $0.status == .active }.count
        let open = all.reduce(0) { $0 + $1.openCount }
        let dirty = store.git.values.filter { $0.dirty > 0 }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Все проекты")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 12)
                Button { store.morningDigest() } label: {
                    Label("Сводка дня", systemImage: "sun.max.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(.orange)
                .fixedSize()
                .help("Claude пройдётся по активным проектам и предложит план (⌘⇧D)")
            }
            GlassEffectContainer(spacing: 10) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                    Stat(value: "\(all.count)", label: "проектов", icon: "folder.fill", color: .blue)
                    Stat(value: "\(active)", label: "активных", icon: "flame.fill", color: .green)
                    Stat(value: "\(open)", label: "открытых задач", icon: "circle.dotted", color: .orange)
                    Stat(value: "\(dirty)", label: "с незакоммиченным", icon: "pencil.circle.fill", color: .pink)
                    if Spend.shared.today > 0 {
                        Stat(value: String(format: "$%.2f", Spend.shared.today), label: "Claude сегодня", icon: "creditcard.fill", color: .purple)
                    }
                }
            }
        }
    }

    private var doingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Сейчас в работе", systemImage: "bolt.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.blue)
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 8) {
                    ForEach(store.doingTasks, id: \.task.id) { item in
                        Button {
                            store.selectedID = item.project.id
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: TaskStatus.doing.icon).foregroundStyle(.blue)
                                Text(item.task.title).lineLimit(1)
                                if store.jobs.job(forTask: item.task.id) != nil {
                                    Image(systemName: "sparkles").foregroundStyle(.orange).help("Claude работает")
                                }
                                Spacer()
                                Text(item.project.displayName).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                    }
                }
            }
        }
    }
}

struct Stat: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color.gradient)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.title2.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                Text(label).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(color.opacity(0.08)), in: .rect(cornerRadius: 16))
    }
}

struct ProjectCard: View {
    @Environment(Store.self) private var store
    let project: Project
    @State private var hover = false

    var body: some View {
        Button {
            store.selectedID = project.id
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if store.pinned.contains(project.id) {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.yellow)
                    }
                    Text(project.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Circle().fill(project.status.color.gradient).frame(width: 8, height: 8)
                        .help(project.status.title)
                }

                Text(project.summary.isEmpty ? "Нет описания" : project.summary)
                    .font(.callout)
                    .foregroundStyle(project.summary.isEmpty ? .tertiary : .secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)

                if !project.stack.isEmpty {
                    Text(project.stack.prefix(4).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Palette.color(for: project.category))
                        .lineLimit(1)
                }

                HStack(spacing: 12) {
                    GitBadges(git: store.git[project.id])
                    Spacer(minLength: 4)
                    if project.openCount > 0 {
                        Label("\(project.openCount)", systemImage: "circle.dotted").labelStyle(CompactLabel())
                    }
                    if project.doingCount > 0 {
                        Label("\(project.doingCount)", systemImage: "bolt.fill").labelStyle(CompactLabel())
                            .foregroundStyle(.blue)
                    }
                    let last = store.lastActivity(project)
                    if !last.isEmpty { Text(last) }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Palette.color(for: project.category).opacity(hover ? 0.14 : 0.05)).interactive(),
                     in: .rect(cornerRadius: 18))
        .scaleEffect(hover ? 1.015 : 1)
        .animation(.snappy(duration: 0.2), value: hover)
        .onHover { hover = $0 }
        .contextMenu { ProjectMenu(project: project) }
    }
}
