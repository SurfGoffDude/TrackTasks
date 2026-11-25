import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// Schedules through the real queue; only the agent and the clock are fake.
@MainActor @Suite(.serialized) struct AutomationsTests {
    final class World {
        var now: Date
        var project: Project
        init(_ now: Date, _ project: Project) { self.now = now; self.project = project }
    }
    let dir: URL, main: URL, cal: Calendar, agent: FakeAgent, queue: JobQueue
    let world: World

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-sched-\(UUID().uuidString)")
        main = dir.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main.appendingPathComponent("automations"), withIntermediateDirectories: true)
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        cal = c
        let a = FakeAgent()
        agent = a
        queue = JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([a]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "F", agent: a.id, model: "m")], defaultID: "fake") },
                         dangerMode: { DangerMode() }, recordSpend: { _, _, _, _ in })
        queue.paused = true
        world = World(c.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 10))!, Codec.project(at: main, category: "c"))
    }

    private var file: URL { main.appendingPathComponent("automations/a.md") }
    private func write(enabled: Bool = true, queue: Bool = true, body: String = "Текст", time: String = "09:00") throws {
        try Data("---\ntitle: \"Обзор\"\nenabled: \(enabled)\nschedule: daily\ntime: \(time)\nqueue: \(queue)\n---\n\n\(body)\n".utf8).write(to: file)
        reread()
    }
    private func reread() { world.project = Codec.project(at: main, category: "c") }
    private func make(_ store: String = "automations.json") -> Automations {
        let w = world, c = cal
        return Automations(jobs: queue, projects: { [w.project] }, storeURL: dir.appendingPathComponent(store),
                           now: { w.now }, calendar: { c }, usesTimer: false)
    }
    private func later(_ days: Double) { world.now = world.now.addingTimeInterval(days * 86400) }
    private var tasks: [TaskItem] { Codec.tasks(in: main.appendingPathComponent("tasks")) }
    private func settle(_ a: Automations) async throws {
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(20))
            reread()
        }
        while !a.running.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    }
    private func history(_ a: Automations) -> [AutomationState.Run] { a.state.entries[Automation.key(file)]?.history ?? [] }
    private func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    @Test func switchedOffDoesNotRun() async throws {
        defer { cleanUp() }
        try write(enabled: false)
        let a = make()
        a.refresh()
        later(7)
        a.refresh()
        try await settle(a)
        #expect(tasks.isEmpty && history(a).isEmpty && a.wakeAt == nil)
    }

    @Test func switchedOffOnDiskWhileListIsStale() async throws {
        defer { cleanUp() }
        try write()
        let a = make()
        a.refresh()
        let stale = world.project
        try write(enabled: false)
        world.project = stale
        later(1)
        a.refresh()
        try await settle(a)
        #expect(tasks.isEmpty)
    }

    @Test func weekOfSleepIsOneTaskAndRestartDoesNotRepeat() async throws {
        defer { cleanUp() }
        try write()
        let a = make()
        a.refresh()
        #expect(a.wakeAt != nil)
        later(7)
        // Wake and clock events together.
        a.refresh(); a.refresh(); a.refreshSoon()
        try await settle(a)
        #expect(tasks.count == 1 && tasks.first?.automation == "a.md" && queue.jobs.isEmpty)
        #expect(history(a).map(\.outcome) == [.created])
        var t = try #require(tasks.first)
        t.status = .done
        try Data(Codec.serialize(t).utf8).write(to: t.url)
        let again = make()
        again.refresh()
        try await settle(again)
        #expect(tasks.count == 1 && history(again).count == 1)
        later(1)
        again.refresh()
        try await settle(again)
        #expect(tasks.count == 2)
    }

    @Test func allowedGoesToThePausedQueueAndWaits() async throws {
        defer { cleanUp() }
        try write()
        let a = make()
        a.refresh()
        #expect(a.allowQueue(world.project.automations[0]) == nil)
        later(1)
        a.refresh()
        try await settle(a)
        #expect(history(a).map(\.outcome) == [.queued])
        let j = try #require(queue.jobs.first)
        #expect(queue.jobs.count == 1 && j.state == .pending && j.scheduled && agent.runs.isEmpty)
        queue.paused = false
        for _ in 0..<200 where agent.runs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(agent.runs.count == 1)
        queue.cancel(j)
    }

    @Test func editedFileLosesPermission() async throws {
        defer { cleanUp() }
        try write()
        let a = make()
        a.refresh()
        let shown = world.project.automations[0]
        try write(body: "Другой текст")
        #expect(a.allowQueue(shown) != nil)
        try write()
        #expect(a.allowQueue(shown) == nil)
        // The switch keeps it.
        #expect(await a.setEnabled(shown, false) == nil)
        reread()
        #expect(!world.project.automations[0].enabled && a.state.mayQueue(world.project.automations[0]))
        try write(body: "Другой текст")
        later(1)
        a.refresh()
        try await settle(a)
        #expect(tasks.count == 1 && queue.jobs.isEmpty && history(a).first?.outcome == .created)
    }

    @Test func unfinishedTaskSkips() async throws {
        defer { cleanUp() }
        try write()
        let a = make()
        a.refresh()
        later(1)
        a.refresh()
        try await settle(a)
        later(1)
        a.refresh()
        try await settle(a)
        #expect(tasks.count == 1 && history(a).map(\.outcome) == [.created, .skipped])
    }

    @Test func manualRunWorksSwitchedOffAndKeepsTheSlot() async throws {
        defer { cleanUp() }
        try write(enabled: false)
        let a = make()
        a.refresh()
        let before = a.state.entries[Automation.key(file)]?.since
        #expect(await a.run(world.project.automations[0], in: world.project, manual: true) == nil)
        #expect(tasks.count == 1 && a.state.entries[Automation.key(file)]?.since == before)
        #expect(await a.run(world.project.automations[0], in: world.project, manual: true) != nil)
        #expect(tasks.count == 1)
    }

    @Test func unwritableStateStopsRuns() async throws {
        defer { cleanUp() }
        try write()
        // The folder of the state file is a file.
        try Data().write(to: dir.appendingPathComponent("blocked"))
        let a = make("blocked/automations.json")
        a.refresh()
        later(1)
        a.refresh()
        try await settle(a)
        #expect(tasks.isEmpty && a.saveError != nil && a.wakeAt == nil)
    }

    @Test func corruptStateStopsRuns() async throws {
        defer { cleanUp() }
        try write()
        try Data("oops".utf8).write(to: dir.appendingPathComponent("automations.json"))
        let a = make()
        a.refresh()
        later(1)
        a.refresh()
        try await settle(a)
        #expect(a.stopped != nil && tasks.isEmpty)
    }
}
