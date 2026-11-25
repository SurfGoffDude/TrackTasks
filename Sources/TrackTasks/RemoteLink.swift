import Foundation
import TrackTasksCore

/// How ssh is started. Tests point it at their own config.
struct RemoteTransport: Sendable {
    var ssh = "/usr/bin/ssh"
    var extra: [String] = []
}

enum RemoteError: LocalizedError {
    case link(SSHCommand.Failure, String)
    case failed(String)
    /// The server's command ended with this code.
    case code(Int32, String)
    /// `interrupt()` or the run was stopped.
    case interrupted

    var errorDescription: String? {
        switch self {
        case .link(let f, let detail): f.text + (f == .noConnection && !detail.isEmpty ? ": \(detail)" : "")
        case .failed(let s): s
        case .code(let c, let e): "Команда на сервере завершилась с кодом \(c)" + (e.isEmpty ? "" : ": \(e)")
        case .interrupted: "Остановлено"
        }
    }

    /// The connection may come back.
    var isOutage: Bool { if case .link(.noConnection, _) = self { true } else { false } }
}

/// Calls operations of the runner over ssh, one at a time. Synchronous — not for the main thread.
final class RemoteLink: @unchecked Sendable {
    let server: RemoteServer
    private let transport: RemoteTransport
    private let lock = NSLock()
    private var current: Process?
    private var kills = 0

    init(_ server: RemoteServer, _ transport: RemoteTransport) {
        self.server = server
        self.transport = transport
    }

    enum Input {
        case none, data(Data)
        /// File from this byte on.
        case file(URL, UInt64)
    }

    /// Kills the call that is going now.
    func interrupt() {
        lock.withLock {
            kills += 1
            current?.terminate()
        }
    }

    /// Passed as `since`: an interrupt after this moment stops a call that starts later.
    var mark: Int { lock.withLock { kills } }

    /// Operation of the runner. Installs the script when the server doesn't have it. Non-zero exit code throws `.code`.
    @discardableResult
    func call(_ words: [String], input: Input = .none, timeout: TimeInterval? = 90, since: Int? = nil, onOutput: ((Data) -> Void)? = nil) throws -> String {
        guard let cmd = SSHCommand.runner(server, words) else { throw RemoteError.failed("Недопустимая команда для сервера") }
        do { return try raw(cmd, input: input, timeout: timeout, since: since, onOutput: onOutput) } catch RemoteError.code(let c, let err)
            where (c == 126 || c == 127 || c == 2) && err.contains(RemoteRunner.fileName) {
            try raw(SSHCommand.install(server), input: .data(Data(RemoteRunner.script.utf8)), timeout: timeout, since: since, onOutput: nil)
            return try raw(cmd, input: input, timeout: timeout, since: since, onOutput: onOutput)
        }
    }

    @discardableResult
    private func raw(_ command: String, input: Input, timeout: TimeInterval?, since: Int?, onOutput: ((Data) -> Void)?) throws -> String {
        guard let args = SSHCommand.args(server, command: command, extra: transport.extra) else {
            throw RemoteError.failed(server.problem ?? "Недопустимые настройки сервера")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: transport.ssh)
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        // No graphical password prompt.
        env["SSH_ASKPASS_REQUIRE"] = "never"
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        let w = inp.fileHandleForWriting
        if case .none = input { p.standardInput = FileHandle.nullDevice } else { p.standardInput = inp }
        _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        Log.queue.process("ssh", project: server.host, command: "")

        lock.lock()
        let killsBefore = since ?? kills
        if kills != killsBefore { lock.unlock(); throw RemoteError.interrupted }
        do { try p.run() } catch { lock.unlock(); throw RemoteError.failed(error.localizedDescription) }
        current = p
        lock.unlock()
        defer { lock.withLock { current = nil } }

        let timedOut = Flag()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { timedOut.set(); p.terminate() }
            }
        }
        switch input {
        case .none: break
        case .data(let d):
            OwnThread.start {
                try? w.write(contentsOf: d)
                try? w.close()
            }
        case .file(let url, let from):
            OwnThread.start {
                defer { try? w.close() }
                guard let h = try? FileHandle(forReadingFrom: url) else { return }
                defer { try? h.close() }
                try? h.seek(toOffset: from)
                while let chunk = try? h.read(upToCount: 1 << 18), !chunk.isEmpty {
                    guard (try? w.write(contentsOf: chunk)) != nil else { return }
                }
            }
        }
        let errBuf = Flag()
        let errDone = DispatchSemaphore(value: 0)
        OwnThread.start {
            while case let d = err.fileHandleForReading.availableData, !d.isEmpty { errBuf.append(d) }
            errDone.signal()
        }
        var data = Data()
        while case let d = out.fileHandleForReading.availableData, !d.isEmpty {
            if let onOutput { onOutput(d) } else { data.append(d) }
        }
        exited.wait()
        // A ProxyCommand may keep stderr open.
        _ = errDone.wait(timeout: .now() + 2)
        let text = errBuf.text
        if lock.withLock({ kills != killsBefore }) { throw RemoteError.interrupted }
        let tail = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
        if timedOut.isSet || p.terminationReason == .uncaughtSignal { throw RemoteError.link(.noConnection, "нет ответа") }
        if let f = SSHCommand.failure(status: p.terminationStatus, stderr: text) { throw RemoteError.link(f, tail) }
        guard p.terminationStatus == 0 else { throw RemoteError.code(p.terminationStatus, tail) }
        return String(decoding: data, as: UTF8.self)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        private var data = Data()
        func set() { lock.withLock { on = true } }
        var isSet: Bool { lock.withLock { on } }
        func append(_ d: Data) { lock.withLock { data.append(d) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    // MARK: Files

    /// Sends the file; an interrupted upload goes on from where it stopped. `retry` waits for the connection or throws.
    func upload(_ file: URL, run: String, name: String, retry: (RemoteError) throws -> Void) throws {
        let d = try Data(contentsOf: file, options: .mappedIfSafe)
        let sha = RemoteRun.sha256(d)
        var broken = 0
        while true {
            do {
                let have = try call(["size", run, name]).trimmingCharacters(in: .whitespacesAndNewlines)
                if have != "sealed" {
                    guard let n = Int(have) else { throw RemoteError.failed("Непонятный ответ сервера") }
                    if n < d.count { try call(["append", run, name], input: .file(file, UInt64(n)), timeout: nil) }
                }
                try call(["seal", run, name, String(d.count), sha])
                return
            } catch RemoteError.code(RemoteRunner.badUpload, _) {
                broken += 1
                if broken > 5 { throw RemoteError.failed("Файл доходит до сервера повреждённым") }
            } catch let e as RemoteError where e.isOutage { try retry(e) }
        }
    }

    /// Takes the file; an interrupted download goes on from where it stopped.
    func download(_ name: String, run: String, expect: RemoteState.File, to file: URL, retry: (RemoteError) throws -> Void) throws {
        let fm = FileManager.default
        var broken = 0
        while true {
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
            let have = (try? Data(contentsOf: file, options: .mappedIfSafe)) ?? Data()
            if have.count == expect.size {
                if RemoteRun.sha256(have) == expect.sha { return }
                broken += 1
                if broken > 3 { throw RemoteError.failed("Файл с сервера повреждён: \(name)") }
                try fm.removeItem(at: file)
                continue
            }
            if have.count > expect.size { try fm.removeItem(at: file); continue }
            let h = try FileHandle(forWritingTo: file)
            try h.seekToEnd()
            defer { try? h.close() }
            var writeError: Error?
            do {
                try call(["fetch", run, name, String(have.count)], timeout: nil) { d in
                    guard writeError == nil else { return }
                    do { try h.write(contentsOf: d) } catch { writeError = error }
                }
                // The file must reach its size: an answer without an error that is too short is a broken one.
                let now = try h.offset()
                if now < UInt64(expect.size), writeError == nil { throw RemoteError.failed("Файл на сервере короче ожидаемого: \(name)") }
            } catch let e as RemoteError where e.isOutage { try retry(e) }
            if let writeError { throw RemoteError.failed("Не удалось сохранить файл с сервера: \(writeError.localizedDescription)") }
        }
    }
}
