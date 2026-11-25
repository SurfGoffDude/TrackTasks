import SwiftUI
import TrackTasksCore

/// State of the first-run screen. Nothing here starts an agent before `check()` or `start()`.
@Observable @MainActor
final class OnboardingModel {
    enum Step: Int, CaseIterable {
        case folder, checks, example, task
        var title: String {
            switch self {
            case .folder: "Папка проектов"
            case .checks: "Проверки"
            case .example: "Пример"
            case .task: "Первая задача"
            }
        }
    }

    var step = Step.folder
    private(set) var reports: [EnvironmentCheck.Report] = []
    private(set) var checking = false
    private(set) var creating = false
    /// Made by this screen.
    private(set) var example: (project: URL, task: URL)?
    private(set) var error = ""

    @ObservationIgnored private let env: any CheckEnvironment
    @ObservationIgnored private var generation = 0

    init(env: any CheckEnvironment = EnvironmentProbe()) { self.env = env }

    /// On appearing.
    func look(root: URL) async {
        await update(checked: false) { env in EnvironmentCheck.quick(env, root: root) }
    }

    /// The rest of what was checked stays.
    func lookAtFolder(root: URL) async {
        let env = env
        let r = await Task.detached { EnvironmentCheck.folder(env, root) }.value
        if let i = reports.firstIndex(where: { $0.item == .folder }) { reports[i] = r }
    }

    /// «Проверить».
    func check(root: URL) async {
        await update(checked: true) { env in await EnvironmentCheck.full(env, root: root) }
    }

    private func update(checked: Bool, _ body: @escaping @Sendable (any CheckEnvironment) async -> [EnvironmentCheck.Report]) async {
        generation += 1
        let mine = generation, env = env
        checking = checked
        let r = await Task.detached { await body(env) }.value
        // A newer look or check has been asked for.
        guard mine == generation else { return }
        reports = r
        checking = false
    }

    /// true = created.
    func createExample(root: URL) async -> Bool {
        guard !creating, example == nil else { return false }
        creating = true
        error = ""
        defer { creating = false }
        do {
            example = try await Task.detached { () throws -> (project: URL, task: URL) in try ExampleProject.create(in: root) }.value
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// nil = not read by the tracker yet.
    func firstTask(in projects: [Project]) -> (project: Project, task: TaskItem)? {
        guard let example, let p = projects.first(where: { $0.id == example.project.path || $0.url.standardizedFileURL.path == example.project.standardizedFileURL.path }),
              let t = p.tasks.first(where: { $0.fileName == example.task.lastPathComponent }) else { return nil }
        return (p, t)
    }

    func blocked(agent: AgentID) -> String? { EnvironmentCheck.launchBlocked(reports, agent: agent) }

    /// The ordinary queue: its rights, worktree, pause and messages.
    func start(_ found: (project: Project, task: TaskItem), agent: AgentID, gate: LaunchGate, enqueue: ([TaskItem], Project) -> Void) {
        guard blocked(agent: agent) == nil else { return }
        gate.finish()
        enqueue([found.task], found.project)
    }
}

struct OnboardingView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model = OnboardingModel()

    private var agent: AgentID { AgentProfileStore.current.resolve("")?.agent ?? .claude }
    private var rootText: String { tilde(store.rootPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Начало работы").font(.title2.bold())
            HStack(spacing: 14) {
                ForEach(OnboardingModel.Step.allCases, id: \.self) { s in
                    Button { model.step = s } label: {
                        Text("\(s.rawValue + 1). \(s.title)")
                            .fontWeight(s == model.step ? .semibold : .regular)
                            .foregroundStyle(s == model.step ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Пропустить") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if let prev = OnboardingModel.Step(rawValue: model.step.rawValue - 1) {
                    Button("Назад") { model.step = prev }
                }
                if let next = OnboardingModel.Step(rawValue: model.step.rawValue + 1) {
                    Button("Далее") { model.step = next }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .task { await model.look(root: store.rootURL) }
        .onChange(of: store.rootPath) { Task { await model.lookAtFolder(root: store.rootURL) } }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .folder: folder
        case .checks: checks
        case .example: example
        case .task: task
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TrackTasks показывает проекты из одной папки: внутри — категории, в них — проекты. Задачи лежат рядом с кодом, в tasks/*.md.")
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(rootText).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Button("Выбрать…") { store.chooseRootFolder() }
            }
            if let r = model.reports.first(where: { $0.item == .folder }), r.state != .ok { CheckRow(report: r) }
            caption("Отдельную папку проекта можно добавить позже кнопкой «+» в боковой панели.")
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Обязателен только git. Агенты и gh можно добавить позже: задачи, хроника и расходы работают и без них.")
            ForEach(model.reports) { CheckRow(report: $0) }
            HStack {
                Button(model.reports.contains { $0.state == .unchecked } ? "Проверить" : "Проверить снова") {
                    Task { await model.check(root: store.rootURL) }
                }
                .disabled(model.checking)
                if model.checking { ProgressView().controlSize(.small) }
            }
            caption("«Проверить» запускает найденные программы, чтобы узнать версии и вход; они могут обратиться к своим серверам. Лимит не тратится. Приложение ничего не устанавливает: команды ниже проблемы можно скопировать и выполнить самому.")
        }
    }

    private var example: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Пример — новая папка с описанием, спецификацией и одной простой задачей. Её можно удалить в любой момент.")
            Text(tilde(ExampleProject.url(in: store.rootURL).path)).font(.callout.monospaced()).textSelection(.enabled)
            if model.example != nil {
                Label("Пример создан", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Создать пример") {
                    Task {
                        if await model.createExample(root: store.rootURL), let e = model.example {
                            store.select(created: e.project)
                            await model.lookAtFolder(root: store.rootURL)
                        }
                    }
                }
                .disabled(model.creating)
            }
            if !model.error.isEmpty { Label(model.error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            caption("Недостающие папки по этому пути будут созданы. Существующая папка не меняется. Без примера можно обойтись: ⌥⌘N — новый проект.")
        }
    }

    @ViewBuilder private var task: some View {
        let found = model.firstTask(in: store.projects)
        VStack(alignment: .leading, spacing: 10) {
            if model.example == nil {
                Text("Сначала создай пример — или нажми «Готово» и заведи задачу в своём проекте.")
            } else if let found {
                Text("«\(found.task.title)» — проект «\(found.project.displayName)»").font(.headline)
                Text("Её можно сделать самому или отдать агенту через обычную очередь. Запуск и его ревью тратят лимит агента.")
                if let why = model.blocked(agent: agent) {
                    Label(why, systemImage: "info.circle").foregroundStyle(.secondary)
                }
                if store.jobs.paused { caption("Очередь на паузе: задача начнётся, когда её снимут.") }
                if !GitInit.enabled { caption("Автоматическое добавление git выключено в Настройках: задача пойдёт без worktree, прямо в папке примера.") }
                Button("Запустить задачу") {
                    dismiss()
                    model.start(found, agent: agent, gate: .shared) { tasks, project in
                        store.selectedID = Store.queueID
                        store.enqueue(tasks, project: project)
                    }
                }
                .disabled(model.blocked(agent: agent) != nil || model.checking)
                caption("Если git не знает имени и почты, первый коммит не получится — сообщение будет в журнале задачи в очереди.")
            } else {
                ProgressView("Читаю пример…")
            }
        }
    }

    private func caption(_ s: String) -> some View { Text(s).font(.caption).foregroundStyle(.secondary) }
    private func tilde(_ s: String) -> String { s.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

private struct CheckRow: View {
    let report: EnvironmentCheck.Report

    private var icon: (name: String, color: Color) {
        switch report.state {
        case .ok: ("checkmark.circle.fill", .green)
        case .unchecked: ("circle.dashed", .secondary)
        case .unknown, .noAnswer: ("questionmark.circle.fill", .orange)
        case .missing, .old, .noLogin:
            report.item.isRequired ? ("xmark.circle.fill", .red) : ("minus.circle.fill", .orange)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon.name).foregroundStyle(icon.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.item.title + (report.item.isRequired ? " — обязателен" : "")).fontWeight(.medium)
                Text(report.reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if !report.fix.isEmpty { Text(report.fix).font(.callout) }
                if !report.command.isEmpty {
                    HStack {
                        Text(report.command).font(.callout.monospaced()).textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report.command, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Скопировать команду")
                            .accessibilityLabel("Скопировать команду")
                    }
                }
            }
        }
    }
}
