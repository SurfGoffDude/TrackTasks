import Darwin
import Foundation
import TrackTasksCore

/// One command an ACP agent asked for and the user approved. It has a session of its own (setsid): everything it
/// starts is found and killed with it, also when it ends by itself.
final class ACPTerminal: @unchecked Sendable {
    static let maxOutput = 1 << 20

    private let lock = NSLock()
    private let pid: pid_t
    private let limit: Int
    private var data = Data()
    private var truncated = false
    private var exited = false
    private var reaped = false
    private var status: [String: Any]?
    private var waiting: [@Sendable () -> Void] = []

    init(_ c: ACPSession.Command) throws {
        limit = max(0, min(c.limit ?? Self.maxOutput, Self.maxOutput))
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        defer { close(writeEnd) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        posix_spawn_file_actions_addchdir_np(&actions, c.cwd)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var mask = sigset_t(), all = sigset_t()
        sigemptyset(&mask)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ACPLocator.path(env)
        env.merge(c.env) { $1 }
        // Without arguments it is a line for the shell; with them nothing is interpreted.
        let words = c.args.isEmpty ? ["/bin/sh", "-c", c.command] : ["/bin/sh", "-c", #"exec "$0" "$@""#, c.command] + c.args
        let argv = words.map { strdup($0) } + [nil], envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var id: pid_t = 0
        let e = posix_spawn(&id, "/bin/sh", &actions, &attr, argv, envp)
        guard e == 0 else {
            close(readEnd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        pid = id

        let eof = DispatchGroup()
        eof.enter()
        Thread.detachNewThread { [self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            while case let n = Darwin.read(readEnd, &chunk, chunk.count), n > 0 { append(chunk[0..<n]) }
            close(readEnd)
            eof.leave()
        }
        Thread.detachNewThread { [self] in
            // Until it is reaped its pid and session can't be anyone else's.
            var info = siginfo_t()
            while waitid(P_PID, id_t(id), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
            let left = ProcessTree.members(of: id, in: ProcessTree.snapshot())
            lock.lock()
            exited = true
            lock.unlock()
            if !left.isEmpty { ProcessTree.killTree(id) }
            var st: Int32 = 0
            for _ in 0..<30 where !ProcessTree.alive(left).isEmpty { usleep(100_000) }
            lock.lock()
            while waitpid(id, &st, 0) < 0, errno == EINTR {}
            reaped = true
            lock.unlock()
            _ = eof.wait(timeout: .now() + 1)
            let signal = st & 0x7f
            lock.lock()
            status = signal == 0 ? ["exitCode": Int((st >> 8) & 0xff), "signal": NSNull()]
                : ["exitCode": NSNull(), "signal": String(cString: strsignal(signal))]
            let done = waiting
            waiting = []
            lock.unlock()
            done.forEach { $0() }
        }
    }

    private func append(_ bytes: ArraySlice<UInt8>) {
        lock.lock(); defer { lock.unlock() }
        data.append(contentsOf: bytes)
        if data.count > limit {
            data = Data(data.suffix(limit))
            // Not from the middle of a character.
            data = Data(data.drop { $0 & 0xC0 == 0x80 })
            truncated = true
        }
    }

    var output: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["output": String(decoding: data, as: UTF8.self), "truncated": truncated, "exitStatus": status ?? NSNull()]
    }

    var exitStatus: [String: Any] { lock.lock(); defer { lock.unlock() }; return status ?? [:] }

    func whenExited(_ f: @escaping @Sendable () -> Void) {
        lock.lock()
        let now = status != nil
        if !now { waiting.append(f) }
        lock.unlock()
        if now { f() }
    }

    func kill() {
        lock.lock(); defer { lock.unlock() }
        if !exited, !reaped { ProcessTree.killTree(pid) }
    }
}

/// Terminals of one run.
@MainActor
final class ACPTerminals {
    private var all: [String: ACPTerminal] = [:]
    /// Released ones may still be ending.
    private var ending: [ACPTerminal] = []
    private var closed = false

    /// Answers now or, for `wait`, later.
    func call(_ t: ACPSession.Terminal, reply: @escaping @MainActor @Sendable (Result<[String: Any], ACPAccess.Refusal>) -> Void) {
        func find(_ id: String, _ f: (ACPTerminal) -> Void) {
            guard let t = all[id] else { return reply(.failure(.notFound)) }
            f(t)
        }
        switch t {
        case .create(let c):
            guard !closed else { return reply(.failure(.failed("cancelled"))) }
            do {
                let t = try ACPTerminal(c), id = UUID().uuidString
                all[id] = t
                reply(.success(["terminalId": id]))
            } catch { reply(.failure(.failed(error.localizedDescription))) }
        case .output(let id): find(id) { reply(.success($0.output)) }
        case .wait(let id):
            find(id) { t in
                t.whenExited { DispatchQueue.main.async { MainActor.assumeIsolated { reply(.success(t.exitStatus)) } } }
            }
        case .kill(let id):
            find(id) { $0.kill(); reply(.success([:])) }
        case .release(let id):
            find(id) {
                $0.kill()
                ending.append($0)
                all[id] = nil
                reply(.success([:]))
            }
        }
    }

    func killAll() {
        closed = true
        for t in all.values { t.kill() }
    }

    /// Kills all and calls back when nothing of them is left (or it can't be waited for any longer).
    func close(_ then: @escaping @MainActor @Sendable () -> Void) {
        killAll()
        let group = DispatchGroup()
        for t in Array(all.values) + ending {
            group.enter()
            t.whenExited { group.leave() }
        }
        DispatchQueue.global().async {
            _ = group.wait(timeout: .now() + 6)
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
    }
}
