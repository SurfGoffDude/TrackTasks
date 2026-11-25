import Foundation
import Testing
@testable import TrackTasksCore
@testable import TrackTasks

/// Event rules through the real queue and git; the agent, Keychain and the clock are fake.
@MainActor @Suite(.serialized) struct EventRulesTests {
    final class World {
        var now = Date()
        var mode = DangerMode()
        var project: Project
        init(_ p: Project) { project = p }
    }
    final class Vault: @unchecked Sendable {
        private let lock = NSLock()
        private var d: [String: String] = [:]
        func get(_ k: String) -> String { lock.lock(); defer { lock.unlock() }; return d[k] ?? "" }
        func set(_ k: String, _ v: String) -> Bool { lock.lock(); defer { lock.unlock() }; d[k] = v; return true }
    }
    let dir: URL, main: URL, agent: FakeAgent, queue: JobQueue, world: World, vault = Vault()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-events-\(UUID().uuidString)")
        main = dir.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main.appendingPathComponent("automations"), withIntermediateDirectories: true)
        try Data("---\nname: p\nverify: \"true\"\n---\n".utf8).write(to: main.appendingPathComponent("about.md"))
        let a = FakeAgent("fake", [.resume, .permissions, .bypass])
        agent = a
        let w = World(Codec.project(at: main, category: "c"))
        world = w
        queue = JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([a]),
                         profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "F", agent: a.id, model: "m")], defaultID: "fake") },
                         dangerMode: { w.mode }, recordSpend: { _, _, _, _ in })
        queue.paused = true
    }
    private func cleanUp() {
        let key = main.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "__")
        try? FileManager.default.removeItem(at: Worktrees.root.appendingPathComponent(key))
        try? FileManager.default.removeItem(at: dir)
    }
    private var file: URL { main.appendingPathComponent("automations/a.md") }
    private var rule: EventRule { world.project.eventRules[0] }
    private func write(_ lines: String = "on: webhook\nfields: [msg]", queue: Bool = true, enabled: Bool = true, body: String = "Текст") throws {
        try Data("---\ntitle: \"Событие\"\nenabled: \(enabled)\n\(lines)\nqueue: \(queue)\n---\n\n\(body)\n".utf8).write(to: file)
        reread()
    }
    private func reread() { world.project = Codec.project(at: main, category: "c") }
    private func make(_ store: String = "events.json") async throws -> EventRules {
        let w = world, v = vault
        let e = EventRules(jobs: queue, projects: { [w.project] }, storeURL: dir.appendingPathComponent(store),
                           secretStore: .init(get: { v.get($0) }, set: { v.set($0, $1) }), now: { w.now }, usesServer: false)
        e.refresh()
        for _ in 0..<200 where rule.isActive && rule.isRemote && e.stopped == nil && e.saveError == nil && e.secretKnown[rule.id] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        return e
    }
    private func secret(_ e: EventRules) async throws -> String { try await e.renewSecret(rule).get() }
    private func request(_ e: EventRules, _ secret: String, _ body: String = #"{"msg":"hi"}"#, nonce: String = UUID().uuidString) -> EventRequest {
        let t = String(Int(world.now.timeIntervalSince1970)), b = Data(body.utf8)
        return EventRequest(id: e.state.entries[rule.id]?.id ?? "", headers: [
            "x-tracktasks-timestamp": t, "x-tracktasks-nonce": nonce,
            "x-tracktasks-signature": EventSignature.sign(EventSignature.signed(time: t, nonce: nonce, body: b), secret: secret)], body: b)
    }
    private func tasks(_ f: TaskFolder) -> [TaskItem] { Codec.rawTasks(in: f.url(in: main.appendingPathComponent("tasks"))) }
    private func outcomes(_ e: EventRules) -> [EventState.Record.Outcome] { e.state.entries[rule.id]?.history.map(\.outcome) ?? [] }

    @Test func wrongSignatureAndReplayAreRefused() async throws {
        defer { cleanUp() }
        try write()
        let e = try await make()
        // No secret yet: nothing can be signed.
        #expect(await e.handle(request(e, "")) == .denied)
        let s = try await secret(e)
        #expect(await e.handle(request(e, "чужой")) == .denied)
        var other = request(e, s)
        other.id = String(repeating: "0", count: 32)
        #expect(await e.handle(other) == .denied)
        var changed = request(e, s)
        changed.body = Data(#"{"msg":"ho"}"#.utf8)
        #expect(await e.handle(changed) == .denied)
        #expect(tasks(.drafts).isEmpty && outcomes(e).isEmpty)

        let good = request(e, s)
        #expect(await e.handle(good).status == 202)
        #expect(await e.handle(good).status == 409)
        // After a restart too.
        let again = try await make()
        #expect(await again.handle(good).status == 409)
        #expect(tasks(.drafts).count == 1 && again.rejected[rule.id]?[.replay] == 1)
        // A new secret ends the old one.
        _ = try await secret(again)
        #expect(await again.handle(request(again, s)) == .denied)
    }

    @Test func twoEqualRequestsAtOnceMakeOneTask() async throws {
        defer { cleanUp() }
        try write()
        let e = try await make()
        let r = request(e, try await secret(e))
        async let a = e.handle(r)
        async let b = e.handle(r)
        #expect(await [a.status, b.status].sorted() == [202, 409])
        #expect(tasks(.drafts).count == 1)
    }

    @Test func githubReplayWithAnotherDelivery() async throws {
        defer { cleanUp() }
        try write("on: github\nevents: [issues.opened]\nfields: [issue.title]")
        let e = try await make()
        let s = try await secret(e), b = Data(#"{"action":"opened","issue":{"title":"t"}}"#.utf8)
        func send(_ delivery: String, _ event: String = "issues", _ secret: String) async -> Int {
            await e.handle(EventRequest(id: e.state.entries[rule.id]!.id, headers: [
                "x-hub-signature-256": EventSignature.sign(b, secret: secret), "x-github-event": event, "x-github-delivery": delivery], body: b)).status
        }
        #expect(await send("1", "issues", "чужой") == 401)
        #expect(await send("1", "push", s) == 400)
        #expect(await send("1", "issues", s) == 202)
        #expect(await send("2", "issues", s) == 409)
        #expect(tasks(.drafts).count == 1)
    }

    @Test func withoutPermissionOnlyADraft() async throws {
        defer { cleanUp() }
        try write()
        let e = try await make()
        let s = try await secret(e)
        #expect(await e.handle(request(e, s)).status == 202)
        #expect(e.allowQueue(rule) == nil)
        // The file was edited after the permission, the list in memory is old.
        let stale = world.project
        try write(body: "Другой текст")
        world.project = stale
        #expect(await e.handle(request(e, s)).status == 202)
        #expect(tasks(.drafts).count == 2 && tasks(.active).isEmpty && queue.jobs.isEmpty && outcomes(e) == [.draft, .draft])
        // Switched off on disk: refused.
        try write(enabled: false)
        world.project = stale
        #expect(await e.handle(request(e, s)).status == 403)
        #expect(tasks(.drafts).count == 2)
        // Allowed, but the rule doesn't ask.
        try write(queue: false)
        #expect(e.allowQueue(rule) != nil)
        #expect(await e.handle(request(e, s)).status == 202)
        #expect(tasks(.drafts).count == 3 && queue.jobs.isEmpty)
    }

    @Test func allowedGoesToTheQueueAsForeignWork() async throws {
        defer { cleanUp() }
        try write()
        for a in [["init", "-q", "-b", "main"], ["config", "user.name", "t"], ["config", "user.email", "t@t"],
                  ["config", "commit.gpgsign", "false"], ["add", "-A"], ["commit", "-q", "-m", "base"]] { #expect(Worktrees.git(a, in: main).ok) }
        reread()
        let on = world.mode.enable(main.path, name: "p", typed: "p", .hour, autopilot: true, verify: "true", now: Date().addingTimeInterval(-1))
        #expect(on)
        let e = try await make()
        let s = try await secret(e)
        #expect(e.allowQueue(rule) == nil)
        let evil = "$(touch \(dir.path)/pwned) `touch \(dir.path)/pwned`"
        #expect(await e.handle(request(e, s, "{\"msg\":\"\(evil)\"}")).status == 202)
        let j = try #require(queue.jobs.first), t = try #require(tasks(.active).first)
        #expect(queue.jobs.count == 1 && outcomes(e) == [.queued] && j.foreignSource && j.scheduled)
        #expect(!queue.allows(.fullAccess, j) && !queue.allows(.merge, j) && !queue.allows(.approvePlan, j))
        #expect(t.body.contains(evil) && t.source.hasPrefix("event:") && t.automation == "a.md")
        for text in [j.title, j.prompt, j.systemPrompt, j.verifyCommand ?? "", t.title, t.fileName, t.agent, t.source] { #expect(!text.contains("touch")) }
        // The previous task is open: a draft.
        reread()
        #expect(await e.handle(request(e, s)).status == 202)
        #expect(queue.jobs.count == 1 && tasks(.drafts).count == 1)

        queue.paused = false
        for _ in 0..<500 where agent.runs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let run = try #require(agent.runs.first?.request)
        #expect(!run.bypassPermissions && !run.prompt.contains("touch") && !(j.worktree?.branch ?? "").contains("touch"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwned").path))
        agent.runs.first?.finish { $0.stopped = true }
        queue.paused = true
    }

    @Test func eleventhAnHourIsRefused() async throws {
        defer { cleanUp() }
        try write()
        let e = try await make()
        let s = try await secret(e)
        for _ in 0..<10 { #expect(await e.handle(request(e, s, #"{"msg":"ТЕЛО"}"#)).status == 202) }
        #expect(await e.handle(request(e, s)).status == 429)
        #expect(tasks(.drafts).count == 10)
        world.now = world.now.addingTimeInterval(3601)
        #expect(await e.handle(request(e, s)).status == 202)
        let disk = try String(contentsOf: dir.appendingPathComponent("events.json"), encoding: .utf8)
        #expect(!disk.contains(s) && !disk.contains("ТЕЛО") && !disk.contains("sha256"))
    }

    @Test func unreadableOrUnwritableStateAcceptsNothing() async throws {
        defer { cleanUp() }
        try write()
        let e = try await make()
        let s = try await secret(e)
        let r = request(e, s)
        try Data("oops".utf8).write(to: dir.appendingPathComponent("bad.json"))
        let broken = try await make("bad.json")
        #expect(await broken.handle(r).status == 503)
        // The folder of the state cannot be written any more.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        #expect(await e.handle(r).status == 503)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        #expect(tasks(.drafts).isEmpty)
    }

    @Test func gitCommits() async throws {
        defer { cleanUp() }
        func git(_ a: String...) { #expect(Worktrees.git(a, in: main).ok, "\(a)") }
        func commit(_ m: String) { git("commit", "-q", "--allow-empty", "-m", m) }
        git("init", "-q", "-b", "main"); git("config", "user.name", "t"); git("config", "user.email", "t@t"); git("config", "commit.gpgsign", "false")
        commit("base")
        try write("on: git\nbranches: [main, dev]")
        let e = try await make()
        await e.checkGit(rule, in: world.project)
        #expect(tasks(.drafts).isEmpty && e.state.entries[rule.id]?.refs?.keys.sorted() == ["main"])
        commit("## Находки"); commit("две")
        await e.checkGit(rule, in: world.project)
        await e.checkGit(rule, in: world.project)
        let t = try #require(tasks(.drafts).first)
        #expect(tasks(.drafts).count == 1 && t.body.contains("две") && SpecDoc.findings(in: t.body).isEmpty && !t.body.contains("base"))
        // A task branch, a new branch, a rewritten and a deleted one are not new commits.
        git("checkout", "-q", "-b", "tracktasks/x"); commit("x")
        git("checkout", "-q", "-b", "dev"); commit("y")
        await e.checkGit(rule, in: world.project)
        git("commit", "-q", "--amend", "--allow-empty", "-m", "z")
        await e.checkGit(rule, in: world.project)
        git("checkout", "-q", "main"); git("branch", "-D", "dev")
        await e.checkGit(rule, in: world.project)
        #expect(tasks(.drafts).count == 1 && e.state.entries[rule.id]?.refs?.keys.sorted() == ["main"])
        // Off and on again: only a starting point.
        try write("on: git\nbranches: [main, dev]", enabled: false)
        e.refresh()
        commit("пока выключено")
        try write("on: git\nbranches: [main, dev]")
        e.refresh()
        await e.checkGit(rule, in: world.project)
        // The look started by `refresh` itself is in line by now: this one ends after it, however busy the machine is.
        await e.checkGit(rule, in: world.project)
        #expect(tasks(.drafts).count == 1)
        // Missed while the app was closed: one event.
        commit("a"); commit("b")
        let again = try await make()
        for _ in 0..<200 where tasks(.drafts).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        await again.checkGit(rule, in: world.project)
        #expect(tasks(.drafts).count == 2)
    }
}
