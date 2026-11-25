import AppKit
import SwiftUI
import TrackTasksCore

/// One running (or finished) dev-server command in a folder: the project's main folder or a job's worktree.
@Observable @MainActor
final class DevServer: Identifiable {
    let id = UUID()
    let folder: URL
    let command: RunCommand
    /// Given to the process as `PORT`.
    let assignedPort: Int
    private(set) var log = ""
    private(set) var detectedPort: Int?
    private(set) var exitCode: Int32?
    private(set) var error: String?
    @ObservationIgnored fileprivate(set) var pty: PtyProcess?

    var isRunning: Bool { pty != nil && exitCode == nil && error == nil }
    /// What the server says it listens on, otherwise the port it was told to use.
    var port: Int { detectedPort ?? assignedPort }
    var url: URL? { URL(string: "http://localhost:\(port)") }

    init(folder: URL, main: URL, command: RunCommand, port: Int, branch: String, failure: String? = nil) {
        self.folder = folder
        self.command = command
        assignedPort = port
        if let failure { error = failure; return }
        var env = ProcessInfo.processInfo.environment
        for k in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "TERM_SESSION_ID", "COLUMNS", "LINES"] { env.removeValue(forKey: k) }
        env["PORT"] = String(port)
        env["TERM"] = "xterm-256color"
        env["TRACKTASKS_MAIN"] = main.path
        env["TRACKTASKS_WORKTREE"] = folder.path
        env["TRACKTASKS_BRANCH"] = branch
        do {
            pty = try PtyProcess(
                executable: "/bin/zsh", args: ["-lc", command.command], environment: env, cwd: folder.path, cols: 200, rows: 50,
                onData: { [weak self] bytes in MainActor.assumeIsolated { self?.append(bytes) } },
                onExit: { [weak self] code in
                    DevServers.ledger.release(port: port)
                    MainActor.assumeIsolated { self?.exitCode = code }
                })
        } catch {
            self.error = error.localizedDescription
            DevServers.ledger.release(port: port)
        }
        if let pty { DevServers.registry.add(pty, folder: folder.path) }
    }

    private func append(_ bytes: [UInt8]) {
        log = RunCommands.trimLog(log + RunCommands.plain(String(decoding: bytes, as: UTF8.self)))
        if detectedPort == nil { detectedPort = RunCommands.port(in: log) }
    }

    func stop() { pty?.terminate() }
}

/// Dev servers of all folders. Processes are also in a lock-protected registry: a worktree is removed from background threads.
@Observable @MainActor
final class DevServers {
    static let shared = DevServers()

    /// Thread-safe list of processes by folder.
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var byFolder: [String: [PtyProcess]] = [:]
        func add(_ p: PtyProcess, folder: String) { lock.withLock { byFolder[folder, default: []].append(p) } }
        func take(folder: String) -> [PtyProcess] { lock.withLock { byFolder.removeValue(forKey: folder) ?? [] } }
        func takeAll() -> [PtyProcess] { lock.withLock { defer { byFolder = [:] }; return byFolder.values.flatMap { $0 } } }
    }
    nonisolated static let registry = Registry()
    /// Ports shared with other copies of the app.
    nonisolated static let ledger = PortLedger()

    private(set) var servers: [String: [DevServer]] = [:]
    static let firstPort = 3000

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            PtyProcess.terminateAndWait(DevServers.registry.takeAll())
            DevServers.ledger.release()
        }
    }

    func servers(in folder: URL) -> [DevServer] { servers[folder.path] ?? [] }
    func isRunning(in folder: URL) -> Bool { servers(in: folder).contains(where: \.isRunning) }

    /// Starts every command not already running in `folder`; each gets its own free `PORT`.
    func start(_ commands: [RunCommand], in folder: URL, main: URL, branch: String = "") {
        // Code of a container runs only in it.
        guard !ContainerStore.shared.isContainer(folder) else { return }
        var list = servers[folder.path] ?? []
        for c in commands where !list.contains(where: { $0.command.name == c.name && $0.isRunning }) {
            list.removeAll { $0.command.name == c.name }
            // The port is reserved in the shared ledger (all servers, all app copies), even before it listens.
            do {
                let port = try Self.ledger.claim(from: Self.firstPort, folder: folder.path, name: c.name)
                list.append(DevServer(folder: folder, main: main, command: c, port: port, branch: branch))
            } catch {
                list.append(DevServer(folder: folder, main: main, command: c, port: 0, branch: branch, failure: error.localizedDescription))
            }
        }
        servers[folder.path] = list
    }

    func stop(in folder: URL) { for s in servers(in: folder) { s.stop() } }

    /// The folder is going away (worktree removed): kill and wait, from any thread.
    nonisolated static func stopAndWait(folder: URL) {
        PtyProcess.terminateAndWait(registry.take(folder: folder.path))
        ledger.release(folder: folder.path)
    }
}

/// ▶ / ■ for a folder, with a popover: commands (approved once), status, port, «Открыть», log.
struct ServerControl: View {
    let folder: URL
    let main: URL
    var branch = ""
    @State private var shown = false

    var body: some View {
        let running = DevServers.shared.isRunning(in: folder)
        Button { shown.toggle() } label: {
            Label(running ? "Dev-сервер запущен" : "Dev-сервер", systemImage: running ? "stop.circle.fill" : "play.circle").labelStyle(.titleAndIcon)
        }
            .buttonStyle(.glass)
            .help(running ? "Dev-сервер запущен" : "Запустить dev-сервер (about.md → run)")
            .popover(isPresented: $shown, arrowEdge: .bottom) { DevServerPanel(folder: folder, main: main, branch: branch) }
    }
}

struct DevServerPanel: View {
    let folder: URL
    let main: URL
    var branch = ""
    /// The task whose server it is: offers «Превью».
    var job: UUID?
    @Environment(\.openWindow) private var openWindow
    /// Read when the panel opens.
    @State private var run: RunCommands.Parsed?

    var body: some View {
        Group {
            if let run { content(run) } else { ProgressView().controlSize(.small).padding(16).frame(width: 460) }
        }
        .onAppear { run = RunCommands.load(projectAt: main) }
    }

    @ViewBuilder
    private func content(_ run: RunCommands.Parsed) -> some View {
        let servers = DevServers.shared
        let list = servers.servers(in: folder)
        VStack(alignment: .leading, spacing: 10) {
            Text("Dev-сервер").font(.headline)
            if run.isEmpty && list.isEmpty {
                Text("В about.md нет поля `run:`. Одна команда: `run: npm run dev`, несколько: `run: {\"web\": \"npm run dev\", \"api\": \"go run .\"}`. Порт придёт в переменной PORT.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !run.isEmpty, !ScriptStore.approvals.isRunApproved(run.field, project: main), !servers.isRunning(in: folder) {
                Text("Команды из about.md запускаются только после подтверждения:").font(.caption).foregroundStyle(.secondary)
                ForEach(run.commands) { c in Text("$ \(c.command)").font(.caption.monospaced()).textSelection(.enabled) }
                Button("Подтвердить и запустить") {
                    var a = ScriptStore.approvals
                    a.approveRun(run.field, project: main)
                    ScriptStore.approvals = a
                    servers.start(run.commands, in: folder, main: main, branch: branch)
                }.buttonStyle(.borderedProminent)
            } else {
                ForEach(list) { s in row(s) }
                HStack {
                    if servers.isRunning(in: folder) {
                        Button("Остановить") { servers.stop(in: folder) }
                    }
                    if !run.isEmpty, run.commands.contains(where: { c in !list.contains { $0.command.name == c.name && $0.isRunning } }) {
                        Button(list.isEmpty ? "Запустить" : "Запустить заново") {
                            servers.start(run.commands, in: folder, main: main, branch: branch)
                        }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func row(_ s: DevServer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(s.isRunning ? Color.green : (s.exitCode == 0 ? Color.secondary : Color.red)).frame(width: 8, height: 8)
                Text(s.command.name).font(.subheadline.weight(.semibold))
                Text(s.isRunning ? "порт \(s.port)" : (s.error ?? "завершён, код \(s.exitCode ?? 0)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if s.isRunning, let job {
                    Button("Превью") { openWindow(id: PreviewView.windowID, value: PreviewTarget(job: job, server: s.id)) }
                        .help("Страница в окне TrackTasks: выбрать элемент и написать агенту")
                }
                if s.isRunning, let u = s.url {
                    Button("Открыть") { NSWorkspace.shared.open(u) }
                }
            }
            ScrollView {
                Text(s.log.isEmpty ? " " : WorktreeScripts.tail(s.log, limit: 4000))
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 110)
            .padding(6)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        }
    }
}
