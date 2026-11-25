import Foundation
import TrackTasksCore

/// One turn on a server. The connection may break at any point after the start: the work there goes on.
@MainActor
final class SSHRun: RemoteAgentRun {
    var onEvent: ((AgentEvent) -> Void)?
    var onExit: ((AgentRunResult) -> Void)?
    var onPermission: ((AgentPermission) -> Void)?
    var onTurnStarted: (() -> Void)?
    var onOffset: ((Int) -> Void)?
    var onReturned: (() -> Void)?

    private let transport: RemoteTransport
    private let dataDir: URL
    private let cleanup: RemoteCleanup
    private var stream = ClaudeStream()
    private var worker: RemoteWorker?
    /// Answered before the app was restarted.
    private var answered: Set<String> = []

    init(transport: RemoteTransport, dataDir: URL, cleanup: RemoteCleanup) {
        self.transport = transport
        self.dataDir = dataDir
        self.cleanup = cleanup
    }

    func start(_ request: AgentRequest) throws {
        guard let remote = request.remote else { throw RemoteError.failed("Не задан сервер") }
        if let p = remote.run.problem { throw RemoteError.failed(p) }
        let w = RemoteWorker(request, remote, transport: transport, dir: dataDir.appendingPathComponent(remote.run.id), cleanup: cleanup)
        let shown = remote.attach ? remote.run.offset : 0
        // No Limits and no AppSessions: the server may use another account, its sessions aren't on this Mac.
        let stream = ClaudeStream(resume: request.resume, cwd: request.cwd.path)
        stream.stats.program = "claude на \(remote.run.server.host)"
        stream.onEvent = { [weak self, weak stream] e in
            guard let self, let stream, stream.consumed > shown else { return }
            onEvent?(e)
        }
        stream.onPermission = { [weak self] r in
            guard let self, !answered.contains(r.id) else { return }
            if let onPermission { onPermission(r) } else { respond(r, allow: false, always: false) }
        }
        stream.onSend = { [weak self] m in
            guard let self, let id = (m["response"] as? [String: Any])?["request_id"] as? String, !answered.contains(id) else { return }
            worker?.send(m)
        }
        // Also for lines shown before a restart: it may have come before this was saved.
        stream.onTurnStarted = { [weak self] in self?.onTurnStarted?() }
        stream.onResult = { [weak self] in self?.worker?.sendEnd() }
        stream.onLine = { [weak self, weak stream] in
            guard let self, let stream, stream.consumed > shown else { return }
            onOffset?(stream.consumed)
        }
        self.stream = stream
        worker = w

        w.note = { [weak self] text in Self.main { self?.onEvent?(.tool(text)) } }
        w.answered = { [weak self] ids in Self.mainSync { self?.answered = ids } }
        w.output = { [weak self] d in Self.main { self?.stream.consume(d) } }
        // Strong self: the result must come even if the owner dropped the run.
        w.returned = { Self.mainSync { self.onReturned?() } }
        w.ended = { end in
            Self.main {
                var r = self.stream.stats
                end(&r)
                self.worker = nil
                self.onExit?(r)
                self.onExit = nil
            }
        }
        w.begin()
    }

    nonisolated private static func main(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }
    nonisolated private static func mainSync(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    func respond(_ r: AgentPermission, allow: Bool, always: Bool) {
        if let m = stream.answer(r.id, allow: allow, always: always) { worker?.send(m) }
    }

    func stop() { worker?.stop() }
    func killTree() { worker?.stop() }
}

/// The steps of a run, on its own queue.
private final class RemoteWorker: @unchecked Sendable {
    typealias End = @Sendable (inout AgentRunResult) -> Void

    var note: ((String) -> Void)?
    var output: ((Data) -> Void)?
    var answered: ((Set<String>) -> Void)?
    var returned: (() -> Void)?
    var ended: ((@escaping End) -> Void)?

    private let request: AgentRequest
    private let remote: AgentRemote
    private let dir: URL
    private let cleanup: RemoteCleanup
    private let link: RemoteLink
    private let sendLink: RemoteLink
    private let queue = DispatchQueue(label: "ssh.run", qos: .userInitiated)
    private let sendQueue = DispatchQueue(label: "ssh.send", qos: .userInitiated)

    private let cond = NSCondition()
    private var stopAsked: Date?
    /// The connection may be cut to stop sooner.
    private var interruptible = true
    private var over = false
    private var nextInput = 2

    private var outage = false
    private var delay: TimeInterval = 2
    private var received = 0
    /// The run may exist on the server.
    private var begun = false
    private var stopSent = false

    /// How long a stop waits for the connection.
    private static let stopGrace: TimeInterval = 20

    init(_ request: AgentRequest, _ remote: AgentRemote, transport: RemoteTransport, dir: URL, cleanup: RemoteCleanup) {
        self.request = request
        self.remote = remote
        self.dir = dir
        self.cleanup = cleanup
        link = RemoteLink(remote.run.server, transport)
        sendLink = RemoteLink(remote.run.server, transport)
    }

    private var run: String { remote.run.id }
    private var coding: Bool { request.access == .coding }
    private var folder: URL { request.cwd }
    private var taskBase: URL { dir.appendingPathComponent("task-base.md") }

    func begin() { queue.async { self.drive() } }

    func stop() {
        cond.lock()
        let cut = interruptible && stopAsked == nil
        if stopAsked == nil { stopAsked = Date() }
        cond.broadcast()
        cond.unlock()
        if cut { link.interrupt() }
    }

    private var stopping: Bool { cond.withLock { stopAsked != nil } }
    private var gaveUp: Bool { cond.withLock { stopAsked.map { -$0.timeIntervalSinceNow > Self.stopGrace } ?? false } }
    private func checkStop() throws { if stopping { throw RemoteError.interrupted } }

    // MARK: Steps

    private func drive() {
        // Until the server says otherwise.
        begun = remote.attach
        do {
            var st: RemoteState?
            if remote.attach { st = try patiently { try self.state() } }
            begun = st?.started == true
            if !begun {
                do { try launch() } catch RemoteError.interrupted where begun {
                    // Perhaps started: `watch` stops it there.
                }
            }
            try watch()
            try collect()
        } catch {
            finish(error)
        }
    }

    /// nil = the server doesn't know the run.
    private func state() throws -> RemoteState? {
        do { return RemoteState(try link.call(["state", run])) } catch RemoteError.code(RemoteRunner.noRun, _) { return nil }
    }

    private func launch() throws {
        try checkStop()
        var info: RemoteInfo?
        for attempt in 1...3 {
            do { info = try RemoteInfo(link.call(["check", remote.run.server.claude])); break } catch let e as RemoteError {
                guard e.isOutage, attempt < 3 else { throw RemoteInfo.explain(e) }
                pause(3)
                try checkStop()
            }
        }
        guard let info else { throw RemoteError.failed("Нет ответа сервера") }
        try RemoteTransfer.check(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let work = "\(info.root)/work/\(remote.run.work)"
        let ownFolder = folder.standardizedFileURL.path != remote.main.standardizedFileURL.path
        let snap = try RemoteTransfer.snapshot(folder, run: run, untracked: ownFolder)
        let known = try patiently { try self.link.call(["repo", self.remote.run.project]) }
        try checkStop()
        let bundle = dir.appendingPathComponent("code.bundle")
        try? FileManager.default.removeItem(at: bundle)
        try RemoteTransfer.bundle(folder, run: run, known: known.split(whereSeparator: \.isNewline).map(String.init), to: bundle)
        let size = (try? FileManager.default.attributesOfItem(atPath: bundle.path)[.size] as? Int) ?? nil
        note?("Код на сервер: " + ByteCountFormatter.string(fromByteCount: Int64(size ?? 0), countStyle: .file))
        try upload(bundle, "code.bundle")
        try? FileManager.default.removeItem(at: bundle)

        func there(_ s: String) -> String {
            RemotePaths.translate(s, code: folder.path, main: remote.main.path, remoteCode: work + "/code", remoteProject: work + "/project")
        }
        var o = ClaudeOptions(request)
        o.bypassPermissions = false
        let args = ClaudeArgs.run(systemPrompt: there(o.systemPrompt), model: o.model, allowedTools: o.allowedTools, resume: o.resume,
                                  addDirs: [work + "/project"], isolated: o.isolated, tools: o.tools)
        try upload(text: "set -- " + args.map(SSHCommand.quote).joined(separator: " ") + "\n", "argv")
        var vars = "SETUP=\(SSHCommand.quote(remote.setup))\nBRANCH=\(SSHCommand.quote(remote.branch))\n"
        try? FileManager.default.removeItem(at: taskBase)
        if let t = remote.taskPath {
            vars += "TASK=\(SSHCommand.quote(t.lastPathComponent))\n"
            if let d = try? Data(contentsOf: t) {
                try d.write(to: taskBase)
                try upload(taskBase, "task")
            }
        }
        try upload(text: vars, "vars")
        for (name, file) in [("about", "about.md"), ("spec", "spectrack.md")] {
            let u = remote.main.appendingPathComponent(file)
            if let d = try? Data(contentsOf: u) {
                let copy = dir.appendingPathComponent(name)
                try d.write(to: copy)
                try upload(copy, name)
            }
        }
        let first = try ClaudeStream.opening(prompt: there(request.prompt), images: request.images).map { try JSONSerialization.data(withJSONObject: $0) + Data([10]) }.reduce(Data(), +)
        try patiently { try self.put(1, first, self.link) }
        try checkStop()

        // From here on the run may exist, whatever the connection says.
        cleanup.began(remote.run, folder: folder)
        begun = true
        _ = try patiently {
            try self.link.call(["start", self.run, self.remote.run.work, self.remote.run.project, self.coding ? "coding" : "planning",
                                snap.commit, self.remote.run.server.claude])
        }
    }

    /// Events until the runner is done.
    private func watch() throws {
        cleanup.began(remote.run, folder: folder)
        var first = true
        while true {
            do {
                let mark = link.mark
                if stopping, !stopSent {
                    try link.call(["stop", run])
                    stopSent = true
                    note?("Остановлено на сервере, забираю сделанное")
                }
                guard let st = try state(), st.started else { throw RemoteError.failed("Сервер не знает этот запуск: его папка удалена") }
                backOnline()
                if first {
                    first = false
                    cond.withLock { nextInput = st.inputs + 1 }
                    answered?(st.answered)
                    if let d = st.done, remote.attach, incomplete(d) { try link.call(["again", run]) }
                }
                if let d = st.done, received >= d.out, !(remote.attach && incomplete(d)) { return }
                try link.call(["follow", run, String(received)], timeout: nil, since: mark) { [self] d in
                    received += d.count
                    output?(d)
                }
                if let d = try state()?.done, received >= d.out { return }
            } catch RemoteError.interrupted {
                // Told to stop: the loop sends it.
            } catch let e as RemoteError where e.isOutage { try wait(e) } catch RemoteError.code(1, _) { pause(2) }
        }
    }

    /// The runner could not save the result.
    private func incomplete(_ d: RemoteState.Done) -> Bool {
        d.claudeStarted && !d.error.isEmpty
            && (coding && d.bundle == nil || remote.returnsTask && remote.taskPath != nil && d.task == nil)
    }

    private func collect() throws {
        cond.withLock { interruptible = false }
        guard let d = try patiently({ try self.state() })?.done else { throw RemoteError.failed("Сервер не отдал итог запуска") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var problem: String?
        var keep = false, keepRefs = false
        if coding, let f = d.bundle {
            let file = dir.appendingPathComponent("result.bundle")
            try link.download("result.bundle", run: run, expect: f, to: file, retry: wait)
            backOnline()
            let base = try base()
            do {
                let result = try RemoteTransfer.fetch(folder, run: run, bundle: file, base: base.commit)
                switch try RemoteTransfer.apply(folder, run: run, base: base, result: result) {
                case .nothing: break
                case .applied, .already: note?("Правки с сервера возвращены в worktree")
                }
            } catch let e as RemoteTransfer.Changed { problem = e.localizedDescription; keepRefs = true }
            catch let e as RemoteTransfer.Refused { problem = e.localizedDescription + ". Он сохранён в \(RemoteTransfer.resultRef(run))"; keepRefs = true }
        }
        if remote.returnsTask, let t = remote.taskPath, let f = d.task {
            let file = dir.appendingPathComponent("task-server.md")
            try link.download("task.md", run: run, expect: f, to: file, retry: wait)
            backOnline()
            switch try RemoteTransfer.returnTask(t, base: taskBase, remote: file) {
            case .same, .replaced: break
            case .merged: note?("Файл задачи изменился и здесь, и на сервере — правки объединены")
            case .conflict(let u):
                keep = true
                note?("Файл задачи на сервере разошёлся с локальным, локальный не тронут. Версия с сервера: \(u.path)")
            }
        }
        var err = ""
        if d.exit != 0 || !d.error.isEmpty { err = (try? link.call(["fetch", run, "err", "0"])) ?? "" }
        if incomplete(d) {
            // Still on the server: ↻ tries again.
            let text = "Результат остался на сервере: " + d.error
            return end { $0.isError = true; $0.cannotStart = true; $0.resultText = text }
        }
        returned?()
        cleanup.returned(remote.run)
        if !keep { try? FileManager.default.removeItem(at: dir) }
        if !keepRefs { RemoteTransfer.dropRefs(run, in: folder) }
        let failure = problem, tail = err
        end { r in
            r.exitCode = d.exit
            r.stderr += String(tail.suffix(2000))
            r.stopped = d.cancelled
            if let failure {
                r.stopped = false
                r.isError = true
                r.cannotStart = true
                r.resultText = failure
                r.limit = nil
            } else if !d.error.isEmpty, !d.cancelled {
                r.isError = true
                r.cannotStart = !d.claudeStarted
                r.resultText = "Сервер: " + d.error
                r.limit = nil
            }
        }
    }

    private func base() throws -> RemoteTransfer.Snapshot {
        func id(_ s: String) throws -> String {
            let r = Worktrees.git(["rev-parse", "--verify", s], in: folder)
            guard r.ok else { throw RemoteError.failed("Не найден отправленный коммит этого запуска") }
            return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ref = RemoteTransfer.baseRef(run)
        return .init(commit: try id(ref), tree: try id(ref + "^{tree}"))
    }

    private func finish(_ error: Error) {
        let text = RemoteInfo.explain(error).localizedDescription
        let stopped = stopping
        if begun {
            // Nothing is lost: the run is there, ↻ continues watching it.
            if stopped, !stopSent {
                cleanup.stopLater(remote.run)
                note?("Нет связи: остановка на сервере не подтверждена, повторяю в фоне")
            }
            let gaveUp = stopped
            return end { r in
                r.stopped = gaveUp
                r.isError = !gaveUp
                r.cannotStart = true
                r.limit = nil
                r.resultText = text + ". Запуск на сервере не забран: «Повторить» подключится к нему"
            }
        }
        returned?()
        try? FileManager.default.removeItem(at: dir)
        RemoteTransfer.dropRefs(run, in: folder)
        // Files uploaded before the failure.
        if case RemoteError.link = error {} else { cleanup.returned(remote.run) }
        end { r in
            r.stopped = stopped
            r.isError = !stopped
            r.cannotStart = true
            r.resultText = text
        }
    }

    private func end(_ change: @escaping End) {
        cond.lock()
        over = true
        cond.broadcast()
        cond.unlock()
        sendLink.interrupt()
        ended?(change)
        ended = nil
    }

    // MARK: Files

    private func upload(_ file: URL, _ name: String) throws {
        try checkStop()
        try link.upload(file, run: run, name: name, retry: wait)
        backOnline()
    }

    private func upload(text: String, _ name: String) throws {
        let u = dir.appendingPathComponent("up-" + name)
        try Data(text.utf8).write(to: u)
        try upload(u, name)
    }

    private func put(_ n: Int, _ d: Data, _ link: RemoteLink) throws {
        try link.call(["put", run, String(n), String(d.count)], input: .data(d))
    }

    // MARK: Messages to claude

    /// Delivered exactly once: the number is taken by the first message that gets there.
    func send(_ message: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: message) else { return }
        let data = d + Data([10])
        sendQueue.async { [self] in
            retrying {
                let n = cond.withLock { nextInput }
                do {
                    try put(n, data, sendLink)
                    cond.withLock { nextInput = n + 1 }
                } catch RemoteError.code(RemoteRunner.taken, _) {
                    let st = RemoteState(try sendLink.call(["state", run]))
                    cond.withLock { nextInput = st.inputs + 1 }
                    throw RemoteError.link(.noConnection, "")
                }
            }
        }
    }

    func sendEnd() {
        sendQueue.async { [self] in retrying { try sendLink.call(["end", run]) } }
    }

    /// Until it works, the run is over, or the server refuses.
    private func retrying(_ body: () throws -> Void) {
        var delay: TimeInterval = 1
        while !cond.withLock({ over }) {
            do { return try body() } catch let e as RemoteError where e.isOutage {
                pause(delay)
                delay = min(delay * 2, 60)
            } catch {
                note?("Сообщение не дошло до claude на сервере: \(error.localizedDescription)")
                return
            }
        }
    }

    // MARK: Connection

    private func patiently<T>(_ body: () throws -> T) throws -> T {
        while true {
            do {
                let r = try body()
                backOnline()
                return r
            } catch let e as RemoteError where e.isOutage { try wait(e) }
        }
    }

    private func backOnline() {
        delay = 2
        guard outage else { return }
        outage = false
        note?("Связь с сервером восстановлена")
    }

    /// Before the next try. Throws when the run was told to stop and there is no connection to do it.
    private func wait(_ e: RemoteError) throws {
        if gaveUp || (stopping && !begun) { throw RemoteError.interrupted }
        if !outage {
            outage = true
            note?(begun ? "Нет связи, работа на сервере продолжается" : "Нет связи с сервером, повторяю")
        }
        pause(stopping ? 2 : delay)
        delay = min(delay * 2, 60)
        if gaveUp || (stopping && !begun) { throw RemoteError.interrupted }
    }

    /// Ends early when the run is stopped or over.
    private func pause(_ t: TimeInterval) {
        cond.lock()
        defer { cond.unlock() }
        let wasStopping = stopAsked != nil, until = Date().addingTimeInterval(t)
        while !over, (stopAsked != nil) == wasStopping, Date() < until { _ = cond.wait(until: until) }
    }
}
