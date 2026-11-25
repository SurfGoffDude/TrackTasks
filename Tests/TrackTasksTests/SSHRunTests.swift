import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// A real sshd on 127.0.0.1 with its own keys, claude is a stand-in. Nothing of the user's is touched.
@MainActor @Suite(.serialized) final class SSHRunTests {
    let dir: URL, main: URL, wt: URL
    let server: RemoteServer
    let transport: RemoteTransport
    let cleanup: RemoteCleanup
    private let sshd: Process

    init() throws {
        dir = URL(fileURLWithPath: "/private/tmp/tt-ssh-\(UUID().uuidString.prefix(8))")
        let fm = FileManager.default
        main = dir.appendingPathComponent("main")
        wt = dir.appendingPathComponent("wt")
        try fm.createDirectory(at: main.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        let port = Int.random(in: 20000...60000), dir = dir
        server = RemoteServer(host: "127.0.0.1", user: NSUserName(), port: port, folder: dir.path + "/srv", claude: dir.path + "/claude")
        transport = RemoteTransport(ssh: dir.path + "/ssh", extra: ["-F", dir.path + "/ssh_config"])
        cleanup = RemoteCleanup(url: dir.appendingPathComponent("remote-runs.json"), transport: transport)
        sshd = Process()
        func sh(_ cmd: String) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-ec", "cd '\(dir.path)'; " + cmd]
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            try #require(p.terminationStatus == 0)
        }
        try sh("""
        ssh-keygen -q -t ed25519 -N '' -f host; ssh-keygen -q -t ed25519 -N '' -f id; cp id.pub keys
        printf '[127.0.0.1]:\(port) %s\\n' "$(cut -d' ' -f1,2 host.pub)" > known; cp known known.good
        printf '%s\\n' 'Port \(port)' 'ListenAddress 127.0.0.1' 'HostKey \(dir.path)/host' 'AuthorizedKeysFile \(dir.path)/keys' 'PidFile none' 'StrictModes no' 'UsePAM no' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' > sshd_config
        printf '%s\\n' 'IdentityFile \(dir.path)/id' 'IdentitiesOnly yes' 'IdentityAgent none' 'UserKnownHostsFile \(dir.path)/known' 'GlobalKnownHostsFile /dev/null' 'StrictHostKeyChecking no' > ssh_config
        git init -q main; cd main; printf 'one\\n' > a.txt; printf '.env\\nignored\\n' > .gitignore; printf 'SECRET=1\\n' > .env
        printf -- '---\\ntitle: T\\n---\\n\\nтекст\\n' > tasks/t.md; printf -- '---\\nname: P\\n---\\n' > about.md
        git add a.txt .gitignore; git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
        git config user.name t; git config user.email t@t; git config commit.gpgsign false
        git worktree add -q -b tracktasks/x ../wt
        """)
        // Stand-in for ssh failures: no network, a cut download.
        try """
        #!/bin/sh
        [ -e '\(dir.path)/down' ] && { echo 'ssh: connect to host: Connection refused' >&2; exit 255; }
        case "$*" in *' fetch '*) if [ -e '\(dir.path)/cut' ]; then rm '\(dir.path)/cut'; /usr/bin/ssh "$@" | head -c 100; echo 'client_loop: send disconnect' >&2; exit 255; fi;; esac
        case "$*" in *' append '*) if [ -e '\(dir.path)/cutup' ]; then rm '\(dir.path)/cutup'; head -c 50 | /usr/bin/ssh "$@"; exit 255; fi;; esac
        exec /usr/bin/ssh "$@"
        """.write(to: dir.appendingPathComponent("ssh"), atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        [ "$1" = --version ] && { echo '1.0 stub'; exit 0; }
        for a in "$@"; do printf '<%s>\\n' "$a"; done > '\(dir.path)/args'
        read -r a; read -r b; printf '%s' "$b" > '\(dir.path)/prompt'
        echo x >> '\(dir.path)/launches'
        echo '{"type":"system","subtype":"init","session_id":"s1","model":"m"}'
        say() { echo '{"type":"assistant","message":{"content":[{"type":"text","text":"'"$1"'"}]}}'; }
        . '\(dir.path)/body'
        echo '{"type":"result","is_error":false,"result":"готово","num_turns":1,"total_cost_usd":0.1}'
        cat > /dev/null
        """.write(to: dir.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        // The connection of an app that was closed: never comes back.
        try """
        #!/bin/sh
        [ -e '\(dir.path)/down-old' ] && exit 255
        exec '\(dir.path)/ssh' "$@"
        """.write(to: dir.appendingPathComponent("ssh-old"), atomically: true, encoding: .utf8)
        for f in ["ssh", "ssh-old", "claude"] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(f).path) }
        sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        sshd.arguments = ["-D", "-f", dir.path + "/sshd_config", "-E", dir.path + "/sshd.log"]
        sshd.standardInput = FileHandle.nullDevice
        try sshd.run()
        // A test without sshd would prove nothing: it must be visible.
        for i in 0... {
            if SSHAgent.check(server, transport: transport).hasPrefix("Готово") { break }
            try #require(i < 25, "sshd не поднялся: проверки на настоящем ssh не выполнены")
            usleep(200_000)
        }
    }

    deinit {
        sshd.terminate()
        try? FileManager.default.removeItem(at: dir)
    }

    private func body(_ s: String) throws { try s.write(to: dir.appendingPathComponent("body"), atomically: true, encoding: .utf8) }
    private func touch(_ n: String) { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: nil) }
    private func remove(_ n: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    private func text(_ n: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)) ?? "" }
    private func has(_ n: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path) }
    private var launches: Int { text("launches").split(separator: "\n").count }
    /// The network goes away: running connections die too.
    private func cutNetwork() {
        touch("down")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", dir.path + "/ssh_config"]
        try? p.run()
        p.waitUntilExit()
    }
    private func until(_ what: String = "", _ ok: () -> Bool) async throws {
        for _ in 0..<1500 where !ok() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(ok(), "\(what)")
    }

    @MainActor final class Watch {
        var events: [AgentEvent] = [], asked: [AgentPermission] = [], result: AgentRunResult?, returned = 0, offset = 0
        var texts: [String] { events.compactMap { if case .text(let t) = $0 { t } else { nil } } }
        var notes: [String] { events.compactMap { if case .tool(let t) = $0 { t } else { nil } } }
    }

    private func remoteRun() -> RemoteRun { RemoteRun(server: server, id: RemoteRun.newID(), work: RemoteRun.key(wt.path), project: "p1") }

    private func start(_ run: RemoteRun? = nil, attach: Bool = false, prompt: String = "сделай", system: String = "", access: AgentAccess = .coding,
                       cwd: URL? = nil, setup: String = "") throws -> (SSHRun, Watch, RemoteRun) {
        let run = run ?? remoteRun()
        let r = SSHRun(transport: transport, dataDir: dir.appendingPathComponent("data"), cleanup: cleanup), w = Watch()
        r.onEvent = { w.events.append($0) }
        r.onPermission = { w.asked.append($0) }
        r.onExit = { w.result = $0 }
        r.onReturned = { w.returned += 1 }
        r.onOffset = { w.offset = $0 }
        try r.start(AgentRequest(cwd: cwd ?? wt, prompt: prompt, systemPrompt: system, access: access, remote: AgentRemote(
            run: run, attach: attach, main: main, taskPath: main.appendingPathComponent("tasks/t.md"), branch: "tracktasks/x", setup: setup)))
        return (r, w, run)
    }

    private func git(_ a: String...) -> String { Worktrees.git(a, in: wt).out }

    @Test func wholeTurn() async throws {
        try body("""
        say один; echo two >> a.txt; echo new > b.txt; echo x > ignored; mkdir -p tasks automations; echo no > tasks/z.md; echo no > automations/z.md
        echo '- [x] готово' >> ../project/tasks/t.md; ls -A . ../project > '\(dir.path)/seen'
        """)
        let evil = "кавычки ' \" `touch \(dir.path)/pwned` $(touch \(dir.path)/pwned)\nвторая строка \\ конец"
        let (_, w, _) = try start(prompt: evil + " \(wt.path)/a.txt", system: "задача \(main.path)/tasks/t.md " + evil)
        try await until { w.result != nil }
        let r = w.result!
        #expect(!r.failed && r.resultText == "готово" && r.sessionID == "s1" && r.costUSD == 0.1, "\(r.errorText)")
        #expect(w.texts == ["один"])
        #expect(w.returned == 1)
        // Uncommitted in the worktree, the branch is as it was.
        #expect(git("status", "--porcelain") == " M a.txt\n?? b.txt\n")
        #expect(text("wt/a.txt") == "one\ntwo\n")
        #expect(text("main/tasks/t.md").hasSuffix("- [x] готово\n"))
        #expect(!has("pwned"))
        // JSONSerialization escapes slashes.
        let got = text("prompt").replacingOccurrences(of: "\\/", with: "/")
        #expect(got.contains("/work/") && !got.contains(wt.path))
        #expect(text("args").contains(evil) && text("args").contains("/project/tasks/t.md") && !text("args").contains(main.path + "/tasks"))
        #expect(text("seen").contains("about.md") && !text("seen").contains(".env\n"))
        // Cleaned up after the return: files of the run and local refs.
        try await until { cleanup.todo.isEmpty }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path + "/srv/runs").isEmpty)
        #expect(git("for-each-ref", "refs/tracktasks/remote").isEmpty)

        // Next turn sends only the difference and works in the same copy.
        #expect(Worktrees.commitAll(.init(path: wt, main: main, branch: "tracktasks/x"), message: "m").ok)
        try body("[ -f ignored ] && echo kept >> b.txt; rm a.txt")
        let (_, w2, _) = try start()
        try await until { w2.result != nil }
        #expect(w2.result?.failed == false, "\(w2.result?.errorText ?? "")")
        #expect(git("status", "--porcelain") == " D a.txt\n M b.txt\n")

        cleanup.release(folder: wt)
        try await until { cleanup.todo.isEmpty }
        #expect(!has("srv/work/\(RemoteRun.key(wt.path))"))
        #expect(cleanup.works.isEmpty)
    }

    @Test func lostConnectionLosesNothing() async throws {
        touch("cutup")
        try body("say один; until [ -e '\(dir.path)/go' ]; do sleep 0.2; done; say два; echo two >> a.txt")
        let (_, w, _) = try start()
        try await until("первое событие") { w.texts == ["один"] }
        cutNetwork()
        try await until("обрыв замечен") { w.notes.contains("Нет связи, работа на сервере продолжается") }
        touch("go")
        try await until("сервер закончил сам") { text("launches").isEmpty == false && ((try? FileManager.default.subpathsOfDirectory(atPath: dir.path + "/srv/runs"))?.contains { $0.hasSuffix("/done") } ?? false) }
        #expect(w.result == nil)
        touch("cut")
        remove("down")
        try await until("итог") { w.result != nil }
        #expect(!has("cut"))
        #expect(w.result?.failed == false && w.texts == ["один", "два"] && launches == 1, "\(w.result?.errorText ?? "")")
        #expect(text("wt/a.txt") == "one\ntwo\n")
        #expect(w.notes.contains("Связь с сервером восстановлена"))
    }

    @Test func permissionOutlivesTheConnection() async throws {
        try body("""
        echo '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}'
        read -r a; printf '%s' "$a" > '\(dir.path)/answer'
        """)
        let (r, w, _) = try start()
        try await until { w.asked.count == 1 }
        cutNetwork()
        r.respond(w.asked[0], allow: true, always: false)
        try await Task.sleep(for: .seconds(1))
        #expect(!has("answer"))
        remove("down")
        try await until { w.result != nil }
        #expect(text("answer").contains("\"allow\"") && w.asked.count == 1 && w.result?.failed == false)
    }

    @Test(arguments: [false, true]) func wrongHostKeyBlocks(changed: Bool) async throws {
        try body("echo two >> a.txt")
        let known = dir.appendingPathComponent("known")
        let bad = changed ? "[127.0.0.1]:\(server.port) " + text("id.pub").split(separator: " ").prefix(2).joined(separator: " ") + "\n" : ""
        try bad.write(to: known, atomically: true, encoding: .utf8)
        let (_, w, _) = try start()
        try await until { w.result != nil }
        let r = w.result!
        #expect(r.failed && r.cannotStart)
        #expect(r.errorText.contains(changed ? "изменился" : "неизвестен"))
        #expect(launches == 0 && text("known") == bad)
        // Nothing to go back to.
        #expect(w.returned == 1 && cleanup.works.isEmpty)
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: dir.path + "/srv"))?.contains("runs") ?? false))
    }

    @Test func cancelBringsBackWhatIsDone() async throws {
        try body("say один; echo two >> a.txt; sleep 300 & echo $! > '\(dir.path)/pid'; wait")
        let (r, w, _) = try start()
        try await until { has("pid") && w.texts.count == 1 }
        r.killTree()
        r.stop()
        try await until { w.result != nil }
        #expect(w.result?.stopped == true && w.returned == 1)
        #expect(text("wt/a.txt") == "one\ntwo\n")
        let pid = pid_t(text("pid").trimmingCharacters(in: .whitespacesAndNewlines))!
        #expect(kill(pid, 0) != 0)
    }

    /// The server was rebooted: what was done is still taken.
    @Test func deadRunnerIsRecovered() async throws {
        try body("say один; echo two >> a.txt; sleep 300")
        let (_, w, run) = try start()
        try await until { w.texts.count == 1 }
        let pid = try #require(pid_t(text("srv/runs/\(run.id)/pid").split(separator: "\n")[0]))
        kill(pid, SIGKILL)
        try await until { w.result != nil }
        #expect(w.result?.failed == true && w.result?.errorText.contains("оборвался") == true && w.returned == 1)
        #expect(text("wt/a.txt") == "one\ntwo\n")
    }

    @Test func cancelWithoutConnection() async throws {
        try body("say один; echo two >> a.txt; sleep 300")
        let (r, w, run) = try start()
        try await until { w.texts.count == 1 }
        cutNetwork()
        r.stop()
        try await until("остановлено локально") { w.result != nil }
        #expect(w.result?.stopped == true && w.returned == 0)
        #expect(cleanup.todo.map(\.kind) == [.stop])
        #expect(RemoteCleanup(url: dir.appendingPathComponent("remote-runs.json"), transport: transport).todo.count == 1)
        // Not deleted without the result, even with the worktree gone.
        cleanup.release(folder: wt)
        #expect(cleanup.works.first?.unclaimed == [run.id])
        remove("down")
        cleanup.kick()
        try await until("остановка подтверждена") { cleanup.todo.isEmpty }
        let (_, w2, _) = try start(run, attach: true)
        try await until { w2.result != nil }
        #expect(w2.result?.stopped == true && w2.returned == 1 && launches == 1)
        #expect(text("wt/a.txt") == "one\ntwo\n")
        try await until { cleanup.todo.isEmpty && cleanup.works.isEmpty == false || !has("srv/work/\(run.work)") }
    }

    @Test func worktreeChangedMeanwhile() async throws {
        try body("say один; until [ -e '\(dir.path)/go' ]; do sleep 0.2; done; echo two >> a.txt")
        let (_, w, run) = try start()
        try await until { w.texts.count == 1 }
        try "мой\n".write(to: wt.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        touch("go")
        try await until { w.result != nil }
        #expect(w.result?.failed == true && w.result?.errorText.contains(RemoteTransfer.resultRef(run.id)) == true)
        #expect(text("wt/a.txt") == "one\n")
        #expect(git("show", RemoteTransfer.resultRef(run.id) + ":a.txt") == "one\ntwo\n")
    }

    @Test func taskEditedOnBothSides() async throws {
        try body("say один; until [ -e '\(dir.path)/go' ]; do sleep 0.2; done; echo сервер >> ../project/tasks/t.md")
        let (_, w, _) = try start()
        try await until { w.texts.count == 1 }
        let t = main.appendingPathComponent("tasks/t.md")
        try text("main/tasks/t.md").replacingOccurrences(of: "title: T", with: "title: Человек").write(to: t, atomically: true, encoding: .utf8)
        touch("go")
        try await until { w.result != nil }
        #expect(text("main/tasks/t.md").contains("title: Человек") && text("main/tasks/t.md").hasSuffix("сервер\n"))

        // The same line: the local file wins, the other one is kept.
        remove("go")
        try body("say один; until [ -e '\(dir.path)/go' ]; do sleep 0.2; done; printf 'C' > ../project/tasks/t.md")
        let (_, w2, _) = try start()
        try await until { w2.texts.count == 1 }
        try "L".write(to: t, atomically: true, encoding: .utf8)
        touch("go")
        try await until { w2.result != nil }
        #expect(text("main/tasks/t.md") == "L")
        let note = try #require(w2.notes.first { $0.contains("Версия с сервера") })
        #expect(try String(contentsOfFile: String(note.split(separator: ": ").last!), encoding: .utf8) == "C")
    }

    @Test func setupOncePerCopyAndItsFailure() async throws {
        try body("")
        let cmd = "echo x >> '\(dir.path)/setups'"
        for _ in 0..<2 {
            let (_, w, _) = try start(setup: cmd)
            try await until { w.result != nil }
            #expect(w.result?.failed == false, "\(w.result?.errorText ?? "")")
        }
        #expect(text("setups") == "x\n")
        let (_, w, _) = try start(setup: "echo нет >&2; exit 3")
        try await until { w.result != nil }
        #expect(w.result?.cannotStart == true && w.result?.errorText.contains("setup на сервере не прошёл (3)") == true && launches == 2)
    }

    @Test func planTakesNoCodeBack() async throws {
        try body("echo two >> a.txt; printf '\\n## План\\n1. шаг\\n' >> ../project/tasks/t.md")
        let (_, w, _) = try start(access: .planning, cwd: main)
        try await until { w.result != nil }
        #expect(w.result?.failed == false && text("main/a.txt") == "one\n" && text("main/tasks/t.md").contains("## План"))
    }

    @Test func refusedRepositories() async throws {
        try body("")
        _ = Worktrees.git(["add", "-f", ".env"], in: main)
        try "x".write(to: wt.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        _ = Worktrees.git(["add", "-f", ".env"], in: wt)
        _ = Worktrees.git(["commit", "-q", "-m", "env"], in: wt)
        let (_, w, _) = try start()
        try await until { w.result != nil }
        #expect(w.result?.cannotStart == true && w.result?.errorText.contains(".env") == true && launches == 0)
    }

    /// Objects of a hostile server.
    @Test func hostileResults() throws {
        let base = try RemoteTransfer.snapshot(wt, run: "r", untracked: true)
        func result(_ path: String, _ mode: String = "100644") throws -> String {
            let blob = DiffLoader.runRaw(["hash-object", "-w", "--stdin"], in: wt, input: Data("x".utf8)).text.trimmingCharacters(in: .newlines)
            let env = ["GIT_INDEX_FILE": dir.path + "/idx-\(UUID().uuidString)"]
            #expect(DiffLoader.runEnv(["read-tree", base.commit], in: wt, env: env, input: nil).ok)
            let id = mode == "160000" ? base.commit : blob
            #expect(DiffLoader.runEnv(["update-index", "--add", "--cacheinfo", "\(mode),\(id),\(path)"], in: wt, env: env, input: nil).ok)
            let t = DiffLoader.runEnv(["write-tree"], in: wt, env: env, input: nil).text.trimmingCharacters(in: .newlines)
            return DiffLoader.runRaw(["commit-tree", t, "-p", base.commit], in: wt, input: Data("m".utf8)).text.trimmingCharacters(in: .newlines)
        }
        for (p, m) in [("tasks/x.md", "100644"), ("automations/x.md", "100644"), ("About.md", "100644"), (".claude/settings.json", "100644"), ("node_modules/x", "100644"), ("sub", "160000")] {
            let r = try result(p, m)
            #expect(throws: RemoteTransfer.Refused.self) { try RemoteTransfer.apply(wt, run: "r", base: base, result: r) }
        }
        // A file of the user that git ignores.
        try "моё".write(to: wt.appendingPathComponent("ignored"), atomically: true, encoding: .utf8)
        let over = try result("ignored")
        #expect(throws: RemoteTransfer.Changed.self) { try RemoteTransfer.apply(wt, run: "r", base: base, result: over) }
        #expect(text("wt/ignored") == "моё")
        let good = try result("dir/ok.txt")
        #expect(try RemoteTransfer.apply(wt, run: "r", base: base, result: good) == .applied)
        // The app died right after that.
        #expect(try RemoteTransfer.apply(wt, run: "r", base: base, result: good) == .already)
    }

    /// The app is restarted while the server works.
    @Test func newQueueContinuesTheRun() async throws {
        try body("say один; until [ -e '\(dir.path)/go' ]; do sleep 0.2; done; say два; echo two >> a.txt")
        let agent = SSHAgent(transport: transport, dataDir: dir.appendingPathComponent("data"), cleanup: cleanup)
        let profiles = AgentProfiles(custom: [AgentProfile(id: "box", title: "box", agent: .ssh, server: server)])
        let store = dir.appendingPathComponent("queue.json")
        var oldAgent = agent
        oldAgent.transport.ssh += "-old"
        func queue(_ agent: SSHAgent) -> JobQueue {
            let q = JobQueue(storeURL: store, agents: AgentRegistry([agent]), profiles: { profiles }, dangerMode: { DangerMode() }, recordSpend: { _, _, _, _ in })
            q.paused = false
            return q
        }
        let q1 = queue(oldAgent)
        let j = Job(kind: .runTask, title: "Задача", projectID: nil, projectName: "p", cwd: main, prompt: "сделай", systemPrompt: "")
        j.profile = "box"
        j.setupDone = true
        j.worktree = .init(path: wt, main: main, branch: "tracktasks/x")
        j.baseCommit = git("rev-parse", "HEAD").trimmingCharacters(in: .newlines)
        q1.add(j)
        try await until("событие") { j.log.contains("один") }
        try await until("записано") { text("queue.json").contains("один") }
        let id = try #require(j.remote?.id)
        // The old queue is gone together with its connection.
        j.proc?.onEvent = nil
        j.proc?.onExit = nil
        (j.proc as? any RemoteAgentRun)?.onReturned = nil
        (j.proc as? any RemoteAgentRun)?.onOffset = nil
        let snapshot = try Data(contentsOf: store)
        touch("down-old")
        cutNetwork()
        try await Task.sleep(for: .milliseconds(700))
        try snapshot.write(to: store)

        let q2 = queue(agent)
        let old = try #require(q2.jobs.first)
        #expect(old.remoteUnclaimed && old.state == .failed && old.interrupted)
        for _ in 0..<500 where old.worktreeBusy { try await Task.sleep(for: .milliseconds(20)) }
        remove("down")
        q2.retry(old)
        let new = try #require(q2.jobs.last)
        #expect(new.remote?.id == id)
        touch("go")
        try await until("готово") { !new.isActive }
        #expect(new.state == .done, "\(new.lastLine)")
        #expect(launches == 1 && new.log.filter { $0 == "один" }.isEmpty && new.log.filter { $0 == "два" }.count == 1)
        #expect(new.committed && git("show", "HEAD:a.txt") == "one\ntwo\n")
        #expect(!new.remoteUnclaimed)
        q2.paused = true
    }
}
