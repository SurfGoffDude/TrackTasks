import Foundation
import Testing
@testable import TrackTasksCore

@Suite("RunCommands")
struct RunCommandsTests {
    @Test func single() {
        let p = RunCommands.parse(["run": " npm run dev "])
        #expect(p.commands == [RunCommand(name: "dev", command: "npm run dev")])
        #expect(RunCommands.parse([:]).isEmpty)
        #expect(RunCommands.parse(["run": "\"make serve\""]).commands.first?.command == "make serve")
    }

    @Test func named() {
        let p = RunCommands.parse(["run": #"{"web": "npm run dev", "api": "go run . --port $PORT", "bad": ""}"#])
        #expect(p.commands.map(\.name) == ["api", "web"])
        #expect(p.commands.first?.command == "go run . --port $PORT")
    }

    @Test func approvalByText() {
        var a = ScriptApprovals()
        let proj = URL(fileURLWithPath: "/tmp/p")
        #expect(!a.isRunApproved("npm run dev", project: proj))
        #expect(a.isRunApproved("", project: proj))
        a.approveRun("npm run dev", project: proj)
        #expect(a.isRunApproved("npm run dev", project: proj))
        #expect(!a.isRunApproved("npm run dev && evil", project: proj))
        // setup approvals are independent
        #expect(a.pending(WorktreeScripts(setup: "x"), project: proj).count == 1)
    }

    @Test func findsPort() {
        #expect(RunCommands.port(in: "  ➜  Local:   http://localhost:5173/\n") == 5173)
        #expect(RunCommands.port(in: "\u{1b}[32mready\u{1b}[0m - started server on 0.0.0.0:3001, url: http://0.0.0.0:3001") == 3001)
        #expect(RunCommands.port(in: "Listening on port 8080") == 8080)
        #expect(RunCommands.port(in: "Listening on :9000") == 9000)
        #expect(RunCommands.port(in: "compiled in 300ms") == nil)
    }

    @Test func plainStripsEscapes() {
        #expect(RunCommands.plain("\u{1b}[1;32mok\u{1b}[0m\r\nnext") == "ok\nnext")
    }

    @Test func trimLogCutsAtLine() {
        let big = (0..<5000).map { "line \($0)" }.joined(separator: "\n")
        let t = RunCommands.trimLog(big, limit: 1000)
        #expect(t.count < 1000)
        #expect(t.hasPrefix("line "))
        #expect(t.hasSuffix("line 4999"))
    }

    @Test func twoWorktreesGetDifferentPorts() throws {
        let a = try #require(RunCommands.freePort(from: 41000))
        let b = try #require(RunCommands.freePort(from: 41000, avoiding: [a]))
        #expect(a != b)
        // A listening socket is skipped. Another process may take the port meanwhile: try the next free one.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var taken: Int?
        var candidate = a
        for _ in 0..<20 {
            guard let c = RunCommands.freePort(from: candidate) else { break }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(c).bigEndian
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if ok == 0 { taken = c; break }
            candidate = c + 1
        }
        let bound = try #require(taken)
        #expect(RunCommands.freePort(from: bound) != bound)
    }
}
