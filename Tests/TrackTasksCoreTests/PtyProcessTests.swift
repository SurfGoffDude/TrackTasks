import Foundation
import Testing
@testable import TrackTasksCore

@Suite("PtyProcess")
struct PtyProcessTests {
    final class Out: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []
        private var status: Int32?
        func add(_ b: [UInt8]) { lock.withLock { bytes += b } }
        func exit(_ c: Int32) { lock.withLock { status = c } }
        var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
        var code: Int32? { lock.withLock { status } }
    }

    static func start(_ script: String, cols: Int = 80, rows: Int = 24, cwd: String = "/tmp") throws -> (PtyProcess, Out) {
        let out = Out()
        let p = try PtyProcess(executable: "/bin/zsh", args: ["-fc", script],
                               environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color"],
                               cwd: cwd, cols: cols, rows: rows, queue: DispatchQueue(label: "pty-test"),
                               onData: { out.add($0) }, onExit: { out.exit($0) })
        return (p, out)
    }

    static func until(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
    }

    /// Pids printed as `name=123`.
    static func pid(_ name: String, _ text: String) -> pid_t? {
        text.components(separatedBy: "\r\n").first { $0.hasPrefix(name + "=") }.flatMap { pid_t($0.dropFirst(name.count + 1)) }
    }

    static func gone(_ pids: [pid_t]) -> Bool {
        let live = Set(ProcessTree.snapshot().map(\.id.pid))
        return live.isDisjoint(with: pids)
    }

    @Test func controllingTerminalAndCwd() async throws {
        let (_, out) = try Self.start("pwd; echo hi > /dev/tty; [[ -t 0 && -t 1 && -t 2 ]] && echo istty; exit 7", cwd: "/usr")
        #expect(await Self.until { out.code != nil })
        #expect(out.code == 7)
        #expect(out.text.contains("/usr\r\n") && out.text.contains("hi\r\n") && out.text.contains("istty"))
    }

    @Test func colorsAndUnicodeInput() async throws {
        let (p, out) = try Self.start(#"printf '\e[31mкрасный\e[0m 🚀\n'; read -r x; echo "got:$x""#)
        #expect(await Self.until { out.text.contains("🚀") })
        #expect(out.text.contains("\u{1b}[31mкрасный\u{1b}[0m"))
        p.write(Array("Привет 日本\r".utf8))
        #expect(await Self.until { out.code != nil })
        #expect(out.text.contains("got:Привет 日本"))
    }

    @Test func ctrlCInterruptsForeground() async throws {
        let (p, out) = try Self.start("echo ready; sleep 60")
        #expect(await Self.until { out.text.contains("ready") })
        p.write([3])
        #expect(await Self.until { out.code != nil })
        #expect(out.code == 128 + SIGINT)
    }

    /// Дочерний процесс не должен держать дескрипторы приложения (например, stdin запущенного claude).
    @Test func noInheritedDescriptors() async throws {
        let pipe = Pipe()
        let n = pipe.fileHandleForWriting.fileDescriptor
        #expect(fcntl(n, F_GETFD) >= 0)
        let (_, out) = try Self.start("[[ -e /dev/fd/\(n) ]] && echo LEAK; echo END")
        #expect(await Self.until { out.code != nil })
        #expect(out.text.contains("END") && !out.text.contains("LEAK"))
    }

    @Test func resize() async throws {
        let (p, out) = try Self.start("stty size; read -r x; stty size", cols: 100, rows: 30)
        #expect(await Self.until { out.text.contains("30 100") })
        p.resize(cols: 132, rows: 43)
        p.write([13])
        #expect(await Self.until { out.code != nil })
        #expect(out.text.contains("43 132"))
    }

    @Test func longOutputArrivesWhole() async throws {
        let (_, out) = try Self.start("seq 1 50000; echo END")
        #expect(await Self.until(20) { out.code != nil })
        #expect(out.text.contains("\r\n50000\r\nEND\r\n"))
    }

    /// HUP игнорируется, фоновое задание, nohup и отдельная сессия (как дети инструментов claude).
    static let stubborn = """
        trap '' HUP TERM
        sleep 601 & echo bg=$!
        nohup sleep 602 >/dev/null 2>&1 & echo nohup=$!
        /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec "sleep","603"' & echo sid=$!
        echo ready
        """

    @Test func terminateLeavesNothing() async throws {
        let (p, out) = try Self.start(Self.stubborn + "\nwhile true; do sleep 604; done")
        #expect(await Self.until { out.text.contains("ready") })
        let pids = [p.pid] + ["bg", "nohup", "sid"].compactMap { Self.pid($0, out.text) }
        #expect(pids.count == 4)
        p.terminate()
        #expect(await Self.until { out.code != nil })
        #expect(Self.gone(pids))
    }

    @Test func terminateAndWaitIsSynchronous() async throws {
        let (p, out) = try Self.start(Self.stubborn + "\nwhile true; do sleep 604; done")
        #expect(await Self.until { out.text.contains("ready") })
        let pids = [p.pid] + ["bg", "nohup", "sid"].compactMap { Self.pid($0, out.text) }
        PtyProcess.terminateAndWait([p])
        #expect(await Self.until(1) { Self.gone(pids) })
        #expect(await Self.until { out.code != nil })
    }

    @Test func ownExitSweepsBackgroundJobs() async throws {
        let (_, out) = try Self.start("nohup sleep 605 >/dev/null 2>&1 & echo bg=$!\nexit 0")
        #expect(await Self.until { out.code != nil })
        let bg = try #require(Self.pid("bg", out.text))
        #expect(Self.gone([bg]))
    }

    @Test func badCwdThrows() {
        #expect(throws: PtyProcess.Failure.self) { _ = try Self.start("true", cwd: "/no/such/dir") }
    }

    @Test func members() {
        func e(_ pid: pid_t, _ parent: pid_t, _ session: pid_t) -> ProcessTree.Entry {
            .init(id: .init(pid: pid, started: 1), parent: parent, session: session)
        }
        let all = [e(10, 5, 10), e(11, 10, 10), e(12, 1, 10), e(13, 11, 13), e(14, 13, 13), e(20, 5, 20), e(5, 1, 5)]
        #expect(Set(ProcessTree.members(of: 10, in: all).map(\.pid)) == [10, 11, 12, 13, 14])
        #expect(ProcessTree.members(of: 0, in: all).isEmpty && ProcessTree.members(of: 1, in: all).isEmpty)
    }
}
