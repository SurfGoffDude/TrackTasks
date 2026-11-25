import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// The real queue, merges and terminals; the question is answered by the test.
@MainActor @Suite(.serialized) struct RestartGateTests {
    let dir: URL, queue: JobQueue, agent = FakeAgent()
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = agent
        queue = JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([a]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "Fake", agent: AgentID(rawValue: "fake"), model: "m1")], defaultID: "fake") },
                         dangerMode: { DangerMode() }, recordSpend: { _, _, _, _ in })
    }

    @MainActor final class Probe {
        var calls = 0
        var asked: [@MainActor (Bool) -> Void] = []
        func answer(_ yes: Bool) { asked.popLast()?(yes) }
    }

    private func job(_ title: String = "Задача") -> Job {
        Job(kind: .runTask, title: title, projectID: nil, projectName: "p", cwd: dir, prompt: "x", systemPrompt: "")
    }
    /// Only what this test makes busy: other suites run merges of their own meanwhile.
    private func gate(_ p: Probe, extra: @escaping @MainActor () -> [UpdatePolicy.Busy] = { [] }, thawAfter: TimeInterval = 60) -> RestartGate {
        let q = queue
        return RestartGate(sources: { q.restartBusy + extra() }, freeze: { q.frozen = $0 }, thawAfter: thawAfter, ask: { p.asked.append($0) })
    }
    private func settle() async { for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)) } }

    private func until(_ done: () -> Bool) async {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Postponed, asked when free, restarted once after agreement.
    private func check(_ p: Probe, _ g: RestartGate, end: () -> Void) async {
        #expect(g.postpone { p.calls += 1 })
        await settle()
        #expect(p.calls == 0 && p.asked.isEmpty && g.isPending && !queue.frozen)
        end()
        await until { !p.asked.isEmpty }
        // Not by itself: the user is asked.
        #expect(p.calls == 0 && p.asked.count == 1)
        p.answer(true)
        #expect(p.calls == 1 && !g.isPending && queue.frozen)
        await settle()
        #expect(p.calls == 1 && p.asked.isEmpty)
    }

    @Test func runningTaskPostpones() async {
        let j = job()
        j.state = .running
        queue.jobs = [j]
        let p = Probe()
        await check(p, gate(p)) { j.state = .done }
    }

    @Test func everyStageOfATaskPostpones() async {
        for (on, off): ((Job) -> Void, (Job) -> Void) in [
            ({ $0.verifying = true }, { $0.verifying = false }),
            ({ $0.checkpointing = true }, { $0.checkpointing = false }),
            ({ $0.settingUp = true }, { $0.settingUp = false }),
            ({ $0.answering = true }, { $0.answering = false }),
            ({ $0.mergePhase = .waiting }, { $0.mergePhase = nil }),
            ({ $0.worktreeBusy = true }, { $0.worktreeBusy = false }),
        ] {
            let j = job()
            j.state = .done
            on(j)
            queue.jobs = [j]
            queue.frozen = false
            let p = Probe()
            await check(p, gate(p)) { off(j) }
        }
    }

    @Test func queueOperationsPostpone() async {
        let q = queue
        for (on, off): (() -> Void, () -> Void) in [
            ({ q.autoMerging.insert("/x") }, { q.autoMerging.removeAll() }),
            ({ q.gitBusy.insert("/x") }, { q.gitBusy.removeAll() }),
            ({ q.restarting = true }, { q.restarting = false }),
            ({ q.cleaning = true }, { q.cleaning = false }),
            ({ q.busyOrphans.insert("/x") }, { q.busyOrphans.removeAll() }),
        ] {
            on()
            q.frozen = false
            let p = Probe()
            await check(p, gate(p)) { off() }
        }
    }

    @Test func mergeOutsideTheQueuePostpones() async {
        let t = MergeToken(), p = Probe()
        t.begin()
        #expect(MergeToken.anyLive && RestartGate.busy(jobs: queue, terminals: Terminals(tmux: Tmux(binary: "/nonexistent/tmux", socket: "/tmp/tt-gate.sock")), servers: 0, chat: false) == [.merge("")])
        // The registry is app-wide, so the end is watched through its own change only.
        var live = true
        let g = gate(p, extra: { _ = MergeToken.anyLive; return live ? [.merge("")] : [] })
        await check(p, g) { live = false; t.end() }
    }

    @Test func terminalPostpones() async throws {
        let terminals = Terminals(tmux: Tmux(binary: "/nonexistent/tmux", socket: "/tmp/tt-gate.sock")), p = Probe()
        let j = job()
        j.state = .done
        queue.jobs = [j]
        let g = gate(p, extra: { terminals.liveCount > 0 ? [.terminal(terminals.liveCount)] : [] })
        terminals.open(j, .command, command: "sleep 30")
        let tab = try #require(terminals.tabs(j).first)
        #expect(tab.isRunning && RestartGate.busy(jobs: queue, terminals: terminals, servers: 0, chat: false).contains(.terminal(1)))
        await check(p, g) { terminals.close(tab, of: j.id) }
    }

    @Test func chatAndServersCount() {
        let none = Terminals(tmux: Tmux(binary: "/nonexistent/tmux", socket: "/tmp/tt-gate.sock"))
        let busy = RestartGate.busy(jobs: queue, terminals: none, servers: 2, chat: true)
        #expect(busy.contains(.server(2)) && busy.contains(.chat))
    }

    @Test func waitingTasksDoNotPostpone() {
        let j = job()
        queue.jobs = [j]
        let p = Probe(), g = gate(p)
        #expect(!g.postpone { p.calls += 1 } && queue.frozen && !g.isPending)
    }

    @Test func workBegunBeforeTheAnswerPostponesAgain() async {
        let j = job(), p = Probe(), g = gate(p)
        j.state = .running
        queue.jobs = [j]
        #expect(g.postpone { p.calls += 1 })
        j.state = .done
        await until { !p.asked.isEmpty }
        j.state = .running
        p.answer(true)
        await settle()
        #expect(p.calls == 0 && p.asked.isEmpty && g.isPending && !queue.frozen)
        j.state = .done
        await until { !p.asked.isEmpty }
        #expect(p.asked.count == 1)
        p.answer(true)
        #expect(p.calls == 1)
    }

    @Test func laterAsksNoMoreButTheButtonWorks() async {
        let j = job(), p = Probe(), g = gate(p)
        j.state = .running
        queue.jobs = [j]
        #expect(g.postpone { p.calls += 1 })
        j.state = .done
        await until { !p.asked.isEmpty }
        p.answer(false)
        j.state = .running
        j.state = .done
        await settle()
        #expect(p.calls == 0 && p.asked.isEmpty && g.isPending && !queue.frozen)
        g.restart()
        #expect(p.calls == 1)
    }

    @Test func quitOfTheUpdaterIsCancelledWhenBusy() async {
        let j = job(), p = Probe(), g = gate(p)
        j.state = .running
        queue.jobs = [j]
        // An ordinary quit isn't stopped.
        #expect(g.mayTerminate(byUpdater: false) && !g.isPending)
        #expect(!g.mayTerminate(byUpdater: true) && g.isPending && !queue.frozen)
        g.cancel()
        j.state = .done
        #expect(g.mayTerminate(byUpdater: true))
    }

    @Test func frozenQueueStartsNothing() async {
        let p = Probe(), g = gate(p)
        #expect(!g.postpone {} && queue.frozen)
        queue.add(job())
        await settle()
        #expect(agent.runs.isEmpty && !queue.paused)
        // The update ended without a restart.
        g.cancel()
        await until { !agent.runs.isEmpty }
        #expect(!queue.frozen && !agent.runs.isEmpty)
    }

    @Test func quitThatNeverCameThawsTheQueue() async {
        let p = Probe(), g = gate(p, thawAfter: 0.2)
        #expect(!g.postpone {} && queue.frozen)
        await until { !queue.frozen }
        #expect(!queue.frozen)
    }
}
