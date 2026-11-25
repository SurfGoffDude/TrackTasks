import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// The real queue, worktrees, setup and verify in real containers; a script stands in for claude.
/// Skipped without Docker or the image (see `TestDocker`).
@MainActor @Suite("Docker: очередь", .serialized, .enabled(if: TestDocker.engine != nil, "нет Docker или образа"))
struct DockerQueueTests {
    let dir: URL, main: URL, mark: URL, task: URL

    init() throws {
        // Under the home folder: Docker Desktop shares it.
        dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/tt-dq-\(UUID().uuidString)")
        main = dir.appendingPathComponent("main")
        mark = dir.appendingPathComponent("host-mark")
        task = main.appendingPathComponent("tasks/20260101-000000-t.md")
        try FileManager.default.createDirectory(at: main.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        try "old\n".write(to: main.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "tasks/\nabout.md\n".write(to: main.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "---\ntitle: T\nstatus: todo\npriority: low\nexecutor: docker\n---\nтекст\n".write(to: task, atomically: true, encoding: .utf8)
        try "секрет".write(to: dir.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        for a in [["init", "-q"], ["config", "user.name", "t"], ["config", "user.email", "t@t"], ["add", "-A"], ["commit", "-qm", "c"]] {
            #expect(Worktrees.git(a, in: main).ok)
        }
    }

    /// Reads the prompt, does `work`, answers like claude.
    private func host(_ work: String) throws -> DockerHost {
        let script = """
        read line
        echo '{"type":"system","subtype":"init","session_id":"s1","model":"m","tools":[],"mcp_servers":[]}'
        \(work)
        echo '{"type":"result","subtype":"success","is_error":false,"result":"готово","session_id":"s1","num_turns":1,"total_cost_usd":0.1,"usage":{}}'
        """
        var h = DockerHost(engine: try #require(TestDocker.engine), image: TestDocker.image)
        h.program = ["sh", "-c", script, "claude"]
        h.sessions = false
        ContainerStore.shared.host = h
        return h
    }

    private func queue(_ h: DockerHost) -> JobQueue {
        JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([ClaudeAgent()]),
                 profiles: { AgentProfiles(custom: [AgentProfile(id: "c", title: "c", agent: .claude, model: "m")], defaultID: "c") },
                 docker: h, dangerMode: { DangerMode() }, recordSpend: { _, _, _, _ in })
    }

    private func job(verify: String = "") -> Job {
        let j = Job(kind: .runTask, title: "T", projectID: nil, projectName: "p", cwd: main, prompt: "сделай", systemPrompt: "s", taskPath: task.path)
        j.verifyCommand = verify
        return j
    }

    private func wait(_ what: String, _ seconds: Double = 60, _ done: () -> Bool) async throws {
        let until = Date().addingTimeInterval(seconds)
        while !done(), Date() < until { try await Task.sleep(for: .milliseconds(50)) }
        #expect(done(), "не дождались: \(what)")
    }

    private func clean(_ j: Job) {
        if let w = j.worktree { Worktrees.remove(w, deleteBranch: true, force: true) }
        ContainerStore.shared.host = nil
        let key = main.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "__")
        // Only when empty.
        rmdir(Worktrees.root.appendingPathComponent(key).path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func containers(_ w: Worktrees.Info) -> [String]? {
        guard let e = TestDocker.engine else { return nil }
        let r = e.run(["ps", "-a", "-q", "--filter", "label=\(ContainerSpec.jobLabel)=\(ContainerStore.key(w.path))"])
        return r.ok ? r.out.split(separator: "\n").map(String.init) : nil
    }

    @Test func wholeJob() async throws {
        let secret = dir.appendingPathComponent("secret.txt").path
        let h = try host("""
        { cat '\(secret)' '\(main.path)/a.txt'; ls /var/run/docker.sock /Users; } >seen.txt 2>/dev/null
        echo new > a.txt
        mkdir -p .claude; echo '{"hooks":{}}' > .claude/settings.json
        sed -i 's/status: todo/status: done/' tasks/20260101-000000-t.md
        """)
        let q = queue(h), j = job(verify: "grep -q new a.txt && ! touch '\(mark.path)' && echo ok > verified.txt")
        defer { clean(j) }
        q.add(j)
        try await wait("конец") { q.jobs.allSatisfy { !$0.isActive } }
        #expect(j.state == .done && !j.verifyFailed, "\(j.lastLine) \(j.verifyNote) \(j.log)")
        let w = try #require(j.worktree)
        #expect(try String(contentsOf: w.path.appendingPathComponent("seen.txt"), encoding: .utf8) == "")
        #expect(!FileManager.default.fileExists(atPath: mark.path))
        // The result is an ordinary branch and diff.
        #expect(j.committed)
        let sections = await DiffLoader.load(DiffSource(job: j))
        #expect(sections.flatMap(\.entries).contains { $0.file.newPath == "a.txt" })
        #expect(Worktrees.git(["show", "\(w.branch):a.txt"], in: main).out == "new\n")
        #expect(try String(contentsOf: task, encoding: .utf8).contains("status: done"))
        #expect(!FileManager.default.fileExists(atPath: w.path.appendingPathComponent("tasks/20260101-000000-t.md").path))
        #expect(containers(w) == [])
        #expect(ContainerStore.shared.refusal(w.path) == nil)
        // The check of a merge runs in the container too.
        let r = await MergeRunner.run(w, allowed: .files([]), token: MergeToken())
        if case .merged = r.outcome {} else { Issue.record("\(r.outcome)") }
        #expect(try String(contentsOf: main.appendingPathComponent("a.txt"), encoding: .utf8) == "new\n")
        #expect(!ContainerStore.shared.isContainer(w.path))
        j.worktree = nil
    }

    @Test func mergeCheckRunsInContainer() async throws {
        let q = queue(try host("echo new > a.txt")), j = job()
        defer { clean(j) }
        q.add(j)
        try await wait("конец") { q.jobs.allSatisfy { !$0.isActive } }
        let w = try #require(j.worktree)
        try "---\nname: P\nverify: touch '\(mark.path)'\n---\n".write(to: main.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
        let r = await MergeRunner.run(w, allowed: .files([]), token: MergeToken())
        #expect(r.outcome == .red)
        #expect(!FileManager.default.fileExists(atPath: mark.path))
    }

    /// The task's own check goes where the project's one does; a Mac one is refused.
    @Test func taskCheckRunsInContainer() async throws {
        let q = queue(try host("echo new > a.txt")), j = job()
        defer { clean(j) }
        q.add(j)
        try await wait("конец") { q.jobs.allSatisfy { !$0.isActive } }
        let w = try #require(j.worktree)
        let store = TaskVerifyStore(nil)
        func run(_ cmd: String) async throws -> SafeMerge.Report {
            try "---\ntitle: T\nstatus: done\nverify: \(Frontmatter.quote(cmd))\n---\n".write(to: task, atomically: true, encoding: .utf8)
            store.approve(cmd, main, task.lastPathComponent)
            return await MergeRunner.run(w, allowed: .files([]), token: MergeToken(),
                                         task: TaskVerifyGate(project: main, task: task, queued: nil, severalRepos: false, folder: w.path, store: store), keep: true)
        }
        #expect(try await run("touch '\(mark.path)'").outcome == .red)
        #expect(!FileManager.default.fileExists(atPath: mark.path))
        if case .failed(let why) = try await run("swift test").outcome { #expect(why.contains("Mac")) } else { Issue.record("swift test") }
        if case .merged = try await run("grep -q new a.txt").outcome {} else { Issue.record("не слито") }
    }

    @Test(arguments: [0, 400, 3000]) func cancelRemovesContainer(ms: Int) async throws {
        let q = queue(try host("sleep 300")), j = job()
        defer { clean(j) }
        q.add(j)
        try await wait("старт") { j.proc != nil }
        let w = try #require(j.worktree)
        try await Task.sleep(for: .milliseconds(ms))
        q.cancel(j)
        try await wait("отмена") { !j.isActive }
        #expect(j.state == .cancelled, "\(j.lastLine)")
        #expect(containers(w) == [])
        #expect(ContainerStore.shared.refusal(w.path) == nil)
    }

    @Test func cancelOfCheckRemovesContainer() async throws {
        let q = queue(try host("echo new > a.txt")), j = job(verify: "sleep 300")
        defer { clean(j) }
        q.add(j)
        try await wait("проверка") { j.verifyProcess != nil }
        let w = try #require(j.worktree)
        #expect(j.verifyProcess?.pid == nil)
        try await Task.sleep(for: .milliseconds(700))
        q.cancel(j)
        try await wait("отмена") { !j.isActive }
        #expect(j.state == .cancelled)
        #expect(containers(w) == [])
    }

    /// The setup of a docker job: in the container, and its cancel waits for the container before the folder goes.
    @Test func cancelOfSetupRemovesContainer() async throws {
        let setup = "touch '\(mark.path)'; sleep 300"
        try "---\nname: P\nsetup: \(setup)\n---\n".write(to: main.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
        let q = queue(try host("true")), j = job()
        defer { clean(j) }
        q.add(j)
        // Not approved: refused first. Approved only for this temporary folder.
        try await wait("отказ") { !j.isActive }
        let before = ScriptStore.approvals
        defer { ScriptStore.approvals = before }
        q.approveScripts(j)
        let j2 = try #require(q.jobs.last)
        try await wait("setup") { j2.setupProcess != nil }
        let w = try #require(j2.worktree)
        try await Task.sleep(for: .seconds(1))
        q.cancel(j2)
        try await wait("папка удалена") { !FileManager.default.fileExists(atPath: w.path.path) && !ContainerStore.shared.isContainer(w.path) }
        #expect(containers(w) == [])
        #expect(!FileManager.default.fileExists(atPath: mark.path))
    }

    /// A nested repository could bring commands for the host's git: nothing is committed and git is refused.
    @Test func nestedRepositoryStopsTheJob() async throws {
        let q = queue(try host("mkdir -p x/.git; echo new > a.txt; sed -i 's/todo/done/' tasks/20260101-000000-t.md")), j = job(verify: "true")
        defer { clean(j) }
        q.add(j)
        try await wait("конец") { q.jobs.allSatisfy { !$0.isActive } }
        #expect(j.state == .failed && j.lastLine.contains(".git"), "\(j.lastLine)")
        #expect(!j.committed)
        let w = try #require(j.worktree)
        #expect(ContainerStore.shared.refusal(w.path) != nil)
        #expect(!Worktrees.git(["status"], in: w.path).ok)
        #expect(try String(contentsOf: task, encoding: .utf8).contains("status: todo"))
        // Removed by hand: «Проверить снова».
        try FileManager.default.removeItem(at: w.path.appendingPathComponent("x"))
        let engine = try #require(TestDocker.engine)
        #expect(await Task.detached { ContainerStore.shared.check(w.path, engine) }.value == nil)
        #expect(Worktrees.git(["status"], in: w.path).ok)
    }

    @Test func reviewGetsTheDiff() async throws {
        let q = queue(try host("""
        if [ -e tasks/.tt-review.diff ]; then grep -q '^+new' tasks/.tt-review.diff && echo '{"type":"result","subtype":"success","is_error":false,"result":"ВЕРДИКТ: ОК","session_id":"s2","num_turns":1,"usage":{}}' && exit; exit 1; fi
        echo new > a.txt
        """)), j = job()
        defer { clean(j) }
        q.add(j)
        try await wait("конец") { q.jobs.allSatisfy { !$0.isActive } }
        // Autoreview may have done it already.
        if j.verdict == nil { q.requestReview(j) }
        try await wait("ревью") { j.verdict != nil && !q.hasActiveChild(j) }
        #expect(j.verdict == .ok, "\(j.review)")
        #expect(q.jobs.last?.executor == .docker)
    }

    /// The task file is missing: no volume, no container, the folder is open again.
    @Test func failedPreparationLeavesNothing() async throws {
        var h = try host("true")
        let q = queue(h), j = job()
        defer { clean(j) }
        q.add(j)
        try await wait("конец") { q.jobs.allSatisfy { !$0.isActive } }
        let made = try #require(Worktrees.create(for: main, title: "x", jobID: UUID(), container: true))
        let w = made.0
        j.worktree = w
        h.sessions = true
        let run = DockerAgentRun(.init(host: h, worktree: w, taskFile: "no-such.md"))
        var result: AgentRunResult?
        run.onExit = { result = $0 }
        try run.start(AgentRequest(cwd: w.path, prompt: "x", access: .coding))
        try await wait("отказ") { result != nil }
        #expect(result?.failed == true && result?.cannotStart == true)
        let name = ContainerStore.shared.volume(w.path)
        #expect(h.engine.run(["volume", "ls", "-q", "--filter", "name=\(name)"]).out == "")
        #expect(containers(w) == [])
        #expect(ContainerStore.shared.refusal(w.path) == nil)
        // From the main thread: refused at once, not frozen.
        #expect(throws: ContainerStore.Failure.self) { try ContainerStore.shared.begin(w.path, command: ["true"], host: h) }
        #expect(ContainerStore.shared.refusal(w.path) == nil)
    }

    /// Crash: the container outlived the app. At the next start it is removed and the folder is open again.
    @Test func leftoverIsRemovedAtStart() async throws {
        let h = try host("echo new > a.txt"), q = queue(h), j = job()
        defer { clean(j) }
        q.add(j)
        try await wait("конец") { q.jobs.allSatisfy { !$0.isActive } }
        let w = try #require(j.worktree)
        let root = dir.appendingPathComponent("store/containers"), a = ContainerStore(root: root)
        try a.mark(w)
        let run = try await Task.detached { try a.begin(w.path, command: ["sleep", "300"], host: h) }.value
        #expect(run.create().ok)
        let b = ContainerStore(root: root)
        b.host = h
        #expect(b.refusal(w.path) == ContainerStore.pending)
        await Task.detached { b.recover() }.value
        #expect(b.refusal(w.path) == nil)
        #expect(containers(w) == [])
        // The record is lost: closed, not open.
        try Data().write(to: root.appendingPathComponent(ContainerStore.key(w.path)).appendingPathComponent("record.json"))
        #expect(ContainerStore(root: root).refusal(w.path) != nil)
    }
}

@MainActor @Suite("Docker: отказы без демона") struct DockerRefusalTests {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-dr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: P\nexecutor: docker\n---\n".write(to: dir.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
    }

    private func queue(_ a: FakeAgent) -> JobQueue {
        JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([a]),
                 profiles: { AgentProfiles(custom: [AgentProfile(id: "fake", title: "F", agent: AgentID(rawValue: "fake"), model: "m")], defaultID: "fake") },
                 docker: DockerHost(engine: DockerEngine(cli: "/usr/bin/false"), image: "i"),
                 dangerMode: { DangerMode() }, recordSpend: { _, _, _, _ in })
    }

    private func job(_ kind: Job.Kind = .runTask) -> Job {
        Job(kind: kind, title: "T", projectID: nil, projectName: "p", cwd: dir, prompt: "x", systemPrompt: "")
    }

    @Test func planIsRefused() {
        let a = FakeAgent("fake", [.container]), q = queue(a), j = job()
        j.planPhase = .planning
        q.add(j)
        #expect(j.state == .failed && j.lastLine.contains("plan: false"), "\(j.lastLine)")
        #expect(a.runs.isEmpty)
    }

    @Test func agentWithoutContainersIsRefused() {
        let a = FakeAgent(), q = queue(a), j = job(.fix)
        j.worktree = Worktrees.Info(path: dir, main: dir, branch: "b")
        q.add(j)
        #expect(j.state == .failed && a.runs.isEmpty)
    }

    @Test func executorIsKept() throws {
        let q = queue(FakeAgent("fake", [.container, .fork, .resumeAt, .resume])), j = job()
        q.add(j)
        #expect(j.executor == .docker && q.requiresWorktree(j))
        #expect(Job(j.record).executor == .docker)
        j.agent = AgentID(rawValue: "fake")
        #expect(q.capabilities(j) == [.container, .resume])
        // about.md can't weaken a saved choice.
        try "---\nname: P\nexecutor: local\n---\n".write(to: dir.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
        #expect(JobQueue.executorRefusal(j) != nil)
        let f = job(.fix)
        f.useAgent(of: j)
        #expect(f.executor == .docker)
        var old = j.record
        old.executor = nil
        #expect(Job(old).executor == nil)
    }

    @Test func planFalseStopsThePlanOfLargeTasks() {
        var t = Codec.task(from: "---\ntitle: T\nstatus: todo\npriority: low\nsize: l\nplan: false\n---\nx\n", url: dir)
        #expect(!JobQueue.wantsPlan(t))
        t.plan = true
        #expect(JobQueue.wantsPlan(t))
    }
}
