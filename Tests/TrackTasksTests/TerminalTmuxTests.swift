import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// Real tmux on a temporary socket; a second `Terminals` stands for the restarted app.
@MainActor @Suite(.serialized, .enabled(if: Tmux.find() != nil)) struct TerminalTmuxTests {
    let dir = URL(fileURLWithPath: "/tmp/tt-\(UUID().uuidString.prefix(8))")
    let tmux: Tmux

    init() throws {
        // Not the user's rc files: they may be slow or ask questions.
        TerminalTab.shell = { ["/bin/zsh", "-f"] }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = try #require(Tmux.find())
        tmux = try #require(Tmux(binary: binary, socket: dir.path + "/s"))
    }

    private func job() -> Job {
        Job(kind: .runTask, title: "t", projectID: nil, projectName: "p", cwd: dir, prompt: "x", systemPrompt: "")
    }

    private func until(_ cond: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return cond()
    }

    private func sessions() -> [Tmux.Session] {
        if case .sessions(let all) = tmux.list() { all } else { [] }
    }

    private func cleanUp() {
        for s in sessions() { _ = tmux.kill(s.id) }
        try? FileManager.default.removeItem(at: dir)
    }

    private func restored(_ jobs: [Job]) async -> Terminals {
        let t = Terminals(tmux: tmux)
        t.restore({ jobs }) {}
        #expect(jobs.allSatisfy(t.claudeRunning))
        #expect(await until { !t.restoring })
        return t
    }

    @Test func survivesRestartAndClosesOnlyItsOwn() async throws {
        defer { cleanUp() }
        let a = job(), b = job(), c = job()
        let first = Terminals(tmux: tmux)
        first.open(a, .claude, command: "sleep 300")
        first.open(b, .shell)
        first.open(b, .command, command: "sleep 300")
        #expect(await until { sessions().count == 2 && first.tabs(a)[0].pty != nil && first.tabs(b)[0].pty != nil })
        #expect(first.tabs(b)[1].tmux == nil)
        PtyProcess.terminateAndWait([a, b].flatMap { first.tabs($0) }.compactMap(\.pty))
        #expect(await until { first.tabs(a)[0].detached != nil })
        #expect(first.claudeRunning(a) && first.tabs(a)[0].isRunning)

        let second = await restored([a, b, c])
        #expect(second.claudeRunning(a) && !second.claudeRunning(b) && !second.claudeRunning(c))
        #expect(second.tabs(a).map(\.command) == ["sleep 300"] && second.tabs(b).map(\.kind) == [.shell])
        #expect(await until { second.tabs(a)[0].pty != nil })
        second.move(from: dir, a, to: c)
        #expect(second.claudeRunning(c))
        #expect(await until { sessions().contains { $0.job == c.id } })
        second.closeAll(c.id)
        #expect(await until { sessions().map(\.job) == [b.id] })
        #expect(!second.claudeRunning(c) && second.tabs(b)[0].isRunning)
    }

    @Test func closingDuringCreationEndsTheSession() async throws {
        defer { cleanUp() }
        let j = job(), t = Terminals(tmux: tmux)
        t.open(j, .shell)
        t.closeAll(j.id)
        try await Task.sleep(for: .seconds(3))
        #expect(sessions().isEmpty && t.tabs(j).isEmpty)
    }

    @Test func endedProgramIsNotRunning() async throws {
        defer { cleanUp() }
        let j = job(), t = Terminals(tmux: tmux)
        // Ends on a signal, not by time: another suite may hold the main thread longer than a short sleep lives.
        let go = dir.appendingPathComponent("go")
        t.open(j, .claude, command: "until [ -e '\(go.path)' ]; do sleep 0.1; done")
        #expect(t.claudeRunning(j))
        #expect(await until { !sessions().isEmpty })
        FileManager.default.createFile(atPath: go.path, contents: nil)
        #expect(await until { !t.claudeRunning(j) }, "\(t.tabs(j)[0].detached ?? "-") busy=\(t.tabs(j)[0].busy) pty=\(t.tabs(j)[0].pty != nil) \(tmux.state(t.tabs(j)[0].id))")
        try FileManager.default.removeItem(at: go)
        t.tabs(j)[0].start()
        #expect(await until { !sessions().isEmpty })
        t.closeAll(j.id)
        #expect(await until { sessions().isEmpty })
    }

    @Test func sessionWithoutJobIsLeftAlone() async throws {
        defer { cleanUp() }
        let j = job(), first = Terminals(tmux: tmux)
        first.open(j, .shell)
        #expect(await until { !sessions().isEmpty })
        let second = await restored([])
        #expect(second.orphans.map(\.job) == [j.id] && second.tabs.isEmpty)
        #expect(sessions().count == 1)
        second.endOrphan(second.orphans[0])
        #expect(await until { sessions().isEmpty })
    }
}
