import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

@MainActor @Suite(.serialized) struct OnboardingTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-onboarding-\(UUID().uuidString)")
    private let domain = "local.tracktasks.test.\(UUID().uuidString.prefix(8))"

    private func gate() throws -> LaunchGate {
        LaunchGate(defaults: try #require(UserDefaults(suiteName: domain)), domain: domain, dataFolder: root.appendingPathComponent("data"))
    }
    private func clean() {
        UserDefaults.standard.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    /// Everything works, every start is written down.
    private final class Env: CheckEnvironment, @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        var calls: [String] { lock.withLock { all } }
        private func add(_ s: String) { lock.withLock { all.append(s) } }

        func prepare() { add("shell") }
        func find(_ tool: CheckTool) -> String? { "/x/\(tool.rawValue)" }
        func folder(_ url: URL) -> CheckFolder { .ready }
        func developerTools() -> Bool { true }
        func run(_ tool: CheckTool, _ args: [String]) -> CheckOutput {
            add(([tool.rawValue] + args).joined(separator: " "))
            if tool == .git { return CheckOutput(ok: true, out: "git version 2.50.1") }
            return switch args.first {
            case "--help": CheckOutput(ok: true, out: "--print --input-format --permission-mode --setting-sources --strict-mcp-config --disable-slash-commands\n  auth  x")
            case "auth": CheckOutput(ok: true, out: #"{"loggedIn":true}"#)
            default: CheckOutput(ok: true, out: "2.1.0")
            }
        }
        func ghLogin() -> CheckOutput { add("gh"); return CheckOutput(ok: true) }
        func codex() async -> CheckCodex { add("codex"); return .ok("codex") }
    }

    @Test func nothingStartsBeforeAClick() async throws {
        defer { clean() }
        let g = try gate(), env = Env(), m = OnboardingModel(env: env)
        var started: [String] = []
        g.whenOpen { started.append("updates") }
        await m.look(root: root)
        for s in OnboardingModel.Step.allCases { m.step = s }
        #expect(!g.isOpen && started.isEmpty)
        #expect(env.calls == ["git --version"])
        #expect(m.blocked(agent: .claude) != nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        await m.check(root: root)
        #expect(env.calls.contains("codex") && m.blocked(agent: .claude) == nil && !m.checking)
        #expect(started.isEmpty)
    }

    @Test func skippingResumesWhatWaited() throws {
        defer { clean() }
        let g = try gate()
        var started: [String] = []
        g.whenOpen { started.append("a") }
        g.whenOpen { started.append("b") }
        g.finish()
        g.finish()
        #expect(g.isOpen && started == ["a", "b"])
        g.whenOpen { started.append("c") }
        #expect(started == ["a", "b", "c"])
        #expect(try gate().isOpen)
    }

    @Test func notShownWithSavedSettings() throws {
        defer { clean() }
        try #require(UserDefaults(suiteName: domain)).set("/p", forKey: "rootPath")
        #expect(try gate().isOpen)
        #expect(UserDefaults.standard.persistentDomain(forName: domain)?[FirstRun.doneKey] == nil)
    }

    @Test func notShownWithData() throws {
        defer { clean() }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        #expect(try !gate().isOpen)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        try Data().write(to: root.appendingPathComponent("data/queue.json"))
        #expect(try gate().isOpen)
    }

    /// Quit without an answer: asked again although the folder is saved by then.
    @Test func askedAgainAfterQuitting() throws {
        defer { clean() }
        #expect(try !gate().isOpen)
        try #require(UserDefaults(suiteName: domain)).set("/p", forKey: "rootPath")
        #expect(try !gate().isOpen)
    }

    @Test func firstTaskGoesToTheOrdinaryQueue() async throws {
        defer { clean() }
        let g = try gate(), m = OnboardingModel(env: Env())
        #expect(await m.createExample(root: root))
        let found = try #require(m.firstTask(in: Store.scan(root: root)))
        let agent = FakeAgent()
        let q = JobQueue(storeURL: root.appendingPathComponent("q/queue.json"), agents: AgentRegistry([agent]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "Fake", agent: AgentID(rawValue: "fake"), model: "m1")], defaultID: "fake") },
                         dangerMode: { DangerMode() }, projectsRoot: { root }, worktreesRoot: root.appendingPathComponent("wt"),
                         recordSpend: { _, _, _, _ in })
        q.paused = true
        let enqueue: ([TaskItem], Project) -> Void = { tasks, p in _ = q.tryEnqueue(tasks, project: p, ensureGit: { _ in nil }) }
        // Not checked yet.
        m.start(found, agent: .claude, gate: g, enqueue: enqueue)
        #expect(q.jobs.isEmpty && !g.isOpen)
        await m.check(root: root)
        m.start(found, agent: .claude, gate: g, enqueue: enqueue)
        #expect(g.isOpen && q.jobs.map(\.taskPath) == [found.task.id] && q.jobs.first?.planPhase == nil)
        q.paused = false
        q.pump()
        for _ in 0..<200 where agent.runs.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(agent.runs.count == 1)
        agent.runs.first?.stop()
    }

    @Test func takenFolderIsReported() async throws {
        defer { clean() }
        let m = OnboardingModel(env: Env())
        try FileManager.default.createDirectory(at: ExampleProject.url(in: root), withIntermediateDirectories: true)
        #expect(await !m.createExample(root: root))
        #expect(m.error.contains("Уже есть") && m.example == nil && m.firstTask(in: Store.scan(root: root)) == nil)
    }
}
