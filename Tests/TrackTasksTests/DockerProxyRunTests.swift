import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

private let agentImage: DockerEngine? = DockerEngine.find().flatMap { $0.isUp && $0.hasImage(DockerImage.tag) ? $0 : nil }

/// The app's own image and the closed network. Needs the image (Settings → Docker) and the internet.
@MainActor @Suite("Docker: прокси", .serialized, .enabled(if: agentImage != nil, "нет Docker или образа приложения"))
struct DockerProxyRunTests {
    let engine: DockerEngine, dir: URL, main: URL, wt: Worktrees.Info
    let instance = "test-" + UUID().uuidString

    init() throws {
        engine = try #require(agentImage)
        dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/tt-px-\(UUID().uuidString)")
        main = dir.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        try "old\n".write(to: main.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "---\ntitle: T\nstatus: todo\n---\n".write(to: main.appendingPathComponent("tasks/t.md"), atomically: true, encoding: .utf8)
        for a in [["init", "-q"], ["config", "user.name", "t"], ["config", "user.email", "t@t"], ["add", "a.txt"], ["commit", "-qm", "c"]] {
            #expect(Worktrees.git(a, in: main).ok)
        }
        let path = dir.appendingPathComponent("wt")
        #expect(Worktrees.git(WorktreeGit.add(branch: "b", path: path.path, base: "HEAD"), in: main).ok)
        wt = Worktrees.Info(path: path, main: main, branch: "b")
        try ContainerSpec.gitLink.write(to: dir.appendingPathComponent("seal"), atomically: true, encoding: .utf8)
    }

    private func make(_ sh: String, domains: [String] = DockerProxy.defaultDomains) -> DockerRun {
        DockerRun(engine, ContainerSpec(image: DockerImage.tag, worktree: wt.path, gitSeal: dir.appendingPathComponent("seal"),
                                        command: ["sh", "-c", sh], instance: instance, job: "j"),
                  proxy: DockerProxy(image: DockerImage.tag, domains: domains))
    }

    private func leftovers() -> String {
        engine.run(["ps", "-a", "-q", "--filter", "label=\(ContainerSpec.instanceLabel)=\(instance)"]).out
            + engine.run(["network", "ls", "-q", "--filter", "label=\(ContainerSpec.instanceLabel)=\(instance)"]).out
    }

    /// Prints one line per attempt: name and what happened.
    private static let probe = #"""
    cat > /tmp/p.js <<'E'
    const net=require('net'),dns=require('dns');
    const via=t=>new Promise(r=>{const s=net.connect(3128,'tracktasks-proxy',()=>s.write('CONNECT '+t+' HTTP/1.1\r\n\r\n'));
      s.on('data',d=>{r(String(d).split('\r\n')[0]);s.destroy()});s.on('error',e=>r(e.code));setTimeout(()=>r('timeout'),9000)});
    const tcp=(h,p)=>new Promise(r=>{const s=net.connect(p,h,()=>{r('OPEN');s.destroy()});s.on('error',e=>r(e.code));setTimeout(()=>{s.destroy();r('timeout')},4000)});
    (async()=>{
      for (const t of ['api.anthropic.com:443','example.com:443','api.anthropic.com:80','1.1.1.1:443','host.docker.internal:443','local.test.nip.io:443','127.0.0.1.nip.io:443']) console.log('via',t,await via(t));
      for (const [h,p] of [['1.1.1.1',443],['example.com',443],['host.docker.internal',80],['192.168.65.254',80],['192.168.65.2',53],['172.17.0.1',80]]) console.log('tcp',h,await tcp(h,p));
    })();
    E
    node /tmp/p.js
    """#

    @Test func onlyListedDomains() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = make(Self.probe, domains: ["api.anthropic.com", "127.0.0.1.nip.io"])
        let o = await Task.detached { r.run(timeout: 120) }.value
        let lines = o.result.out.split(separator: "\n").map(String.init)
        #expect(lines.count == 13, "\(o.result)")
        #expect(lines.contains("via api.anthropic.com:443 HTTP/1.1 200 OK"), "\(o.result)")
        for l in lines where l.hasPrefix("via") && !l.hasPrefix("via api.anthropic.com:443") { #expect(l.contains("403"), "\(l)") }
        for l in lines where l.hasPrefix("tcp") { #expect(!l.contains("OPEN"), "\(l)") }
        #expect(leftovers() == "")
    }

    @Test(arguments: [0, 600, 3000]) func stopRemovesNetwork(ms: Int) async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = make("sleep 300")
        async let o = Task.detached { r.run(timeout: 120) }.value
        try await Task.sleep(for: .milliseconds(ms))
        await Task.detached { _ = r.stop() }.value
        #expect(await o.stopped)
        #expect(leftovers() == "")
    }

    /// A crash leaves everything behind; the folder's own cleanup takes it all.
    @Test func leftoversAreRemoved() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = make("sleep 300"), e = engine, i = instance
        #expect(await Task.detached { r.create().ok }.value)
        #expect(leftovers() != "")
        #expect(await Task.detached { e.removeAll(instance: i, job: "j") }.value == nil)
        #expect(leftovers() == "")
    }

    /// The real CLI in the container with a token that is not one: it must reach the API and be refused there.
    @Test func realClaudeReachesTheAPI() async throws {
        let store = ContainerStore(root: dir.appendingPathComponent("store/containers"))
        try store.mark(wt)
        var h = DockerHost(engine: engine, image: DockerImage.tag)
        h.proxy = DockerProxy(image: DockerImage.tag, domains: DockerProxy.defaultDomains)
        h.token = { "sk-ant-oat01-not-a-token" }
        let run = DockerAgentRun(.init(host: h, worktree: wt, taskFile: "t.md", store: store))
        var result: AgentRunResult?, said = ""
        run.onEvent = { if case .text(let t) = $0 { said += t + "\n" } }
        run.onExit = { result = $0 }
        try run.start(AgentRequest(cwd: wt.path, prompt: "ok", access: .coding))
        let until = Date().addingTimeInterval(120)
        while result == nil, Date() < until { try await Task.sleep(for: .milliseconds(100)) }
        let s = try #require(result)
        #expect(s.failed && s.sessionID != nil, "\(s)")
        #expect((s.resultText + s.errorText + said).range(of: "401|authenticat", options: [.regularExpression, .caseInsensitive]) != nil, "\(s) \(said)")
        #expect(store.refusal(wt.path) == nil)
        let e = engine, f = wt.path
        #expect(await Task.detached { store.host = h; return store.release(f) }.value == nil)
        let job = ContainerStore.key(wt.path)
        for a in [["ps", "-a", "-q"], ["network", "ls", "-q"]] {
            #expect(e.run(a + ["--filter", "label=\(ContainerSpec.jobLabel)=\(job)"]).out == "")
        }
        try? FileManager.default.removeItem(at: dir)
    }
}
