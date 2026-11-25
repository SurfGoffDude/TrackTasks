import SwiftUI
import AppKit
import TrackTasksCore

struct TrackTasksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store()
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        let launch = LaunchGate.shared
        DockerSetup.shared.apply()
        launch.whenOpen { Task.detached(priority: .utility) { ContainerStore.shared.recover() } }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            TaskWrites.flush()
            ContainerStore.shared.stopAll()
        }
    }

    var body: some Scene {
        Window("TrackTasks", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear {
                    Appearance.apply(appearance)
                    NSApp.activate()
                }
                .onChange(of: appearance) { Appearance.apply(appearance) }
                .onOpenURL { store.openLink($0) }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                if Updater.shared.availability.mayCheckByHand {
                    Button("Проверить обновления…") { Updater.shared.check() }
                }
            }
            CommandGroup(after: .newItem) {
                Button("Новый проект…") { store.mode = .work; store.showNewProject = true }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Добавить папку проекта…") { store.mode = .work; store.chooseProjectFolder() }
                Divider()
                Button("Режим: Работа") { store.mode = .work }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Режим: Личное") { store.mode = .personal }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Divider()
                Button("Быстрая задача…") { store.showQuickAdd = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Импорт задач…") { store.importIssuesProject = store.selectedProject }
                    .disabled(store.selectedProject == nil)
                Button("Сводка дня") { store.morningDigest() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Обновить проекты") { store.reload() }
                    .keyboardShortcut("r")
                Button("Сегодня") { store.selectedID = Store.todayID }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Все проекты") { store.selectedID = Store.dashboardID }
                    .keyboardShortcut("0")
                Button("Хроника") { store.selectedID = Store.timelineID }
                    .keyboardShortcut("1")
                Button("Очередь Claude") { store.selectedID = Store.queueID }
                    .keyboardShortcut("2")
                Button("Расходы") { store.selectedID = Store.statsID }
                    .keyboardShortcut("3")
                Button("Сессии Claude") { store.selectedID = Store.sessionsID }
                    .keyboardShortcut("4")
                Button("Быстрый поиск…") { store.mode = .work; store.showQuickOpen = true }
                    .keyboardShortcut("p")
                Button("Панель Claude") { store.showClaude.toggle() }
                    .keyboardShortcut("k")
            }
            CommandGroup(after: .toolbar) {
                Picker("Тема", selection: $appearance) {
                    ForEach(Appearance.allCases) { a in
                        Label(a.title, systemImage: a.icon).tag(a)
                    }
                }
                Button("Переключить светлую/тёмную") {
                    let dark = appearance == .dark
                        || (appearance == .system && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                    appearance = dark ? .light : .dark
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
            }
        }

        WindowGroup("Diff", id: DiffView.windowID, for: DiffSource.self) { $source in
            if let source {
                DiffView(source: source)
                    .id(source)
                    .environment(store)
                    .frame(minWidth: 800, minHeight: 480)
            }
        }
        .defaultSize(width: 1200, height: 800)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        WindowGroup("Превью", id: PreviewView.windowID, for: PreviewTarget.self) { $target in
            if let target {
                PreviewView(target: target)
                    .id(target)
                    .environment(store)
                    .frame(minWidth: 760, minHeight: 480)
            }
        }
        .defaultSize(width: 1280, height: 860)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        WindowGroup("История git", id: GitView.windowID, for: String.self) { $id in
            if let id, let p = store.project(id) {
                GitView(project: p)
                    .id(id)
                    .environment(store)
                    .frame(minWidth: 800, minHeight: 480)
            }
        }
        .defaultSize(width: 1200, height: 800)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            let busy = store.jobs.runningCount > 0
            let danger = !DangerModeStore.shared.active.isEmpty
            Image(systemName: danger ? "exclamationmark.octagon.fill" : busy ? "checklist.checked" : "checklist")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

struct SettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage(ClaudeModel.storageKey) private var model: ClaudeModel = .auto
    @AppStorage(ClaudeModel.backgroundKey) private var bgModel: ClaudeModel = .sonnet
    @AppStorage(ClaudeModel.planningKey) private var planningModel: ClaudeModel = .sonnet
    @AppStorage(ClaudeOptions.isolateKey) private var isolate = true
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system
    @AppStorage(TerminalApp.storageKey) private var terminal: TerminalApp = .ghostty
    @AppStorage(Terminals.embeddedKey) private var terminalInCard = true
    @AppStorage(Terminals.tmuxKey) private var terminalTmux = false
    @State private var hasTmux = Terminals.installedTmux() != nil
    @AppStorage("autoAbout") private var autoAbout = true
    @AppStorage(JobQueue.parallelKey) private var parallel = 3
    @AppStorage(Worktrees.enabledKey) private var worktrees = true
    @AppStorage(JobQueue.autoModelKey) private var autoModel = true
    @AppStorage(GitInit.key) private var autoGit = true
    @AppStorage(JobQueue.autoReviewKey) private var autoReview = true
    @AppStorage(JobQueue.planLargeKey) private var planLarge = true
    @AppStorage(Notifier.enabledKey) private var notifications = true
    @AppStorage(JobQueue.limitGuardKey) private var limitGuard = 10
    @AppStorage(JobQueue.fiveHourGuardKey) private var fiveHourGuard = 0
    @AppStorage(SleepGuard.enabledKey) private var preventSleep = true
    @State private var gitBulk: String?
    @State private var gitBulkRunning = false
    @State private var confirmGitBulk = false
    @State private var root = ""

    var body: some View {
        Form {
            Section("Внешний вид") {
                Picker("Тема", selection: $appearance) {
                    ForEach(Appearance.allCases) { a in
                        Label(a.title, systemImage: a.icon).tag(a)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Папка с проектами") {
                HStack {
                    TextField("Путь", text: $root)
                        .onSubmit { store.rootPath = root }
                    Button("Выбрать…") { pick() }
                }
                Text("Структура: <папка>/<категория>/<проект>").font(.caption).foregroundStyle(.secondary)
                ForEach(store.extraFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { store.extraFolders.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Убрать из трекера (папка не удаляется)")
                    }
                }
                Button("Добавить отдельную папку проекта…") { store.chooseProjectFolder() }
                Button("Проверка окружения и пример…") {
                    store.openMainWindow?()
                    store.showOnboarding = true
                }
            }
            Section("Терминал") {
                Toggle("Терминал задачи — в её карточке", isOn: $terminalInCard)
                Text("Вкладки shell, Claude и процессов в очереди. Выключено — всё открывается во внешнем терминале.")
                    .font(.caption).foregroundStyle(.secondary)
                if hasTmux, terminalInCard {
                    Toggle("Shell и Claude в tmux", isOn: $terminalTmux)
                    Text("Новые вкладки shell и Claude переживают перезапуск приложения: свой сервер tmux, твои сессии и конфиг не затронуты. Закрытие вкладки и удаление ветки завершают сессию. ПКМ по вкладке — команда attach.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                tmuxIssues
                Picker("Внешний терминал", selection: $terminal) {
                    ForEach(TerminalApp.allCases) { t in
                        Text(t.isInstalled ? t.title : "\(t.title) (не установлен)").tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Claude Code") {
                Picker("Модель (чат и выполнение задач)", selection: $model) {
                    ForEach(ClaudeModel.allCases) { m in Text("\(m.title) — \(m.hint)").tag(m) }
                }
                Picker("Модель для фона (about.md, быстрые задачи)", selection: $bgModel) {
                    ForEach(ClaudeModel.allCases) { m in Text("\(m.title) — \(m.hint)").tag(m) }
                }
                Picker("Модель для планирования (предложи, уточни, разбей)", selection: $planningModel) {
                    ForEach(ClaudeModel.allCases) { m in Text("\(m.title) — \(m.hint)").tag(m) }
                }
                TextField("Путь к claude (пусто = авто)", text: $claudePath)
                Text("Найден: \(ClaudeLocator.resolve() ?? "—")").font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            AgentProfilesSection()
            DockerSettingsSection()
            Section("Фоновые задачи") {
                Toggle("Автообновление about.md раз в неделю", isOn: $autoAbout)
                Text("Только активные проекты, где после даты в about.md появились новые коммиты.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $parallel, in: JobQueue.parallelRange) {
                    Text("Фоновых задач параллельно: \(parallel)").monospacedDigit()
                }
                Toggle("Автоматически добавлять git", isOn: $autoGit)
                Text("Перед первой работой Claude в проекте без git: git init, .gitignore и первый коммит. Похожие на секреты, личные данные и файлы больше 10 МБ не коммитятся — они дописываются в .gitignore.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Автовыбор модели для задач", isOn: $autoModel)
                Text(autoModel
                     ? "Оценка size: s → Sonnet, l → Opus; короткая простая задача → Sonnet, явные признаки сложности (архитектура, миграции, конкурентность…) → Opus. Если неясно — Haiku читает задачу и выбирает (~$0.001 и пару секунд)."
                     : "Задачи очереди выполняются моделью из настройки «Модель» выше.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Изолировать фоновые запуски", isOn: $isolate)
                Text(isolate
                     ? "Очередь, ревью и выбор модели запускают claude без твоих MCP-серверов, плагинов, хуков, скиллов и пользовательских настроек (~/.claude/settings.json) — системный промпт в разы короче и дешевле. Настройки проекта (.claude/settings*.json) действуют; чат не изолируется."
                     : "Фоновые запуски получают всё из твоей конфигурации claude: MCP-серверы, плагины, хуки — каждый шаг дороже.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Параллельно в одном проекте (git worktree)", isOn: $worktrees)
                    .onChange(of: worktrees) { _, _ in store.jobs.pump() }
                Text(worktrees
                     ? "Если проект занят, следующая задача стартует в отдельном worktree на своей ветке tracktasks/…, от последнего коммита (незакоммиченные правки туда не попадут — если в коде есть такие, задача ждёт коммита и предлагает выбор). После выполнения — «Слить» в очереди. Каждая задача — отдельный процесс claude и расход лимита."
                     : "Задачи одного проекта выполняются по очереди, разные проекты — одновременно. Каждая задача — отдельный процесс claude и расход лимита.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Ревью после выполнения", isOn: $autoReview)
                Text("Второй запуск Claude читает diff задачи и пишет замечания; «Исправить замечания» отправляет их обратно в работу.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("План до кода для задач size: l", isOn: $planLarge)
                Text("Агент сначала изучает проект и пишет «## План» в задачу, не меняя код, и ждёт «Одобрить» / «Доработать» в очереди или на «Сегодня». Для любой задачи то же включает `plan: true` в её файле. Пока план ждёт, слот очереди свободен.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Пауза по недельному лимиту", selection: $limitGuard) {
                    Text("Выключено").tag(0)
                    ForEach([5, 10, 20, 30], id: \.self) { Text("когда осталось < \($0)%").tag($0) }
                }
                Picker("Пауза по лимиту 5 часов", selection: $fiveHourGuard) {
                    Text("Выключено").tag(0)
                    ForEach([5, 10, 20, 30], id: \.self) { Text("когда осталось < \($0)%").tag($0) }
                }
                .onChange(of: fiveHourGuard) { store.jobs.pump() }
                Text("Задача, остановленная лимитом 5 часов, ждёт сброса и один раз продолжает ту же сессию.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Не давать Mac уснуть, пока идёт очередь", isOn: $preventSleep)
                    .onChange(of: preventSleep) { _, _ in store.jobs.updateSleepGuard() }
                Text("Только пока выполняется задача или её проверка; пауза и ожидание лимита сон разрешают. Закрытую крышку это не обходит: Mac уснёт и задачи встанут.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Уведомления macOS", isOn: $notifications)
                Text("Готово / ждёт разрешения / конфликт — с кнопками «Разрешить», «Слить» прямо в уведомлении.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Claude в очереди правит файлы и смотрит git, остальное спрашивает. Работа без вопросов — «опасный режим» в шапке проекта, на время.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            WorktreeCleanupSettings()
            UpdateSettingsSection()
            PhonePushSection()
            IssueSourcesSection()
            Section("Git") {
                let missing = store.projectsWithoutGit
                HStack {
                    Button("Добавить git во все проекты без него (\(missing.count))") { confirmGitBulk = true }
                        .disabled(missing.isEmpty || gitBulkRunning)
                    if gitBulkRunning { ProgressView().controlSize(.small) }
                }
                if let gitBulk {
                    Text(gitBulk).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .confirmationDialog("Добавить git в \(store.projectsWithoutGit.count) проектов?", isPresented: $confirmGitBulk) {
            Button("Добавить") { runGitBulk() }
        } message: {
            Text("В каждом: git init, .gitignore и первый коммит. Секреты, выгрузки данных и файлы > 10 МБ не коммитятся. Проекты внутри другого репозитория пропускаются. Ничего не пушится.")
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onAppear { root = store.rootPath }
    }

    @ViewBuilder private var tmuxIssues: some View {
        let t = Terminals.shared
        if let why = t.restoreFailure {
            HStack {
                Label("Сессии tmux неизвестны: \(why)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("Проверить снова") { t.restoreAgain() }.disabled(t.restoring)
            }
        }
        ForEach(t.orphans, id: \.id) { s in
            HStack {
                Text("tmux без задачи: \(s.command ?? "shell"), \(s.folder)").font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let tmux = Terminals.installedTmux() {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tmux.attachCommand(s.id), forType: .string) }
                        label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Скопировать команду attach")
                }
                Button("Завершить", role: .destructive) { t.endOrphan(s) }
            }
        }
    }

    private func runGitBulk() {
        gitBulkRunning = true
        store.initGitEverywhere { i, n, name in
            gitBulk = "\(i + 1)/\(n): \(name)…"
        } done: { notes in
            gitBulkRunning = false
            gitBulk = notes.isEmpty ? "Готово" : "Готово (\(notes.count)):\n" + notes.joined(separator: "\n")
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: root)
        if panel.runModal() == .OK, let url = panel.url {
            root = url.path
            store.rootPath = url.path
        }
    }
}
