import Darwin
import Foundation

/// The app's own tmux server: its own socket and no user config, so other sessions and settings are never touched.
/// All calls block (up to `timeout`): never on the main thread.
public struct Tmux: Sendable {
    public struct Session: Sendable, Equatable {
        public let id: UUID
        public let job: UUID?
        public let kind: String
        /// nil = interactive shell.
        public let command: String?
        public let folder: String

        public init(id: UUID, job: UUID?, kind: String, command: String?, folder: String) {
            self.id = id; self.job = job; self.kind = kind; self.command = command; self.folder = folder
        }
    }

    /// "tmux failed" is not "no session": a live claude must not be taken for a finished one.
    public enum State: Sendable, Equatable { case alive, gone, unknown(String) }
    public enum Listing: Sendable, Equatable { case sessions([Session]), unknown(String) }

    public let binary: String
    public let socket: String
    var timeout: TimeInterval = 5

    /// nil when the socket path doesn't fit into sockaddr_un (103 bytes and the final zero).
    public init?(binary: String, socket: String) {
        guard socket.utf8.count <= 103 else { return nil }
        self.binary = binary
        self.socket = socket
    }

    /// An app started from Finder has no Homebrew in PATH.
    public static func find(dirs: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"],
                            path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String? {
        (dirs + path.split(separator: ":").map(String.init)).lazy
            .filter { $0.hasPrefix("/") }
            .map { $0 + "/tmux" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func name(_ id: UUID) -> String { "tt-" + id.uuidString }
    /// "=": otherwise tmux matches by prefix and may take another session. ":" — a session where a pane is expected.
    static func target(_ id: UUID) -> String { "=" + name(id) + ":" }

    // MARK: Arguments

    var base: [String] { ["-S", socket, "-f", "/dev/null", "-u"] }

    public func attachArgs(_ id: UUID) -> [String] { base + ["attach-session", "-t", "=" + Self.name(id)] }

    /// For the user's terminal, also when that one runs inside tmux.
    public func attachCommand(_ id: UUID) -> String {
        "TMUX= " + ([binary] + attachArgs(id)).map(Self.quote).joined(separator: " ")
    }

    static func quote(_ s: String) -> String {
        let safe = !s.isEmpty && s.utf8.allSatisfy { b in
            (0x61...0x7A).contains(b) || (0x41...0x5A).contains(b) || (0x30...0x39).contains(b) || "/._-".utf8.contains(b)
        }
        return safe ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// tmux takes a trailing ";" of an argument for its command separator.
    static func escaped(_ arg: String) -> String { arg.hasSuffix(";") ? String(arg.dropLast()) + #"\;"# : arg }

    /// Labels are base64: any text survives tmux formats and the separator.
    private static func encode(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
    private static func decode(_ s: String) -> String? { Data(base64Encoded: s).map { String(decoding: $0, as: UTF8.self) } }

    func createArgs(_ s: Session, program: [String], cols: Int, rows: Int) -> [String] {
        var a = base + ["start-server"]
        func then(_ cmd: String...) { a += [";"] + cmd }
        then("set-option", "-g", "status", "off")
        then("set-option", "-g", "mouse", "on")
        then("set-option", "-g", "history-limit", "10000")
        then("set-option", "-g", "default-terminal", "screen-256color")
        then("set-option", "-s", "escape-time", "10")
        then("set-option", "-s", "terminal-overrides[90]", "xterm-256color:Tc")
        a += [";", "new-session", "-d", "-s", Self.name(s.id), "-x", "\(max(cols, 10))", "-y", "\(max(rows, 4))",
              // A format: "#" is doubled.
              "-c", Self.escaped(s.folder.replacingOccurrences(of: "#", with: "##"))] + program.map(Self.escaped)
        let labels = ["@tt_job": s.job?.uuidString ?? "", "@tt_kind": s.kind,
                      "@tt_command": Self.encode(s.command ?? ""), "@tt_folder": Self.encode(s.folder)]
        for (k, v) in labels.sorted(by: { $0.key < $1.key }) { then("set-option", "-t", Self.target(s.id), k, v) }
        return a
    }

    static let listFormat = "#{session_name}|#{@tt_job}|#{@tt_kind}|#{@tt_command}|#{@tt_folder}"

    static func parse(_ out: String) -> [Session] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5, f[0].hasPrefix("tt-"), let id = UUID(uuidString: String(f[0].dropFirst(3))),
                  let command = decode(f[3]), let folder = decode(f[4]) else { return nil }
            return Session(id: id, job: UUID(uuidString: f[1]), kind: f[2], command: command.isEmpty ? nil : command, folder: folder)
        }
    }

    static func noServer(_ err: String) -> Bool {
        err.contains("no server running on")
            || err.contains("error connecting to") && (err.contains("(No such file or directory)") || err.contains("(Connection refused)"))
    }

    private static func noSession(_ err: String) -> Bool { noServer(err) || err.contains("can't find session") }
    /// The server was just exiting after its last session.
    private static func exiting(_ err: String) -> Bool { err.contains("server exited") || err.contains("lost server") }

    // MARK: Calls

    /// Separate from attaching: the server must not become a descendant of the tab's `PtyProcess`.
    /// nil = created, otherwise what went wrong.
    public func create(_ s: Session, program: [String], environment: [String: String], cols: Int, rows: Int) -> String? {
        try? FileManager.default.createDirectory(atPath: (socket as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let args = createArgs(s, program: program, cols: cols, rows: rows)
        var r = run(args, environment: environment)
        for _ in 0..<3 where !r.ok && Self.exiting(r.err) {
            usleep(200_000)
            r = run(args, environment: environment)
        }
        return r.ok ? nil : r.message
    }

    public func state(_ id: UUID) -> State {
        let args = base + ["has-session", "-t", "=" + Self.name(id)]
        var r = run(args)
        for _ in 0..<3 where !r.ok && Self.exiting(r.err) {
            usleep(200_000)
            r = run(args)
        }
        if r.ok { return .alive }
        return Self.noSession(r.err) || !Self.listening(socket) ? .gone : .unknown(r.message)
    }

    public func list() -> Listing {
        let r = run(base + ["list-sessions", "-F", Self.listFormat])
        if r.ok { return .sessions(Self.parse(r.out)) }
        return Self.noServer(r.err) || !Self.listening(socket) ? .sessions([]) : .unknown(r.message)
    }

    /// The session now belongs to another job.
    public func setJob(_ id: UUID, _ job: UUID) {
        _ = run(base + ["set-option", "-t", Self.target(id), "@tt_job", job.uuidString])
    }

    /// Ends this session and everything started in it; blocks until it is gone (SIGKILL after `PtyProcess.grace`).
    /// nil = gone, otherwise what went wrong. Never `kill-server`.
    public func kill(_ id: UUID) -> String? {
        let panes = run(base + ["list-panes", "-s", "-t", Self.target(id), "-F", "#{pane_pid}"])
        let roots = panes.ok ? panes.out.split(separator: "\n").compactMap { pid_t($0) } : []
        let all = ProcessTree.snapshot()
        var ids = roots.reduce(into: Set<ProcessTree.ID>()) { $0.formUnion(ProcessTree.members(of: $1, in: all)) }
        let r = run(base + ["kill-session", "-t", "=" + Self.name(id)])
        guard r.ok || Self.noSession(r.err) || Self.exiting(r.err) || !Self.listening(socket) else { return r.message }
        ProcessTree.signal(ids, SIGHUP, SIGCONT)
        let deadline = Date().addingTimeInterval(PtyProcess.grace)
        while !ids.isEmpty, Date() < deadline {
            usleep(30_000)
            // Started meanwhile by the ones that are going.
            let now = ProcessTree.snapshot()
            ids = ids.intersection(now.map(\.id))
            for i in ids { ids.formUnion(ProcessTree.members(of: i.pid, in: now)) }
        }
        ProcessTree.signal(ids, SIGKILL)
        return nil
    }

    /// Somebody listens on the socket: sessions may be alive even when there is no tmux binary to ask.
    public static func listening(_ socket: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        guard socket.utf8.count < MemoryLayout.size(ofValue: a.sun_path) else { return false }
        withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: socket.utf8) }
        return withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
    }

    private struct Output {
        let ok: Bool, out: String, err: String
        var message: String {
            let t = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "tmux завершился с ошибкой" : t
        }
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    private func run(_ args: [String], environment: [String: String]? = nil) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        var env = environment ?? ProcessInfo.processInfo.environment
        for k in ["TMUX", "TMUX_PANE"] { env.removeValue(forKey: k) }
        p.environment = env
        // The server inherits it: must not hold a worktree.
        p.currentDirectoryURL = URL(fileURLWithPath: "/")
        let out = Pipe(), err = Pipe(), outBox = Box(), errBox = Box()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return Output(ok: false, out: "", err: error.localizedDescription) }
        let eof = DispatchGroup()
        for (pipe, box) in [(out, outBox), (err, errBox)] {
            OwnThread.start(group: eof) { box.data = pipe.fileHandleForReading.readDataToEndOfFile() }
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            Darwin.kill(p.processIdentifier, SIGKILL)
            return Output(ok: false, out: "", err: "tmux не ответил за \(Int(timeout)) с")
        }
        guard eof.wait(timeout: .now() + 2) == .success else { return Output(ok: false, out: "", err: "tmux не закрыл вывод") }
        return Output(ok: p.terminationReason == .exit && p.terminationStatus == 0,
                      out: String(decoding: outBox.data, as: UTF8.self), err: String(decoding: errBox.data, as: UTF8.self))
    }
}
