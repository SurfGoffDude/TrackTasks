import Foundation
import SwiftUI
import AppKit

@Observable @MainActor
final class Store {
    static let dashboardID = "__dashboard__"
    static let timelineID = "__timeline__"
    static let queueID = "__queue__"
    static let todayID = "__today__"
    static let statsID = "__stats__"
    static let sessionsID = "__sessions__"
    static let automationsID = "__automations__"

    /// First: decides before anything else here reads or writes its files.
    @ObservationIgnored private let launch = LaunchGate.shared
    var showOnboarding = false
    var rootPath: String {
        didSet {
            UserDefaults.standard.set(rootPath, forKey: "rootPath")
            globalSessionStorage = nil
            reload()
        }
    }
    var projects: [Project] = [] {
        didSet {
            derivedVersion &+= 1
            if projectsLoaded, launch.isOpen {
                automations.refreshSoon()
                events.refreshSoon()
            }
        }
    }
    /// Bumped whenever an input of `filtered` / `grouped` / `pinnedProjects` changes — the cache key.
    private(set) var derivedVersion = 0
    @ObservationIgnored private var filteredCache: (version: Int, value: [Project])?
    @ObservationIgnored private var pinnedCache: (version: Int, value: [Project])?
    @ObservationIgnored private var groupedCache: [Bool: (version: Int, value: [(category: String, projects: [Project])])] = [:]
    /// Work (projects folder) or personal (Apple Reminders).
    var mode: AppMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "appMode") }
    }
    /// Project folders outside the root structure, added by hand.
    var extraFolders: [String] {
        didSet {
            UserDefaults.standard.set(extraFolders, forKey: "extraFolders")
            reload()
        }
    }
    var showNewProject = false
    var personalSelection: String? = "__p_today__"
    /// Select this project as soon as the next reload sees it.
    @ObservationIgnored private var pendingSelect: String?
    nonisolated static let extraCategory = "Отдельные папки"
    var git: [String: GitInfo] = [:]
    var selectedID: String? = Store.dashboardID
    var search = "" { didSet { derivedVersion &+= 1 } }
    var statusFilter: ProjectStatus? = nil { didSet { derivedVersion &+= 1 } }
    var isLoading = false
    /// The first scan finished, even if it found no projects.
    @ObservationIgnored private(set) var projectsLoaded = false
    var showClaude = false
    var showQuickAdd = false
    var showQuickOpen = false
    var selectedTasks: Set<String> = []
    /// Project whose commit sheet is open.
    var commitProject: Project?
    /// Project whose «Импорт GitHub Issues» window is open.
    var importIssuesProject: Project?
    /// Job whose pull request sheet is open.
    var prJob: Job?
    /// Job whose «Снимок задачи» sheet is open.
    var snapshotJob: Job?
    /// Job whose «Передать другому агенту» sheet is open.
    var handoffJob: Job?
    /// Task to open in the project view (from search / Today board).
    var focusTask: String?
    /// Alert from «В очередь»: missing/cyclic depends, or an offer to queue dependencies too.
    var enqueueAlert: EnqueueAlert?
    /// Card of the queue to scroll to.
    var focusJob: UUID?
    /// Errors of writing task files, for the alert.
    var taskError: String?
    /// Projects the user chose to keep despite inactivity.
    var keptActive: Set<String> {
        didSet { UserDefaults.standard.set(Array(keptActive), forKey: "keptActive") }
    }

    var pinned: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(pinned), forKey: "pinned")
            derivedVersion &+= 1
        }
    }
    var sortMode: SortMode {
        didSet {
            UserDefaults.standard.set(sortMode.rawValue, forKey: "sortMode2")
            derivedVersion &+= 1
        }
    }
    /// Newest real change per project: max(file mtime, last commit).
    var lastChange: [String: Date] = [:] { didSet { derivedVersion &+= 1 } }
    @ObservationIgnored private var lastMetaLoad = Date.distantPast
    /// Categories = folders directly under the root; refreshed by `reload()`.
    private(set) var categories: [String] = []
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var reloadGen: [String: Int] = [:]
    @ObservationIgnored private var gitPending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var structurePending: Task<Void, Never>?
    /// At most this many projects get `git status` + tree walk at once.
    nonisolated private static let metaQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "TrackTasks.meta"
        q.maxConcurrentOperationCount = 6
        q.qualityOfService = .utility
        return q
    }()

    let jobs = JobQueue(dockerHost: { DockerSetup.shared.host })
    /// Runs schedules of all projects; stands still until the first scan is over.
    @ObservationIgnored private(set) lazy var automations = Automations(
        jobs: jobs, projects: { [weak self] in self?.projects ?? [] }, ensureGit: { [weak self] in self?.ensureGit($0) },
        adopt: { [weak self] t, id in
            self?.patch(t, projectID: id)
            self?.reloadProject(id)
        })
    /// Receives events (webhook, GitHub, git) for rules of all projects.
    @ObservationIgnored private(set) lazy var events = EventRules(
        jobs: jobs, projects: { [weak self] in self?.projects ?? [] }, ensureGit: { [weak self] in self?.ensureGit($0) },
        adopt: { [weak self] t, id in
            self?.patch(t, projectID: id)
            self?.reloadProject(id)
        })
    /// Opens the main window when it is closed; set by the window itself.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// Fuzzy index of tasks, about.md, spectrack.md and docs/ for the quick-open palette.
    let quickSearch = QuickSearchLibrary()
    let reminders = RemindersStore()

    @ObservationIgnored private var signatures: [String: String] = [:]
    @ObservationIgnored private var sessions: [String: ClaudeSession] = [:]
    @ObservationIgnored private var globalSessionStorage: ClaudeSession?

    nonisolated static let ignoredFolders = ProjectScan.ignoredFolders

    /// The chosen projects root (also for code without a `Store`).
    nonisolated static var savedRoot: URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: "rootPath")
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Projects"), isDirectory: true)
    }

    var rootURL: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }

    init() {
        rootPath = UserDefaults.standard.string(forKey: "rootPath")
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Projects")
        pinned = Set(UserDefaults.standard.stringArray(forKey: "pinned") ?? [])
        sortMode = SortMode(rawValue: UserDefaults.standard.string(forKey: "sortMode2") ?? "") ?? .recent
        keptActive = Set(UserDefaults.standard.stringArray(forKey: "keptActive") ?? [])
        mode = AppMode(rawValue: UserDefaults.standard.string(forKey: "appMode") ?? "") ?? .work
        extraFolders = UserDefaults.standard.stringArray(forKey: "extraFolders") ?? []
        jobs.onStarted = { [weak self] job in self?.jobStarted(job) }
        jobs.onFinished = { [weak self] job in self?.jobFinished(job) }
        jobs.onMerged = { [weak self] job in
            guard let pid = job.projectID else { return }
            self?.reloadProject(pid)
            self?.refreshGit(pid)
        }
        Notifier.shared.handler = { [weak self] action in
            guard let self else { return }
            switch action {
            case .allow(let id): self.jobs.answer(requestID: id, allow: true)
            case .deny(let id): self.jobs.answer(requestID: id, allow: false)
            case .merge(let id): if let j = self.jobs.job(id) { self.jobs.merge(j) }
            case .open: self.selectedID = Store.queueID
            }
            NSApp.activate()
        }
        Notifier.shared.setup()
        QueueServer.shared.start(self)
        reload()
        showOnboarding = !launch.isOpen
        let first = showOnboarding
        launch.whenOpen { [weak self] in
            Notifier.shared.askPermission()
            RemoteCleanup.shared.kick()
            Updater.shared.start(gate: RestartGate(
                sources: { [weak self] in self.map { RestartGate.busy(jobs: $0.jobs, chat: $0.chatRunning) } ?? [] },
                freeze: { [weak self] in self?.jobs.frozen = $0 }))
            // May start the user's shell.
            Task.detached { _ = ClaudeLocator.resolve() }
            // git, schedules and events were left out of the first scan.
            if first { self?.reload() }
        }
    }

    /// Sample project of the first-run screen.
    func select(created url: URL) {
        pendingSelect = url.path
        reload()
    }

    // MARK: Derived

    var selectedProject: Project? {
        guard let id = selectedID else { return nil }
        return projects.first { $0.id == id }
    }

    func project(_ id: String?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// Cached until `derivedVersion` changes (reading it keeps SwiftUI observation intact).
    var filtered: [Project] {
        let v = derivedVersion
        if let c = filteredCache, c.version == v { return c.value }
        let value = computeFiltered()
        filteredCache = (v, value)
        return value
    }

    private func computeFiltered() -> [Project] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return projects.filter { p in
            if let s = statusFilter, p.status != s { return false }
            guard !q.isEmpty else { return true }
            let hay = ([p.displayName, p.folderName, p.category, p.summary] + p.stack)
                .joined(separator: " ").lowercased()
            return hay.contains(q)
        }
    }

    func lastChangeDate(_ p: Project) -> Date? {
        lastChange[p.id]
    }

    /// Human-readable "last touched", e.g. «2 ч назад».
    func lastActivity(_ p: Project) -> String {
        guard let d = lastChange[p.id] else { return p.updated }
        return Store.relative(d)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f
    }()

    static func relative(_ d: Date) -> String {
        if Date().timeIntervalSince(d) < 60 { return "только что" }
        return relativeFormatter.localizedString(for: d, relativeTo: Date())
    }

    func sorted(_ ps: [Project]) -> [Project] {
        switch sortMode {
        case .recent:
            ps.sorted {
                let a = lastChange[$0.id] ?? .distantPast, b = lastChange[$1.id] ?? .distantPast
                return a != b ? a > b : $0.displayName < $1.displayName
            }
        case .name:
            ps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .tasks:
            ps.sorted { ($0.openCount, $1.displayName) > ($1.openCount, $0.displayName) }
        }
    }

    var pinnedProjects: [Project] {
        let v = derivedVersion
        if let c = pinnedCache, c.version == v { return c.value }
        let value = sorted(filtered.filter { pinned.contains($0.id) })
        pinnedCache = (v, value)
        return value
    }

    /// Groups by category. `excludingPinned` keeps sidebar tags unique.
    func grouped(excludingPinned: Bool = false) -> [(category: String, projects: [Project])] {
        let v = derivedVersion
        if let c = groupedCache[excludingPinned], c.version == v { return c.value }
        let value = computeGrouped(excludingPinned: excludingPinned)
        groupedCache[excludingPinned] = (v, value)
        return value
    }

    private func computeGrouped(excludingPinned: Bool) -> [(category: String, projects: [Project])] {
        let base = excludingPinned ? filtered.filter { !pinned.contains($0.id) } : filtered
        // "Recent" is a single flat list — category grouping would defeat the ordering.
        if sortMode == .recent {
            return base.isEmpty ? [] : [("Недавние", sorted(base))]
        }
        return Dictionary(grouping: base, by: \.category)
            .map { ($0.key, sorted($0.value)) }
            .sorted { $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending }
    }

    /// Tasks of all projects matching the search text (title or body).
    var taskMatches: [(project: Project, task: TaskItem)] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var out: [(project: Project, task: TaskItem)] = []
        for p in projects {
            for t in p.tasks where t.title.lowercased().contains(q) || t.body.lowercased().contains(q) {
                out.append((p, t))
            }
        }
        func rank(_ t: TaskItem) -> Int { (t.status == .done ? 10 : 0) + t.priorityRank }
        return out.sorted { rank($0.task) < rank($1.task) }
    }

    /// Ссылка из push: только открывает известную задачу. Чужой, неизвестный или битый адрес не делает ничего;
    /// одобрить, запустить или слить ссылкой нельзя (в `AppLink` таких действий нет).
    @discardableResult
    func openLink(_ url: URL) -> Bool {
        guard let link = AppLink.parse(url), case .openTask(let id) = link,
              let job = jobs.job(id), let path = job.taskPath,
              let p = project(job.projectID), let t = p.tasks.first(where: { $0.id == path }) else { return false }
        reveal(t, in: p)
        NSApp.activate()
        return true
    }

    /// Open a project and highlight a task in it.
    func reveal(_ task: TaskItem, in project: Project) {
        search = ""
        selectedID = project.id
        focusTask = task.id
    }

    /// Today board: in progress, important, waiting in the queue.
    var highTasks: [(project: Project, task: TaskItem)] {
        projects.flatMap { p in p.tasks.filter { $0.status == .todo && $0.priority == .high }.map { (p, $0) } }
            .sorted { (lastChange[$0.project.id] ?? .distantPast) > (lastChange[$1.project.id] ?? .distantPast) }
    }

    /// Active-looking projects untouched for 90+ days with nothing open.
    var archiveCandidates: [Project] {
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        return projects.filter { (p: Project) -> Bool in
            if p.status == .archived || keptActive.contains(p.id) || p.openCount > 0 { return false }
            guard let last = lastChange[p.id], last < cutoff else { return false }
            let dirty: Int = git[p.id]?.dirty ?? 0
            return dirty == 0
        }
        .sorted { (lastChange[$0.id] ?? .distantPast) < (lastChange[$1.id] ?? .distantPast) }
    }

    func setProjectStatus(_ p: Project, _ status: ProjectStatus) {
        setAboutField(p, key: "status", value: status.rawValue)
    }

    /// Set (or clear) one frontmatter field in about.md.
    func setAboutField(_ p: Project, key: String, value: String) {
        // An existing file that can't be read is never replaced with bare frontmatter.
        let read = try? String(contentsOf: p.aboutURL, encoding: .utf8)
        if read == nil, FileManager.default.fileExists(atPath: p.aboutURL.path) { NSSound.beep(); return }
        let text = read ?? ""
        let out = Frontmatter.setting(key, to: value, in: text,
                                      defaults: ["name: \(p.displayName)", "category: \(p.category)", "status: \(p.status.rawValue)"])
        try? out.write(to: p.aboutURL, atomically: true, encoding: .utf8)
        reloadProject(p.id)
    }

    func setDefinitionOfDone(_ p: Project, items: [String]) {
        let text = (try? String(contentsOf: p.aboutURL, encoding: .utf8)) ?? ""
        let out = DefinitionOfDone.setting(items, inAbout: text)
        guard out != text else { return }
        do { try out.write(to: p.aboutURL, atomically: true, encoding: .utf8) } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось сохранить Definition of Done"
            alert.informativeText = "\(p.aboutURL.path): \(error.localizedDescription)"
            alert.runModal()
            return
        }
        reloadProject(p.id)
    }

    var projectsWithoutGit: [Project] {
        projects.filter { git[$0.id] == nil && !Git.isRepo($0.url) }
    }

    /// Bulk `git init` with safe first commits; reports per project.
    func initGitEverywhere(progress: @escaping @MainActor (Int, Int, String) -> Void,
                           done: @escaping @MainActor ([String]) -> Void) {
        let items = projectsWithoutGit.map { ($0.id, $0.displayName, $0.url) }
        // Holds a restart for an update, like a merge.
        let hold = MergeToken()
        hold.begin()
        Task.detached(priority: .userInitiated) {
            defer { hold.end() }
            var notes: [String] = []
            for (i, item) in items.enumerated() {
                await MainActor.run { progress(i, items.count, item.1) }
                if let n = GitInit.ensure(item.2) { notes.append("\(item.1): \(n)") }
            }
            let result = notes
            await MainActor.run {
                self.loadGit()
                done(result)
            }
        }
    }

    var doingTasks: [(project: Project, task: TaskItem)] {
        projects.flatMap { p in p.tasks.filter { $0.status == .doing }.map { (p, $0) } }
    }

    // MARK: Adding projects

    /// Creates <root>/<category>/<slug>/ with about.md, spectrack.md and tasks/. Returns an error text on failure.
    func createProject(name: String, category: String, summary: String, stack: String, git: Bool) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Введи название" }
        guard !category.isEmpty, !category.contains("/") else { return "Выбери или впиши категорию" }
        var folder = Codec.slug(name)
        if folder.isEmpty { folder = "project-\(Codec.stamp())" }
        let dir = rootURL.appendingPathComponent(category, isDirectory: true).appendingPathComponent(folder, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) { return "Папка уже есть: \(category)/\(folder)" }
        do {
            try fm.createDirectory(at: dir.appendingPathComponent("tasks", isDirectory: true), withIntermediateDirectories: true)
            let stackList = stack.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let about = """
            ---
            name: \(Frontmatter.quote(name))
            category: \(category)
            status: active
            stack: [\(stackList.joined(separator: ", "))]
            updated: \(Codec.today())
            ---

            # \(name)

            \(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Описание проекта." : summary.trimmingCharacters(in: .whitespacesAndNewlines))

            """
            try about.write(to: dir.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
            try SpecDoc.template(name: name, idea: summary.trimmingCharacters(in: .whitespacesAndNewlines))
                .write(to: dir.appendingPathComponent(SpecDoc.fileName), atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        pendingSelect = dir.path
        if git {
            Task.detached(priority: .userInitiated) {
                _ = GitInit.ensure(dir)
                await MainActor.run { self.loadGit() }
            }
        }
        reload()
        return nil
    }

    /// Adds an existing folder. Folders already inside <root>/<category>/ just get selected.
    func addProjectFolder(_ url: URL) {
        let url = url.standardizedFileURL
        let root = rootURL.standardizedFileURL.path
        pendingSelect = url.path
        if url.deletingLastPathComponent().deletingLastPathComponent().path == root {
            reload()
        } else if !extraFolders.contains(url.path) {
            extraFolders.append(url.path)
        } else {
            selectedID = url.path
        }
    }

    func isExtra(_ p: Project) -> Bool { p.category == Store.extraCategory && extraFolders.contains(p.url.standardizedFileURL.path) }

    func removeExtra(_ p: Project) {
        extraFolders.removeAll { $0 == p.url.standardizedFileURL.path }
        if selectedID == p.id { selectedID = Store.dashboardID }
    }

    func chooseRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Папка с проектами: внутри — категории, в них — проекты"
        panel.directoryURL = rootURL
        if panel.runModal() == .OK, let url = panel.url { rootPath = url.path }
    }

    func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Добавить"
        panel.message = "Папки проектов — можно несколько"
        panel.directoryURL = rootURL
        if panel.runModal() == .OK {
            for url in panel.urls { addProjectFolder(url) }
        }
    }

    func togglePin(_ p: Project) {
        if pinned.contains(p.id) { pinned.remove(p.id) } else { pinned.insert(p.id) }
    }

    // MARK: Loading

    func reload() {
        isLoading = true
        let root = rootURL
        let extras = extraFolders
        Task.detached(priority: .userInitiated) {
            let sp = Log.store.begin("reload")
            let result = Store.scan(root: root, extras: extras)
            let sigs = Dictionary(result.map { ($0.id, Store.signature(of: $0.url)) }, uniquingKeysWith: { a, _ in a })
            let cats = Store.categoryNames(root: root)
            Log.store.end("reload", sp)
            let watchMap = Dictionary(result.map { (Store.realPath($0.url), $0.id) }, uniquingKeysWith: { a, _ in a })
            let watchRoots = [Store.realPath(root)] + extras.map { Store.realPath(URL(fileURLWithPath: $0)) }
            await MainActor.run {
                self.projectsLoaded = true
                self.projects = result
                self.jobs.syncAlwaysWorktree(result)
                self.jobs.syncFiles(result)
                self.jobs.syncQuestions(result)
                self.categories = cats
                self.signatures = sigs
                self.isLoading = false
                self.reindexSearch()
                if let id = self.pendingSelect, result.contains(where: { $0.id == id }) {
                    self.selectedID = id
                    self.pendingSelect = nil
                }
                self.startWatching(roots: watchRoots, projects: watchMap, rootReal: Store.realPath(root))
                self.loadGit()
            }
        }
    }

    nonisolated private static func subdirs(_ url: URL) -> [URL] {
        ProjectScan.subdirs(url)
    }

    nonisolated static func categoryNames(root: URL) -> [String] {
        subdirs(root).map(\.lastPathComponent)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    nonisolated private static func realPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated static func scan(root: URL, extras: [String] = []) -> [Project] {
        ProjectScan.entries(root: root, extras: extras).map {
            var p = Codec.project(at: $0.url, category: $0.category ?? extraCategory)
            TaskRepos.lint(&p, root: root)
            return p
        }
    }

    nonisolated static func signature(of projectURL: URL) -> String {
        let fm = FileManager.default
        var parts: [String] = []
        let about = projectURL.appendingPathComponent("about.md")
        if let d = (try? fm.attributesOfItem(atPath: about.path))?[.modificationDate] as? Date {
            parts.append("a\(d.timeIntervalSince1970)")
        }
        if let d = (try? fm.attributesOfItem(atPath: SpecDoc.url(in: projectURL).path))?[.modificationDate] as? Date {
            parts.append("s\(d.timeIntervalSince1970)")
        }
        for f in WorkflowFile.all(in: projectURL) {
            let d = (try? f.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            parts.append("w\(f.name)\(d)")
        }
        let tasks = projectURL.appendingPathComponent("tasks")
        for folder in TaskFolder.allCases {
            guard let files = try? fm.contentsOfDirectory(at: folder.url(in: tasks), includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            parts.append(folder.rawValue)
            for f in files.sorted(by: { $0.path < $1.path }) {
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                parts.append("\(f.lastPathComponent)\(d)")
            }
        }
        parts.append(contentsOf: Automation.files(in: projectURL).map {
            let d = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            return "\($0.lastPathComponent)\(d)"
        })
        return parts.joined(separator: "|")
    }

    /// Re-reads one project off the main thread; only the newest request per project gets applied.
    func reloadProject(_ id: String) {
        guard let p = project(id) else { return }
        let url = p.url, category = p.category, root = rootURL
        let gen = (reloadGen[id] ?? 0) &+ 1
        reloadGen[id] = gen
        Task.detached(priority: .userInitiated) {
            let (fresh, sig) = Log.store.measure("reloadProject", id) {
                var fresh = Codec.project(at: url, category: category)
                TaskRepos.lint(&fresh, root: root)
                return (fresh, Store.signature(of: url))
            }
            await MainActor.run {
                guard self.reloadGen[id] == gen,
                      let idx = self.projects.firstIndex(where: { $0.id == id }) else { return }
                if self.projects[idx] != fresh { self.projects[idx] = fresh }
                self.jobs.syncAlwaysWorktree([fresh])
                self.jobs.syncFiles([fresh])
                self.jobs.syncQuestions([fresh])
                self.signatures[id] = sig
                self.indexSearch(fresh)
            }
        }
    }

    /// Rebuilds the quick-open index of all projects off the main thread (reads docs/).
    func reindexSearch() {
        let ps = projects
        let lib = quickSearch
        Task.detached(priority: .utility) {
            var all: [String: [SearchEntry]] = [:]
            for p in ps { all[p.id] = SearchEntries.make(p, docs: SearchEntries.docs(in: p.url)) }
            await lib.reset(all)
        }
    }

    /// Re-indexes one project after its files changed.
    func indexSearch(_ p: Project) {
        let lib = quickSearch
        Task.detached(priority: .utility) {
            await lib.replace(project: p.id, with: SearchEntries.make(p, docs: SearchEntries.docs(in: p.url)))
        }
    }

    /// Signatures are computed in the background; only changed projects are re-read.
    func refreshAllIfChanged() {
        let items = projects.map { ($0.id, $0.url) }
        Task.detached(priority: .utility) {
            let sigs = items.map { ($0.0, Store.signature(of: $0.1)) }
            await MainActor.run {
                for (id, s) in sigs where self.signatures[id] != s { self.reloadProject(id) }
            }
        }
    }

    /// Instant in-memory update after our own write; `reloadProject` then confirms from disk.
    func patch(_ t: TaskItem, projectID: String, removing: Bool = false) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var p = projects[idx]
        var tasks = p[t.folder]
        tasks.removeAll { $0.id == t.id }
        if !removing {
            var t = t
            t.body = t.body.trimmingCharacters(in: .whitespacesAndNewlines)
            t.milestone = Milestone.clean(t.milestone)
            // We just wrote the canonical form — lint that, not the stale pre-save problems.
            t.problems = TaskLint.fileProblems(text: Codec.serialize(t), fileName: t.fileName)
            tasks.append(t)
            tasks.sort { ($0.priorityRank, $0.created, $0.fileName) < ($1.priorityRank, $1.created, $1.fileName) }
        }
        p[t.folder] = tasks
        TaskLint.crossCheck(&p)
        projects[idx] = p
    }

    // MARK: File watching

    /// Project map shared with the FSEvents callback; updated in place on every `reload()`
    /// so the stream itself is only recreated when the watched roots change (no lost events).
    private final class WatchState: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: String] = [:]
        private var rootReal = ""
        /// Project paths that themselves contain a skip-dir segment (normally empty).
        private var skipExempt: [String] = []

        func update(map: [String: String], rootReal: String) {
            let exempt = map.keys.filter { $0.split(separator: "/").contains { Activity.skipDirs.contains(String($0)) } }
            lock.lock(); defer { lock.unlock() }
            self.map = map; self.rootReal = rootReal; self.skipExempt = exempt
        }
        func snapshot() -> (map: [String: String], rootReal: String, skipExempt: [String]) {
            lock.lock(); defer { lock.unlock() }
            return (map, rootReal, skipExempt)
        }
    }
    @ObservationIgnored private let watchState = WatchState()
    @ObservationIgnored private var watchedRoots: [String] = []

    private func startWatching(roots: [String], projects map: [String: String], rootReal: String) {
        watchState.update(map: map, rootReal: rootReal)
        guard roots != watchedRoots || watcher == nil else { return }
        watchedRoots = roots
        let state = watchState
        watcher = FileWatcher(paths: roots, latency: 0.3) { [weak self] events in
            let s = state.snapshot()
            let change = Log.fs.measure("fsBatch", "\(events.count) events") {
                FSChange.classify(events, projects: s.map, rootReal: s.rootReal, skipExempt: s.skipExempt,
                                  skipDirs: Activity.skipDirs, ignoredFolders: Store.ignoredFolders)
            }
            guard !change.isEmpty else { return }
            Task { @MainActor in self?.apply(change) }
        }
    }

    private func apply(_ c: FSChange) {
        if c.structure {
            structurePending?.cancel()
            structurePending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }
        for id in c.tasks.union(c.docs) { reloadProject(id) }
        let now = Date()
        for id in c.touched {
            Activity.note(URL(fileURLWithPath: id), at: now)
            // Coarse: re-sorting the sidebar on every keystroke elsewhere isn't worth it.
            if (lastChange[id] ?? .distantPast) < now.addingTimeInterval(-30) { lastChange[id] = now }
        }
        for id in c.git { scheduleGitRefresh(id) }
    }

    /// Debounced per project: a burst of saves → one `git status`.
    private func scheduleGitRefresh(_ id: String) {
        guard launch.isOpen else { return }
        gitPending[id]?.cancel()
        gitPending[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.gitPending[id] = nil
            self?.refreshGit(id)
            // A commit/merge/checkout may unblock queued jobs of this project (no queue polling).
            self?.jobs.gitChanged(id)
            self?.events.gitChanged(id)
        }
    }

    // MARK: Git

    private final class MetaBox: @unchecked Sendable {
        let lock = NSLock()
        var git: [String: GitInfo] = [:]
        var change: [String: Date] = [:]
    }

    nonisolated private static func meta(_ url: URL) -> (GitInfo?, Date?) {
        let g = Git.info(url)
        let dates = [Activity.cachedLastModified(url), g?.lastCommitTime].compactMap { $0 }
        return (g, dates.max())
    }

    /// Git status + last-change dates for all projects (background, at most 6 at a time).
    func loadGit() {
        // Without Command Line Tools git opens their installer.
        guard launch.isOpen else { return }
        lastMetaLoad = Date()
        let items = projects.map { ($0.id, $0.url) }
        let span = Log.git.begin("loadGit", "\(items.count) projects")
        let box = MetaBox()
        let ops = items.map { item in
            BlockOperation {
                let (g, d) = Store.meta(item.1)
                box.lock.lock()
                if let g { box.git[item.0] = g }
                if let d { box.change[item.0] = d }
                box.lock.unlock()
            }
        }
        let done = BlockOperation { [weak self] in
            Log.git.end("loadGit", span)
            let git = box.git, change = box.change
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.git != git { self.git = git }
                if self.lastChange != change { self.lastChange = change }
                self.scheduleAutoAbout()
            }
        }
        ops.forEach(done.addDependency)
        Store.metaQueue.addOperations(ops + [done], waitUntilFinished: false)
    }

    /// Called when the app becomes active; skips if refreshed recently.
    /// Also a safety net for file events FSEvents might have dropped.
    func refreshMetaIfStale() {
        guard !projects.isEmpty, Date().timeIntervalSince(lastMetaLoad) > 60 else { return }
        refreshAllIfChanged()
        loadGit()
    }

    func refreshGit(_ id: String) {
        guard launch.isOpen, let p = project(id) else { return }
        let url = p.url
        Store.metaQueue.addOperation { [weak self] in
            let (g, d) = Log.git.measure("refreshGit", id) { Store.meta(url) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.git[id] != g { self.git[id] = g }
                if let d, self.lastChange[id] != d { self.lastChange[id] = d }
            }
        }
    }

    // MARK: Tasks

    @discardableResult
    func createTask(in project: Project, title: String, template: TaskTemplate = .blank,
                    body: String? = nil, milestone: String = "", folder: TaskFolder = .active) async -> TaskItem? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let dir = folder.url(in: project.tasksURL)
        var t = TaskItem(url: dir, title: clean, status: .todo, priority: template.priority,
                         created: Codec.today(), completed: "",
                         body: DefinitionOfDone.apply(project.dod, to: body ?? template.body))
        t.milestone = milestone
        // Never overwrites: a taken name gets the next second.
        let item = t
        switch await TaskWrites.run({ try TaskFile.create(item, in: dir).item }) {
        case .success(let made):
            patch(made, projectID: project.id)
            reloadProject(project.id)
            return made
        case .failure(let e):
            // With the title: the field it was typed in may be gone.
            report("Задача «\(clean)» не создана: \(TaskFile.message(e))")
            return nil
        }
    }

    private func report(_ error: String) {
        taskError = [taskError, error].compactMap { $0 }.joined(separator: "\n")
    }

    /// Archive, drafts or back, under the same name. A taken name or a task at work is refused.
    func move(_ tasks: [TaskItem], to folder: TaskFolder, projectID: String) {
        Task {
            for t in tasks where t.folder != folder {
                if let why = jobs.moveBlocked(forTask: t.id) {
                    report("«\(t.title)»: \(why)")
                    continue
                }
                switch await TaskWrites.run({ try TaskFile.move(t.url, to: folder) }) {
                case .success(let url):
                    var moved = project(projectID)?.task(path: t.id) ?? t
                    moved.url = url
                    selectedTasks.remove(t.id)
                    patch(t, projectID: projectID, removing: true)
                    patch(moved, projectID: projectID)
                case .failure(let e):
                    report("«\(t.title)»: \(TaskFile.message(e))")
                }
            }
            reloadProject(projectID)
        }
    }

    enum SaveResult {
        case saved(TaskItem)
        /// The file was changed meanwhile in the same place: it is left as it is.
        case conflict(TaskMerge.Conflict)
        case failed(String)

        init(_ r: Result<TaskItem, Error>) {
            switch r {
            case .success(let t): self = .saved(t)
            case .failure(let c as TaskMerge.Conflict): self = .conflict(c)
            case .failure(let e): self = .failed(TaskFile.message(e))
            }
        }
    }

    /// Saves an edit of `base`, the task as the person saw it. The caller shows the error: it has what was typed.
    func save(_ t: TaskItem, base: TaskItem, projectID: String) async -> SaveResult {
        guard t.folder != .archive else { return .saved(t) }
        let r = SaveResult(await TaskWrites.run { try TaskFile.save(t, base: base) })
        if case .saved(let saved) = r { patch(saved, projectID: projectID) }
        reloadProject(projectID)
        return r
    }

    /// A change that fits any text of the file. Memory gets it at once; what was really written replaces it later.
    @discardableResult
    private func change(_ t: TaskItem, projectID: String, _ body: @escaping @Sendable (inout TaskItem) -> Void) async -> Bool {
        guard t.folder != .archive else { return false }
        var now = t
        body(&now)
        patch(now, projectID: projectID)
        let url = t.url
        let r = await TaskWrites.run { try TaskFile.change(url, body) }
        switch r {
        case .success(let saved): patch(saved, projectID: projectID)
        case .failure(let e): report("«\(t.title)» не сохранена: \(TaskFile.message(e))")
        }
        reloadProject(projectID)
        if case .success = r { return true }
        return false
    }

    /// `ifUnchanged`: not a person's decision, gives way to a status somebody has set in the file meanwhile.
    @discardableResult
    func setStatus(taskPath: String, to status: TaskStatus, projectID: String, ifUnchanged: Bool = false) -> Task<Void, Never>? {
        guard let t = project(projectID)?.tasks.first(where: { $0.id == taskPath }), t.status != status else { return nil }
        let seen = t.status
        return Task {
            await change(t, projectID: projectID) {
                if ifUnchanged, $0.status != seen { return }
                $0.status = status
                $0.settleCompleted()
            }
        }
    }

    /// Quick fix from «Проблемы»: drop a depends entry pointing to a missing file.
    func removeDepend(_ name: String, from taskPath: String, projectID: String) {
        guard let p = project(projectID), let t = (p.tasks + p.drafts).first(where: { $0.id == taskPath }) else { return }
        Task { await change(t, projectID: projectID) { $0.depends.removeAll { $0 == name } } }
    }

    /// Quick fix: `status: done` without `completed:` — fill in today.
    func fillCompleted(taskPath: String, projectID: String) {
        guard let p = project(projectID), let t = (p.tasks + p.drafts).first(where: { $0.id == taskPath }) else { return }
        Task { await change(t, projectID: projectID) { $0.settleCompleted() } }
    }

    /// Adds entries to `files:`.
    func addFiles(_ new: [String], to t: TaskItem, projectID: String) async -> Bool {
        await change(t, projectID: projectID) { t in t.files += new.filter { !t.files.contains($0) } }
    }

    func delete(_ t: TaskItem, projectID: String) {
        guard t.folder != .archive else { return }
        let url = t.url
        Task {
            switch await TaskWrites.run({ try TaskFile.trash(url) }) {
            case .success:
                selectedTasks.remove(t.id)
                patch(t, projectID: projectID, removing: true)
            case .failure(let e): report("«\(t.title)» не удалена: \(TaskFile.message(e))")
            }
            reloadProject(projectID)
        }
    }

    func toggleSelection(_ t: TaskItem) {
        if selectedTasks.contains(t.id) { selectedTasks.remove(t.id) } else { selectedTasks.insert(t.id) }
    }

    // MARK: Claude chat

    func session(for project: Project) -> ClaudeSession {
        if let s = sessions[project.id] { return s }
        let s = ClaudeSession(cwd: project.url, title: project.displayName,
                              systemPrompt: ClaudePrompts.projectSystem(name: project.displayName, path: project.url.path))
        let id = project.id
        s.beforeSend = { [weak self] in self?.ensureGit(id) }
        s.onFinish = { [weak self] in
            self?.reloadProject(id)
            self?.refreshGit(id)
        }
        sessions[project.id] = s
        return s
    }

    var chatRunning: Bool { sessions.values.contains(where: \.isBusy) || globalSessionStorage?.isBusy == true }

    func globalSession() -> ClaudeSession {
        if let s = globalSessionStorage { return s }
        let s = ClaudeSession(cwd: rootURL, title: "Все проекты", systemPrompt: ClaudePrompts.globalSystem(root: rootPath))
        s.onFinish = { [weak self] in self?.refreshAllIfChanged() }
        globalSessionStorage = s
        return s
    }

    func askClaude(_ project: Project, prompt: String, label: String? = nil, model: ClaudeModel = .current) {
        showClaude = true
        session(for: project).send(prompt, display: label, model: model)
    }

    /// Morning digest: gathers git/task context off-main, then asks the global session.
    func morningDigest() {
        selectedID = Store.dashboardID
        showClaude = true
        let snapshot = projects, gitSnap = git
        let session = globalSession()
        Task {
            let ctx = await Task.detached(priority: .userInitiated) { Store.digestContext(snapshot, git: gitSnap) }.value
            session.send(ClaudePrompts.digest + "\n\nДанные:\n" + ctx, display: "Сводка дня")
        }
    }

    func askGlobal(_ prompt: String, label: String) {
        selectedID = Store.dashboardID
        showClaude = true
        globalSession().send(prompt + "\n\nПроекты:\n" + overviewContext(), display: label)
    }

    /// One line per project — cheap context for overview questions.
    func overviewContext() -> String {
        sorted(projects).map { p in
            let g = git[p.id]
            let changed = lastChange[p.id].map { Codec.isoDay($0) } ?? p.updated
            var parts = ["\(p.category)/\(p.folderName)", p.status.rawValue, "последнее изменение \(changed)",
                         "открыто \(p.openCount)", "в работе \(p.doingCount)"]
            if let g {
                if g.dirty > 0 { parts.append("незакоммичено \(g.dirty)") }
                if g.ahead > 0 { parts.append("не запушено \(g.ahead)") }
            }
            return "- " + parts.joined(separator: " · ") + " — " + String(p.summary.prefix(90))
        }.joined(separator: "\n")
    }

    nonisolated static func digestContext(_ ps: [Project], git: [String: GitInfo]) -> String {
        let relevant = ps.filter { p in
            p.status == .active || p.doingCount > 0 || (git[p.id]?.dirty ?? 0) > 0 || (git[p.id]?.ahead ?? 0) > 0
        }
        var blocks = [String](repeating: "", count: relevant.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: relevant.count) { i in
            let p = relevant[i]
            var lines = ["### \(p.category)/\(p.folderName) — \(p.displayName) [\(p.status.rawValue)]", p.summary]
            let doing = p.tasks.filter { $0.status == .doing }.map(\.title)
            let high = p.tasks.filter { $0.status == .todo && $0.priority == .high }.map(\.title)
            lines.append("Задачи: открыто \(p.openCount)"
                         + (doing.isEmpty ? "" : "; в работе: " + doing.joined(separator: "; "))
                         + (high.isEmpty ? "" : "; важные todo: " + high.joined(separator: "; ")))
            if let g = git[p.id] {
                lines.append("Git: ветка \(g.branch), незакоммичено \(g.dirty), не запушено \(g.ahead), последний коммит \(g.lastCommit)")
                let commits = Git.commits(p.url, sinceDays: 3, limit: 8)
                if !commits.isEmpty {
                    lines.append("Коммиты за 3 дня:")
                    lines += commits.map { "- \($0.date) \($0.subject)" }
                }
            }
            let text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
            lock.lock(); blocks[i] = text; lock.unlock()
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: Jobs

    /// Auto `git init` (Settings → «Автоматически добавлять git»). Returns a note if git was added.
    @discardableResult
    func ensureGit(_ projectID: String, force: Bool = false) -> String? {
        guard force || GitInit.enabled, let p = projects.first(where: { $0.id == projectID }) else { return nil }
        let note = GitInit.ensure(p.url)
        if note != nil { refreshGit(projectID) }
        return note
    }

    /// `chain`: each task starts only after the previous one is done (and merged).
    /// Every job also waits for all unfinished `depends:` of its task. Dependencies that are neither done
    /// nor queued are offered to be queued first (topological order); cycles and missing files block it.
    /// `waves`: «Волнами по приоритету» — all high in parallel, then medium, then low; every job waits for
    /// all jobs of the previous wave (`depends:` beats priority: a dependency is lifted into an earlier wave).
    /// `confirmed`: the user already agreed to add those dependencies.
    func enqueue(_ tasks: [TaskItem], project: Project, chain: Bool = false, waves: Bool = false,
                 confirmed: Bool = false) {
        switch tryEnqueue(tasks, project: project, chain: chain, waves: waves, confirmed: confirmed) {
        case .queued:
            selectedTasks.removeAll()
        case .failed(let message):
            enqueueAlert = EnqueueAlert(title: "Задача не поставлена в очередь", message: message)
        case .needsDependencies(let extra, let plan):
            let list = extra.map { "• \($0.title)" }.joined(separator: "\n")
            enqueueAlert = EnqueueAlert(
                title: "Сначала нужны зависимости (\(extra.count))",
                message: "Эти задачи не выполнены и не стоят в очереди:\n\(list)\n\nДобавить их перед выбранными?",
                confirm: { [weak self] in self?.enqueue(plan, project: project, chain: chain, waves: waves, confirmed: true) })
        }
    }

    typealias EnqueueResult = JobQueue.EnqueueResult

    /// `enqueue` without dialogs (also for `tt queue add`).
    func tryEnqueue(_ tasks: [TaskItem], project: Project, chain: Bool = false, waves: Bool = false,
                    confirmed: Bool = false, autoDependencies: Bool = true) -> EnqueueResult {
        jobs.tryEnqueue(tasks, project: project, chain: chain, waves: waves, confirmed: confirmed,
                        autoDependencies: autoDependencies, ensureGit: { [weak self] in self?.ensureGit($0) })
    }

    /// `then` gets an error text or nil.
    func quickAdd(_ text: String, to project: Project?, template: TaskTemplate, then: @escaping @MainActor (String?) -> Void) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let project {
            Task {
                if await createTask(in: project, title: clean, template: template) != nil { return then(nil) }
                // Shown by the caller, which still has the text: an alert of the main window may not be seen there.
                let why = taskError
                taskError = nil
                then(why ?? "Задача не создана")
            }
            return
        }
        let list = sorted(projects).map {
            "- \($0.category)/\($0.folderName) — \($0.displayName): \(String($0.summary.prefix(110)))"
        }.joined(separator: "\n")
        var prompt = ClaudePrompts.quickAdd(clean)
        if template != .blank {
            prompt += "\nИспользуй в теле задачи шаблон «\(template.title)» (priority: \(template.priority.rawValue)):\n\(template.body)"
        }
        prompt += "\n\nПроекты:\n" + list
        jobs.add(Job(kind: .quickAdd, title: clean, projectID: nil, projectName: "Claude выберет проект",
                     cwd: rootURL, prompt: prompt, systemPrompt: ClaudePrompts.globalSystem(root: rootPath)))
        then(nil)
    }

    private func jobStarted(_ job: Job) {
        if job.kind == .runTask, let path = job.taskPath, let pid = job.projectID {
            setStatus(taskPath: path, to: .doing, projectID: pid, ifUnchanged: true)
        }
    }

    /// Logs the run into «Заметки» of the task and moves its «## Находки» into the project's spectrack.md
    /// (the app is the only writer for queue jobs). Findings stay in the task when spectrack.md can't be updated.
    private func logRun(_ job: Job, path: String) {
        let first = job.summary.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        let what = job.state == .failed ? "ошибка" : (first.isEmpty ? "выполнено" : String(first.prefix(160)))
        let note = "Claude\(job.kind == .fix ? " (правки по ревью)" : job.kind == .reply ? " (ответ)" : ""): \(what)"
        let url = URL(fileURLWithPath: path), spec = SpecDoc.url(in: job.cwd), name = job.projectName
        Task {
            let r = await TaskWrites.run {
                // Moved or deleted while the agent worked.
                guard FileManager.default.fileExists(atPath: url.path) else { return (moved: 0, problem: "") }
                var moved = 0, problem = ""
                try TaskFile.change(url) { t in
                    let items = SpecDoc.findings(in: t.body)
                    if !items.isEmpty {
                        do {
                            try Store.addFindings(items, task: t.fileName, to: spec, project: name)
                            t.body = SpecDoc.removingFindings(from: t.body)
                            moved = items.count
                        } catch {
                            problem = "Находки задачи «\(t.title)» остались в её файле: \(spec.path) — \(error.localizedDescription)"
                        }
                    }
                    t.body = MD.appendNote(t.body, note)
                }
                return (moved: moved, problem: problem)
            }
            switch r {
            case .success(let s):
                if s.moved > 0 { job.log.append("⚙︎ Находки перенесены в \(spec.lastPathComponent): \(s.moved)") }
                if !s.problem.isEmpty { StorageIssues.shared.report(s.problem) }
            case .failure(let e):
                StorageIssues.shared.report("Итог запуска не записан в задачу «\(job.title)»: \(TaskFile.message(e))")
            }
            if let pid = job.projectID { reloadProject(pid) }
        }
    }

    nonisolated private static func addFindings(_ items: [String], task: String, to url: URL, project: String) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy"
        let old = FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8)
            : SpecDoc.template(name: project)
        try SpecDoc.adding(items, task: task, date: f.string(from: Date()), to: old)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func jobFinished(_ job: Job) {
        jobs.autoCleanup()
        if job.isCodeTask, let path = job.taskPath, job.state == .done || job.state == .failed { logRun(job, path: path) }
        if let pid = job.projectID {
            reloadProject(pid)
            refreshGit(pid)
            if job.isCodeTask {
                let target = job.isFollowUp ? (jobs.job(job.parentID) ?? job) : job
                let url = target.cwd
                let w = target.worktree, base = target.baseCommit
                for p in target.parts {
                    guard let pw = p.worktree else { continue }
                    let from = p.baseCommit
                    Task.detached(priority: .utility) {
                        let d = Worktrees.diffStat(pw, base: from)
                        await MainActor.run { p.diffStat = d }
                    }
                }
                Task.detached(priority: .utility) {
                    let d = w.map { Worktrees.diffStat($0, base: base) } ?? Git.diffStat(url)
                    await MainActor.run { target.diffStat = d }
                }
            }
        } else {
            refreshAllIfChanged()
        }
    }

    /// Weekly about.md refresh for active projects that got commits after about.md's `updated` date.
    func scheduleAutoAbout() {
        guard UserDefaults.standard.object(forKey: "autoAbout") as? Bool ?? true else { return }
        var last = UserDefaults.standard.dictionary(forKey: "autoAboutLast") as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        for p in projects where p.status == .active && p.hasAbout {
            guard let g = git[p.id], !g.lastCommit.isEmpty, g.lastCommit > p.updated else { continue }
            if let l = last[p.id], now - l < 7 * 86400 { continue }
            if jobs.jobs.contains(where: { $0.kind == .updateAbout && $0.projectID == p.id && $0.isActive }) { continue }
            last[p.id] = now
            jobs.add(Job(kind: .updateAbout, title: "Автообновление about.md", projectID: p.id,
                         projectName: p.displayName, cwd: p.url, prompt: ClaudePrompts.about,
                         systemPrompt: ClaudePrompts.projectSystem(name: p.displayName, path: p.url.path)))
        }
        UserDefaults.standard.set(last, forKey: "autoAboutLast")
    }

    // MARK: Timeline

    func loadTimeline(days: Int) async -> [TimelineEntry] {
        let cutoff = Codec.dateString(daysAgo: days)
        let snapshot = projects
        return await Task.detached(priority: .userInitiated) {
            var entries: [TimelineEntry] = []
            for p in snapshot {
                for t in p.tasks + p.archive where t.status == .done && t.completed >= cutoff {
                    entries.append(TimelineEntry(date: t.completed, projectID: p.id, projectName: p.displayName,
                                                 isCommit: false, text: t.title))
                }
            }
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: snapshot.count) { i in
                let p = snapshot[i]
                let commits = Git.commits(p.url, sinceDays: days, limit: 60)
                guard !commits.isEmpty else { return }
                let items = commits.map {
                    TimelineEntry(date: $0.date, projectID: p.id, projectName: p.displayName, isCommit: true, text: $0.subject)
                }
                lock.lock(); entries += items; lock.unlock()
            }
            return entries.sorted { ($0.date, $0.isCommit ? 0 : 1) > ($1.date, $1.isCommit ? 0 : 1) }
        }.value
    }

    // MARK: System actions

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens the chosen terminal app in `url`, optionally typing `command` into the user's shell.
    func openTerminal(at url: URL, command: String? = nil) {
        // A shell there would run git (prompt) and the agent's code on the host.
        guard !ContainerStore.shared.isContainer(url) else { return }
        let src: String
        switch TerminalApp.effective {
        case .ghostty:
            let input = command.map { "set initial input of cfg to \"\(Shell.appleScript($0))\" & linefeed" } ?? ""
            src = """
            tell application "Ghostty"
                activate
                set cfg to new surface configuration
                set initial working directory of cfg to "\(Shell.appleScript(url.path))"
                \(input)
                if (count of windows) > 0 then
                    new tab in front window with configuration cfg
                else
                    new window with configuration cfg
                end if
            end tell
            """
        case .terminal:
            var sh = "cd " + Shell.quote(url.path)
            if let command { sh += " && " + command }
            src = """
            tell application "Terminal"
                activate
                do script "\(Shell.appleScript(sh))"
            end tell
            """
        }
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err { NSLog("TrackTasks: terminal AppleScript failed: \(err)") }
    }

    func runTaskInTerminal(_ t: TaskItem, project: Project) {
        let started = t.status == .todo ? setStatus(taskPath: t.id, to: .doing, projectID: project.id) : nil
        Task {
            // The agent edits the same file: our write goes first.
            await started?.value
            openTerminal(at: project.url, command: claudeCommand(prompt: ClaudePrompts.runTask(t)
                + " Неочевидные находки, полезные следующим агентам, допиши в spectrack.md в раздел «## \(SpecDoc.findingsTitle)» строкой «- дд.мм.гггг — …»; остальной его текст не меняй."))
        }
    }

    /// Shell command for interactive claude, with selected model.
    func claudeCommand(prompt: String? = nil, resume: String? = nil, fork: Bool = false) -> String {
        var cmd = ClaudeArgs.codeMode + " claude"
        let model = ClaudeModel.current
        if !model.alias.isEmpty { cmd += " --model " + model.alias }
        if let resume { cmd += " " + ClaudeArgs.resume(Shell.quote(resume), fork: fork).joined(separator: " ") }
        if let prompt { cmd += " " + Shell.quote(prompt) }
        return cmd
    }
}

extension Codec {
    static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func dateString(daysAgo: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date())
    }
}

enum Shell {
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape for an AppleScript string literal.
    static func appleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum TerminalApp: String, CaseIterable, Identifiable {
    case ghostty, terminal
    var id: String { rawValue }
    static let storageKey = "terminalApp"

    var title: String { self == .ghostty ? "Ghostty" : "Terminal" }
    var bundleID: String { self == .ghostty ? "com.mitchellh.ghostty" : "com.apple.Terminal" }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    static var selected: TerminalApp {
        TerminalApp(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .ghostty
    }

    /// Selected app, or Terminal if Ghostty isn't installed.
    static var effective: TerminalApp {
        selected == .ghostty && !TerminalApp.ghostty.isInstalled ? .terminal : selected
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    static let storageKey = "appearance"

    var title: String {
        switch self {
        case .system: "Как в системе"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    @MainActor static func apply(_ a: Appearance) {
        switch a {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct EnqueueAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// Non-nil: the alert offers «Добавить»; nil — it's just an error.
    var confirm: (() -> Void)?
}
