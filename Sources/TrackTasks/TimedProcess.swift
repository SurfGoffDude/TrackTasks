import Foundation
import TrackTasksCore

/// Runs a process that may hang (network, keychain): never waits longer than `timeout` plus a few seconds.
enum TimedProcess {
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int?
        init(_ limit: Int?) { self.limit = limit }
        func append(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(d)
            if let limit, data.count > limit * 2 { data = Data(data.suffix(limit)) }
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// `outputLimit`: keep about this much of the end.
    /// `discardOutput`: stdout goes to /dev/null (it may carry a secret).
    static func run(_ p: Process, timeout: TimeInterval, input: String? = nil, discardOutput: Bool = false,
                    killTree: Bool = false, outputLimit: Int? = nil, onStart: ((Process) -> Void)? = nil,
                    onOutput: (@Sendable (String) -> Void)? = nil) -> Worktrees.Result {
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        p.standardOutput = discardOutput ? FileHandle.nullDevice : out
        p.standardError = err
        if input != nil { p.standardInput = stdin } else { p.standardInput = FileHandle.nullDevice }
        // The process may exit without reading its input.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return .init(ok: false, out: "", err: error.localizedDescription) }

        onStart?(p)
        let outBuf = Buffer(outputLimit), errBuf = Buffer(outputLimit)
        let eof = DispatchGroup()
        func drain(_ pipe: Pipe, _ buf: Buffer) {
            DispatchQueue.global().async(group: eof) {
                while case let d = pipe.fileHandleForReading.availableData, !d.isEmpty { buf.append(d); onOutput?(String(decoding: d, as: UTF8.self)) }
            }
        }
        if !discardOutput { drain(out, outBuf) }
        drain(err, errBuf)
        if let input {
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            if killTree { ProcessTree.killTree(p.processIdentifier) }
            p.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 3)
            }
        }
        // A grandchild (ssh master, credential helper) may keep the pipes open: don't wait for it.
        _ = eof.wait(timeout: .now() + 2)
        if timedOut {
            return .init(ok: false, out: outBuf.text, err: "Нет ответа за \(Int(timeout)) с, операция остановлена\n" + errBuf.text)
        }
        return .init(ok: p.terminationReason == .exit && p.terminationStatus == 0, out: outBuf.text, err: errBuf.text)
    }

    /// git that talks to a remote.
    static func gitNetwork(_ args: [String], in url: URL, timeout: TimeInterval = 180) -> Worktrees.Result {
        if let why = ContainerStore.shared.refusal(url) { return .init(ok: false, out: "", err: why) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", url.path] + ContainerStore.shared.gitOptions(url) + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        p.environment = env
        Log.git.process("git", project: url.lastPathComponent, command: args.first ?? "")
        return run(p, timeout: timeout)
    }
}
