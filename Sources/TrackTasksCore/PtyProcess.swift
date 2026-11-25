import Darwin
import Foundation

/// A process on its own pseudo-terminal. `terminate` takes down everything started from it, not only the shell.
public final class PtyProcess: @unchecked Sendable {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// How long processes get to exit after SIGHUP before SIGKILL.
    static let grace: TimeInterval = 1.5

    public let pid: pid_t
    private let queue: DispatchQueue
    private let onData: @Sendable ([UInt8]) -> Void
    private let onExit: @Sendable (Int32) -> Void

    private let writer = DispatchQueue(label: "TrackTasks.pty.write")
    private let reader = DispatchGroup()
    private let lock = NSLock()
    // Under `lock`:
    private var fd: Int32
    private var exited = false
    private var reaped = false
    private var terminating = false
    /// Seen at `terminate`: descendants may lose their parent link before they are killed.
    private var tracked: Set<ProcessTree.ID> = []

    /// Callbacks come on `queue`; `onExit` (exit code, 128+N for a signal) once, after the last `onData`.
    public init(executable: String, args: [String], environment: [String: String], cwd: String,
                cols: Int, rows: Int, queue: DispatchQueue = .main,
                onData: @escaping @Sendable ([UInt8]) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        self.queue = queue
        self.onData = onData
        self.onExit = onExit
        var master: Int32 = -1, slave: Int32 = -1
        var size = Self.winsize(cols, rows)
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, &size) == 0 else {
            throw Failure(message: "Не удалось открыть терминал: \(String(cString: strerror(errno)))")
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        defer { close(slave) }

        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        for n: Int32 in 0...2 { posix_spawn_file_actions_adddup2(&actions, slave, n) }
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        // CLOEXEC_DEFAULT: the child must not hold pipes of other running processes.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        // A tty opened by spawn's file actions doesn't become the controlling one (no Ctrl-C, no /dev/tty):
        // the new session's leader opens it itself, then turns into the program.
        let trampoline = ["/bin/sh", "-c", #"exec <>"$0" >&0 2>&0; exec "$@""#, String(cString: name), executable] + args
        var argv: [UnsafeMutablePointer<CChar>?] = trampoline.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", &actions, &attr, &argv, &envp)
        guard rc == 0 else {
            close(master)
            throw Failure(message: "Не удалось запустить \(executable) в \(cwd): \(String(cString: strerror(rc)))")
        }
        self.pid = pid
        fd = master
        Thread.detachNewThread { [self] in waitLoop() }
        reader.enter()
        Thread.detachNewThread { [self] in readLoop(master) }
    }

    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writer.async { [self] in
            // `fd` is closed on this queue only, so it stays valid during a blocked write.
            lock.lock(); let fd = fd; lock.unlock()
            guard fd >= 0 else { return }
            var sent = 0
            while sent < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, bytes.count - sent) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return }
                sent += n
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        var size = Self.winsize(cols, rows)
        _ = ioctl(fd, TIOCSWINSZ, &size)
    }

    /// SIGHUP to everything started here, SIGKILL to what is left after `grace`. Returns at once.
    public func terminate() {
        guard hangUp() else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.grace) { [self] in killLeader() }
    }

    /// For quitting the app: same for all of them, but waits (≤ `grace`) until nothing is left.
    public static func terminateAndWait(_ all: [PtyProcess]) {
        for p in all { p.hangUp() }
        let left = wait(for: all.reduce(into: Set()) { $0.formUnion($1.everything()) })
        ProcessTree.signal(left, SIGKILL)
        // Whatever was started meanwhile.
        for p in all { ProcessTree.signal(p.everything(), SIGKILL) }
    }

    // MARK: Private

    private static func winsize(_ cols: Int, _ rows: Int) -> Darwin.winsize {
        Darwin.winsize(ws_row: UInt16(clamping: max(rows, 1)), ws_col: UInt16(clamping: max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
    }

    /// Live processes of this terminal. The leader's pid is ours until it is reaped, so its session id can't be reused.
    private func everything() -> Set<ProcessTree.ID> {
        let all = ProcessTree.snapshot()
        lock.lock(); defer { lock.unlock() }
        let live = Set(all.map(\.id))
        tracked.formIntersection(live)
        if !reaped { tracked.formUnion(ProcessTree.members(of: pid, in: all)) }
        // Children of tracked ones that moved to their own session.
        for id in tracked { tracked.formUnion(ProcessTree.members(of: id.pid, in: all)) }
        return tracked
    }

    @discardableResult
    private func hangUp() -> Bool {
        lock.lock()
        let first = !terminating && !reaped
        terminating = true
        lock.unlock()
        guard first else { return false }
        // CONT: a stopped process handles SIGHUP only when continued.
        ProcessTree.signal(everything(), SIGHUP, SIGCONT)
        return true
    }

    private func killLeader() {
        lock.lock(); defer { lock.unlock() }
        if !exited, !reaped { kill(pid, SIGKILL) }
    }

    /// Returns those still alive after `grace`.
    private static func wait(for ids: Set<ProcessTree.ID>) -> Set<ProcessTree.ID> {
        var left = ids
        let deadline = Date().addingTimeInterval(grace)
        while true {
            left = ProcessTree.alive(left)
            if left.isEmpty || Date() >= deadline { return left }
            usleep(30_000)
        }
    }

    private func waitLoop() {
        var info = siginfo_t()
        // NOWAIT keeps the zombie: its pid and session id stay ours while the rest is killed.
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
        lock.lock(); exited = true; lock.unlock()
        let rest = everything()
        if !rest.isEmpty {
            ProcessTree.signal(rest, SIGHUP, SIGCONT)
            _ = Self.wait(for: rest)
            // A killed process may have just forked.
            for _ in 0..<5 {
                let left = everything()
                if left.isEmpty { break }
                ProcessTree.signal(left, SIGKILL)
                usleep(30_000)
            }
        }
        lock.lock()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        reaped = true
        lock.unlock()
        _ = reader.wait(timeout: .now() + 5)
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        queue.async { [self] in onExit(code) }
    }

    private func readLoop(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            let chunk = Array(buf[0..<n])
            // sync: a flood of output blocks the program, not the app's memory.
            queue.sync { onData(chunk) }
        }
        reader.leave()
        writer.async { [self] in
            lock.lock()
            self.fd = -1
            close(fd)
            lock.unlock()
        }
    }
}
