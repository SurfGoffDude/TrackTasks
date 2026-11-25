import AppKit
import SwiftTerm
import TrackTasksCore

/// One tab: a terminal view with its process. Lives independently of the card being on screen.
@Observable @MainActor
final class TerminalTab: Identifiable {
    enum Kind: String { case shell, claude, command }

    let id: UUID
    let kind: Kind
    let folder: URL
    /// nil = interactive shell.
    let command: String?
    private(set) var title: String
    /// Exit code; nil while running.
    private(set) var exitCode: Int32?
    private(set) var error: String?
    @ObservationIgnored let view: TerminalScreen
    @ObservationIgnored private(set) var pty: PtyProcess?

    /// The program lives in this tmux session; `pty` is only a client showing it.
    let tmux: Tmux?
    /// Why the client isn't connected; the session is (or may be) alive.
    private(set) var detached: String?
    /// Waiting for tmux.
    private(set) var busy = false
    /// The session exists as far as we know.
    @ObservationIgnored private var created = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var job: UUID?
    /// tmux calls of this tab, in order: closing during creation still ends the session.
    @ObservationIgnored private lazy var work = DispatchQueue(label: "TrackTasks.tmux", qos: .userInitiated)

    /// An unanswered tmux counts as running.
    var isRunning: Bool { exitCode == nil && error == nil }

    convenience init(kind: Kind, folder: URL, command: String?, job: UUID, tmux: Tmux?) {
        self.init(id: UUID(), kind: kind, folder: folder, command: command, job: job, tmux: tmux, created: false)
    }

    /// A session that outlived the app.
    convenience init?(_ s: Tmux.Session, job: UUID, tmux: Tmux) {
        guard let kind = Kind(rawValue: s.kind) else { return nil }
        self.init(id: s.id, kind: kind, folder: URL(fileURLWithPath: s.folder), command: s.command, job: job, tmux: tmux, created: true)
        // Found by its folder.
        if s.job != job { moved(to: job) }
    }

    private init(id: UUID, kind: Kind, folder: URL, command: String?, job: UUID, tmux: Tmux?, created: Bool) {
        self.id = id
        self.job = job
        self.tmux = tmux
        self.created = created
        self.kind = kind
        self.folder = folder
        self.command = command
        title = switch kind {
        case .shell: "Shell"
        case .claude: "Claude"
        case .command: command ?? "Процесс"
        }
        view = TerminalScreen(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
        view.terminalDelegate = view
        view.forwardsWheel = tmux != nil
        start()
    }

    /// Also reconnects to a tmux session.
    func start() {
        if let tmux { return startSession(tmux) }
        guard pty == nil || !isRunning else { return }
        exitCode = nil
        error = nil
        let program = program
        let size = view.getTerminal()
        do {
            let p = try PtyProcess(
                executable: program[0], args: Array(program.dropFirst()), environment: Self.environment, cwd: folder.path, cols: size.cols, rows: size.rows,
                onData: { [weak view] bytes in MainActor.assumeIsolated { view?.feed(byteArray: bytes[...]) } },
                onExit: { [weak self] code in MainActor.assumeIsolated { self?.ended(code) } })
            pty = p
            view.pty = p
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Interactive: PATH and aliases from the user's shell config, as in their terminal. Tests pass their own shell.
    static var shell: () -> [String] = { [loginShell, "-l", "-i"] }
    private var program: [String] { Self.shell() + (command.map { ["-c", $0] } ?? []) }

    private func ended(_ code: Int32) {
        exitCode = code
        resetScreen("завершено, код \(code)")
    }

    private func resetScreen(_ note: String) {
        // Modes a killed program leaves behind: alternate screen, mouse, hidden cursor, bracketed paste.
        view.feed(text: "\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?25h\u{1b}[0m\r\n[\(note)]\r\n")
    }

    // MARK: tmux

    private func startSession(_ tmux: Tmux) {
        guard !busy, !closed, pty == nil else { return }
        busy = true
        error = nil
        exitCode = nil
        detached = nil
        let session = created ? nil : Tmux.Session(id: id, job: job, kind: kind.rawValue, command: command, folder: folder.path)
        let program = program, env = Self.environment, size = view.getTerminal(), id = id
        let cols = size.cols, rows = size.rows
        work.async { [weak self] in
            let failure = session.flatMap { tmux.create($0, program: program, environment: env, cols: cols, rows: rows) }
            // Created after a timeout, too.
            let state: Tmux.State = session != nil && failure == nil ? .alive : tmux.state(id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    self.busy = false
                    switch state {
                    case .alive:
                        self.created = true
                        self.attach(tmux)
                    case .gone:
                        self.created = false
                        if let failure { self.error = failure } else { self.exitCode = 0; self.resetScreen("завершено") }
                    case .unknown(let why):
                        self.created = true
                        self.detached = failure ?? why
                    }
                }
            }
        }
    }

    private func attach(_ tmux: Tmux) {
        let size = view.getTerminal()
        var env = Self.environment
        for k in ["TMUX", "TMUX_PANE"] { env.removeValue(forKey: k) }
        do {
            let p = try PtyProcess(
                executable: tmux.binary, args: tmux.attachArgs(id), environment: env, cwd: "/", cols: size.cols, rows: size.rows,
                onData: { [weak view] bytes in MainActor.assumeIsolated { view?.feed(byteArray: bytes[...]) } },
                onExit: { [weak self] _ in MainActor.assumeIsolated { self?.clientEnded(tmux) } })
            pty = p
            view.pty = p
        } catch {
            detached = error.localizedDescription
        }
    }

    /// The program ended or the user pressed Ctrl-B d: only tmux knows.
    private func clientEnded(_ tmux: Tmux) {
        pty = nil
        view.pty = nil
        guard !closed else { return }
        busy = true
        let id = id
        work.async { [weak self] in
            let state = tmux.state(id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    self.busy = false
                    switch state {
                    case .gone:
                        self.created = false
                        self.exitCode = 0
                        self.resetScreen("завершено")
                    case .alive:
                        self.detached = "Сессия tmux работает, вкладка от неё отключена"
                        self.resetScreen("отключено")
                    case .unknown(let why):
                        self.detached = "tmux не отвечает: \(why)"
                        self.resetScreen("отключено")
                    }
                }
            }
        }
    }

    func moved(to new: UUID) {
        job = new
        guard let tmux else { return }
        let id = id
        work.async { tmux.setJob(id, new) }
    }

    /// Ends the session; `failed` — tmux didn't, the tab is usable again.
    func endSession(in group: DispatchGroup, failed: @escaping @MainActor (String) -> Void) {
        guard let tmux, isRunning else { return }
        closed = true
        let id = id
        work.async(group: group) {
            guard let why = tmux.kill(id) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.closed = false
                    self.busy = false
                    self.created = true
                    self.detached = "tmux не завершил сессию: \(why)"
                    failed(why)
                }
            }
        }
    }

    private static var loginShell: String {
        if let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell {
            let path = String(cString: s)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "TERM_SESSION_ID", "COLUMNS", "LINES"] { env.removeValue(forKey: k) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "TrackTasks"
        // An app started from Finder has no locale: without it programs don't print UTF-8.
        if !["LC_ALL", "LC_CTYPE", "LANG"].contains(where: { env[$0]?.uppercased().contains("UTF-8") == true }) {
            env.removeValue(forKey: "LC_ALL")
            env["LANG"] = "en_US.UTF-8"
            env["LC_CTYPE"] = "en_US.UTF-8"
        }
        return env
    }
}

/// SwiftTerm's screen; the process is `PtyProcess`, not SwiftTerm's LocalProcess (it signals only the shell).
final class TerminalScreen: TerminalView, TerminalViewDelegate {
    var pty: PtyProcess?
    /// The wheel goes to tmux: SwiftTerm only scrolls its own buffer, empty under tmux.
    var forwardsWheel = false
    private var wheelMonitor: Any?
    private var wheelRest: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = wheelMonitor { NSEvent.removeMonitor(m); wheelMonitor = nil }
        guard window != nil, forwardsWheel else { return }
        // `scrollWheel` of SwiftTerm isn't open for overriding.
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.forwardWheel(event) ?? false } ? nil : event
        }
    }

    /// True = sent to the program.
    private func forwardWheel(_ event: NSEvent) -> Bool {
        guard let pty, let window, event.window === window, event.scrollingDeltaY != 0,
              let hit = window.contentView?.superview?.hitTest(event.locationInWindow) ?? window.contentView?.hitTest(event.locationInWindow),
              hit === self || hit.isDescendant(of: self) else { return false }
        let t = getTerminal()
        guard t.mouseMode != .off, bounds.width > 0, bounds.height > 0 else { return false }
        wheelRest += event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 30 : 1)
        // A mouse's slow notch is less than a line.
        if !event.hasPreciseScrollingDeltas, abs(wheelRest) < 1 { wheelRest = event.scrollingDeltaY > 0 ? 1 : -1 }
        let steps = Int(wheelRest)
        wheelRest -= CGFloat(steps)
        let p = convert(event.locationInWindow, from: nil)
        let x = min(max(Int(p.x / bounds.width * CGFloat(t.cols)), 0), t.cols - 1) + 1
        let fromTop = isFlipped ? p.y : bounds.height - p.y
        let y = min(max(Int(fromTop / bounds.height * CGFloat(t.rows)), 0), t.rows - 1) + 1
        let code = "\u{1b}[<\(steps > 0 ? 64 : 65);\(x);\(y)M"
        pty.write(Array(String(repeating: code, count: min(abs(steps), 10)).utf8))
        return true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            func fixed(_ c: NSColor) -> NSColor { c.usingColorSpace(.deviceRGB) ?? c }
            nativeForegroundColor = fixed(.textColor)
            nativeBackgroundColor = fixed(.textBackgroundColor)
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { pty?.write(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { pty?.resize(cols: newCols, rows: newRows) }
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    /// The link comes from program output: only web pages.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        NSWorkspace.shared.open(url)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Terminal tabs of all jobs.
@Observable @MainActor
final class Terminals {
    static let shared = Terminals()
    static let embeddedKey = "terminalInCard"
    static let tmuxKey = "terminalTmux"
    nonisolated static var tmuxSocket: String {
        JobQueue.storeURL.deletingLastPathComponent().appendingPathComponent("tmux.sock").path
    }
    /// nil = no tmux on this Mac (or the socket path is too long): the mode is hidden.
    nonisolated static func installedTmux() -> Tmux? { Tmux.find().flatMap { Tmux(binary: $0, socket: tmuxSocket) } }
    /// Settings → «Терминал задачи»: in the card (default) or in the external app.
    static var embedded: Bool { UserDefaults.standard.object(forKey: embeddedKey) as? Bool ?? true }

    private(set) var tabs: [UUID: [TerminalTab]] = [:]
    var selected: [UUID: UUID] = [:]
    /// Jobs whose panel is open.
    var shown: Set<UUID> = []
    @ObservationIgnored var onUsed: (() -> Void)?
    /// Closed tabs whose processes are still being killed.
    @ObservationIgnored private var closing: [UUID: PtyProcess] = [:]

    /// Sessions of earlier runs are being read: any job may turn out to have a live claude.
    private(set) var restoring = false
    /// tmux didn't answer at launch: nobody knows which jobs have live sessions.
    private(set) var restoreFailure: String?
    /// Live sessions whose job isn't in the queue (it may have failed to load): ended only by the user.
    private(set) var orphans: [Tmux.Session] = []
    @ObservationIgnored private var ended: Set<UUID> = []
    @ObservationIgnored private let killing = DispatchGroup()
    @ObservationIgnored private var restoreJobs: (() -> [Job])?
    /// Tests: their own server.
    @ObservationIgnored private let ownTmux: Tmux?

    /// Where new shells and claude go; nil = as without tmux.
    private var tmuxForNewTabs: Tmux? {
        ownTmux ?? (UserDefaults.standard.bool(forKey: Self.tmuxKey) ? Self.installedTmux() : nil)
    }

    init(tmux: Tmux? = nil) {
        ownTmux = tmux
        guard tmux == nil else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let t = Terminals.shared
                // Of a tmux tab that's only the client; its session stays.
                PtyProcess.terminateAndWait(t.tabs.values.joined().filter(\.isRunning).compactMap(\.pty) + Array(t.closing.values))
                // Sessions of just closed tabs.
                _ = t.killing.wait(timeout: .now() + 5)
            }
        }
    }

    func tabs(_ job: Job) -> [TerminalTab] { tabs[job.id] ?? [] }

    func current(_ job: Job) -> TerminalTab? {
        let all = tabs(job)
        return all.first { $0.id == selected[job.id] } ?? all.last
    }

    /// Interactive claude works in this job's session.
    func claudeRunning(_ job: Job) -> Bool {
        restoring || (restoreFailure != nil && job.terminalUsed) || tabs(job).contains { $0.kind == .claude && $0.isRunning }
    }

    // MARK: Sessions of earlier runs

    /// Once at launch, also when the mode is off now. `claudeRunning` is true for every job until `then`.
    func restore(_ jobs: @escaping () -> [Job], then: @escaping @MainActor () -> Void) {
        restoreJobs = jobs
        restoring = true
        let own = ownTmux
        Task.detached(priority: .userInitiated) {
            // Without tmux: a listening socket still means unknown sessions.
            let tmux = own ?? Self.installedTmux() ?? Tmux(binary: "/nonexistent/tmux", socket: Self.tmuxSocket)
            let found = tmux?.list() ?? .sessions([])
            await MainActor.run {
                self.restoring = false
                self.adopt(found, tmux, jobs())
                then()
            }
        }
    }

    /// Settings → «Проверить снова».
    func restoreAgain() {
        guard !restoring, let restoreJobs else { return }
        restore(restoreJobs) {}
    }

    private func adopt(_ found: Tmux.Listing, _ tmux: Tmux?, _ jobs: [Job]) {
        guard case .sessions(let all) = found, let tmux else {
            if case .unknown(let why) = found {
                restoreFailure = why
                StorageIssues.shared.report("Не удалось узнать, какие сессии tmux работают: \(why). Слияние и удаление веток, где открывали терминал, заблокировано — «Настройки → Терминал → Проверить снова».")
            }
            return
        }
        restoreFailure = nil
        orphans = []
        let known = Set(tabs.values.joined().map(\.id)).union(ended)
        for s in all where !known.contains(s.id) {
            // By folder: the label may be older than a retry of the job.
            let owner = jobs.first { $0.id == s.job }
                ?? jobs.last { $0.worktree?.path.standardizedFileURL.path == URL(fileURLWithPath: s.folder).standardizedFileURL.path }
            guard let owner, let t = TerminalTab(s, job: owner.id, tmux: tmux) else { orphans.append(s); continue }
            tabs[owner.id, default: []].append(t)
            markUsed(owner)
        }
    }

    func endOrphan(_ s: Tmux.Session) {
        orphans.removeAll { $0.id == s.id }
        guard let tmux = ownTmux ?? Self.installedTmux() else { return }
        DispatchQueue.global(qos: .userInitiated).async(group: killing) {
            guard let why = tmux.kill(s.id) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.orphans.append(s)
                StorageIssues.shared.report("tmux не завершил сессию: \(why)")
            } }
        }
    }

    func open(_ job: Job, _ kind: TerminalTab.Kind, command: String? = nil) {
        guard !ContainerStore.shared.isContainer(job.runDir) else { return }
        let t = TerminalTab(kind: kind, folder: job.runDir, command: command, job: job.id,
                            tmux: kind == .command ? nil : tmuxForNewTabs)
        tabs[job.id, default: []].append(t)
        selected[job.id] = t.id
        shown.insert(job.id)
        markUsed(job)
    }

    /// Also for the external app: merge then checks the worktree for edits made by hand.
    func markUsed(_ job: Job) {
        guard !job.terminalUsed else { return }
        job.terminalUsed = true
        onUsed?()
    }

    func close(_ tab: TerminalTab, of id: UUID) {
        guard var list = tabs[id], let i = list.firstIndex(where: { $0.id == tab.id }) else { return }
        list.remove(at: i)
        tabs[id] = list.isEmpty ? nil : list
        if selected[id] == tab.id { selected[id] = list.isEmpty ? nil : list[min(i, list.count - 1)].id }
        if list.isEmpty { shown.remove(id) }
        if tab.tmux != nil, tab.isRunning {
            ended.insert(tab.id)
            tab.endSession(in: killing) { [weak self] why in
                // Still alive: merge and the like must know.
                self?.ended.remove(tab.id)
                self?.tabs[id, default: []].append(tab)
                StorageIssues.shared.report("tmux не завершил сессию: \(why)")
            }
        }
        guard tab.isRunning, let p = tab.pty else { return }
        p.terminate()
        // Kept until surely gone, so quitting right after closing doesn't leave them.
        let key = tab.id
        closing[key] = p
        Task {
            try? await Task.sleep(for: .seconds(5))
            closing[key] = nil
        }
    }

    /// The job or its folder is gone.
    func closeAll(_ id: UUID) {
        for t in tabs[id] ?? [] { close(t, of: id) }
        shown.remove(id)
    }

    /// A retry replaces the job.
    func move(from dir: URL, _ old: Job, to new: Job) {
        // The folder of the new one may differ (no worktree yet).
        guard dir == new.runDir else { return closeAll(old.id) }
        tabs[new.id] = tabs.removeValue(forKey: old.id)
        selected[new.id] = selected.removeValue(forKey: old.id)
        if shown.remove(old.id) != nil { shown.insert(new.id) }
        for t in tabs(new) { t.moved(to: new.id) }
    }
}

extension JobQueue {
    /// Why claude can't be resumed in the card's terminal now: one session and one folder — one agent. nil = can.
    func terminalClaudeBlocked(_ job: Job) -> String? {
        if Terminals.shared.claudeRunning(job) { return "диалог уже открыт во вкладке" }
        if job.isActive || hasActiveChild(job) { return "агент сейчас работает" }
        if job.worktreeBusy { return "с веткой сейчас что-то делают" }
        return nil
    }
}
