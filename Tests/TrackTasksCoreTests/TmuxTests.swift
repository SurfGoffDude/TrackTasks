import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Tmux", .serialized)
struct TmuxTests {
    static let binary = Tmux.find()
    static let env = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color", "HOME": NSHomeDirectory()]

    /// Short path: the socket limit is 103 bytes.
    private func temp() throws -> (Tmux, URL) {
        let dir = URL(fileURLWithPath: "/tmp/tt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try #require(Tmux(binary: Self.binary ?? "/nonexistent", socket: dir.path + "/s ock")), dir)
    }

    private func cleanUp(_ t: Tmux, _ dir: URL) {
        if case .sessions(let all) = t.list() { for s in all { _ = t.kill(s.id) } }
        try? FileManager.default.removeItem(at: dir)
    }

    private func session(_ folder: String = "/tmp", job: UUID? = UUID(), command: String? = "x") -> Tmux.Session {
        Tmux.Session(id: UUID(), job: job, kind: "claude", command: command, folder: folder)
    }

    @Test func findsBinary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tmux-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(Tmux.find(dirs: [dir.path], path: "") == nil)
        let file = dir.appendingPathComponent("tmux")
        try "".write(to: file, atomically: true, encoding: .utf8)
        #expect(Tmux.find(dirs: [dir.path], path: "") == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        #expect(Tmux.find(dirs: [], path: "relative:" + dir.path) == file.path)
    }

    @Test func socketPathLimit() {
        #expect(Tmux(binary: "/t", socket: String(repeating: "a", count: 103)) != nil)
        #expect(Tmux(binary: "/t", socket: String(repeating: "я", count: 52)) == nil)
    }

    @Test func attachCommandIsQuoted() throws {
        let id = UUID()
        let t = try #require(Tmux(binary: "/opt/homebrew/bin/tmux", socket: "/a b/it's"))
        #expect(t.attachCommand(id) == "TMUX= /opt/homebrew/bin/tmux -S '/a b/it'\\''s' -f /dev/null -u attach-session -t '=tt-\(id.uuidString)'")
    }

    @Test func parsesOnlyOwnSessions() {
        let id = UUID(), job = UUID()
        let cmd = Data("a|b".utf8).base64EncodedString(), dir = Data("/x y".utf8).base64EncodedString()
        let out = "tt-\(id)|\(job)|claude|\(cmd)|\(dir)\ntt-zzz|||| \nmine||||\ntt-\(id)||shell||\(dir)\n"
        #expect(Tmux.parse(out) == [Tmux.Session(id: id, job: job, kind: "claude", command: "a|b", folder: "/x y"),
                                    Tmux.Session(id: id, job: nil, kind: "shell", command: nil, folder: "/x y")])
    }

    @Test func noServerIsNotAnError() {
        #expect(Tmux.noServer("no server running on /x"))
        #expect(Tmux.noServer("error connecting to /x (No such file or directory)"))
        #expect(!Tmux.noServer("error connecting to /x (Socket operation on non-socket)"))
        #expect(!Tmux.noServer("server protocol version mismatch (client 8, server 9)"))
    }

    /// Broken tmux: "no sessions" only when nobody listens on the socket.
    @Test(.enabled(if: binary != nil)) func brokenTmuxIsUnknown() throws {
        let none = try #require(Tmux(binary: "/nonexistent/tmux", socket: "/tmp/none"))
        #expect(none.list() == .sessions([]) && none.state(UUID()) == .gone && none.kill(UUID()) == nil)
        let (t, dir) = try temp()
        defer { cleanUp(t, dir) }
        let s = session()
        #expect(t.create(s, program: ["/bin/sh", "-c", "sleep 100"], environment: Self.env, cols: 80, rows: 24) == nil)
        for bin in ["/nonexistent/tmux", "/usr/bin/false"] {
            let broken = try #require(Tmux(binary: bin, socket: t.socket))
            guard case .unknown = broken.list(), case .unknown = broken.state(s.id) else { Issue.record("not unknown"); return }
            #expect(broken.kill(s.id) != nil)
        }
        #expect(t.state(s.id) == .alive)
    }

    @Test(.enabled(if: binary != nil)) func listsLabels() throws {
        let (t, dir) = try temp()
        defer { cleanUp(t, dir) }
        #expect(t.list() == .sessions([]) && t.state(UUID()) == .gone)
        let folder = dir.appendingPathComponent("a #{pid} b;")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let s = session(folder.path, command: "claude --resume 'x|y' \"$z\";\n#{pid} привет;")
        #expect(t.create(s, program: ["/bin/sh", "-c", "pwd > out; sleep 100;"], environment: Self.env, cols: 80, rows: 24) == nil)
        #expect(t.list() == .sessions([s]) && t.state(s.id) == .alive && Tmux.listening(t.socket))
        let end = Date().addingTimeInterval(5)
        var pwd = ""
        while pwd.isEmpty, Date() < end {
            usleep(50_000)
            pwd = (try? String(contentsOf: folder.appendingPathComponent("out"), encoding: .utf8)) ?? ""
        }
        #expect(pwd.hasSuffix("/a #{pid} b;\n"))
        let other = UUID()
        t.setJob(s.id, other)
        guard case .sessions(let all) = t.list() else { Issue.record("no list"); return }
        #expect(all.map(\.job) == [other])
    }

    /// What quitting the app does: the client dies, the session stays and can be attached again.
    @Test(.enabled(if: binary != nil)) func sessionOutlivesItsClient() async throws {
        let (t, dir) = try temp()
        defer { cleanUp(t, dir) }
        let s = session()
        #expect(t.create(s, program: ["/bin/sh", "-c", "echo pid=$$; exec sleep 100"], environment: Self.env, cols: 80, rows: 24) == nil)
        for _ in 0..<2 {
            let out = PtyProcessTests.Out()
            let p = try PtyProcess(executable: t.binary, args: t.attachArgs(s.id), environment: Self.env, cwd: "/tmp", cols: 80, rows: 24,
                                   queue: DispatchQueue(label: "tmux-test"), onData: { out.add($0) }, onExit: { out.exit($0) })
            #expect(await PtyProcessTests.until { out.text.contains("pid=") })
            PtyProcess.terminateAndWait([p])
            #expect(await PtyProcessTests.until { out.code != nil })
            #expect(t.state(s.id) == .alive)
        }
        #expect(t.list() == .sessions([s]))
    }

    @Test(.enabled(if: binary != nil)) func killEndsOnlyItsSession() async throws {
        let (t, dir) = try temp()
        defer { cleanUp(t, dir) }
        let a = session(), b = session()
        let pids = dir.appendingPathComponent("pids")
        // Children that ignore the hang-up must go too.
        let script = "trap '' HUP; sleep 301 & echo $! >> '\(pids.path)'; echo $$ >> '\(pids.path)'; wait"
        #expect(t.create(a, program: ["/bin/sh", "-c", script], environment: Self.env, cols: 80, rows: 24) == nil)
        #expect(t.create(b, program: ["/bin/sh", "-c", "sleep 302"], environment: Self.env, cols: 80, rows: 24) == nil)
        func read() -> [pid_t] {
            ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
        }
        #expect(await PtyProcessTests.until { read().count == 2 })
        #expect(t.kill(a.id) == nil)
        #expect(await PtyProcessTests.until(2) { PtyProcessTests.gone(read()) })
        #expect(t.state(a.id) == .gone && t.state(b.id) == .alive)
        #expect(t.kill(a.id) == nil)
        #expect(t.state(b.id) == .alive)
        #expect(t.kill(b.id) == nil && t.state(b.id) == .gone)
    }

    @Test(.enabled(if: binary != nil)) func createsRightAfterTheLastSessionEnded() throws {
        let (t, dir) = try temp()
        defer { cleanUp(t, dir) }
        for _ in 0..<3 {
            let s = session()
            #expect(t.create(s, program: ["/bin/sh", "-c", "sleep 100"], environment: Self.env, cols: 80, rows: 24) == nil)
            #expect(t.kill(s.id) == nil)
        }
    }
}
