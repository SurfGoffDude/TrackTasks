import AppKit
import Foundation
import Network
import Testing
import TrackTasksCore
import WebKit
@testable import TrackTasks

/// A comment to an element of the page: sent only by the person, the snapshot goes outside git.
@MainActor @Suite(.serialized) struct PreviewTests {
    let dir: URL, main: URL
    init() throws {
        dir = URL(fileURLWithPath: TaskRepos.canonical(FileManager.default.temporaryDirectory)).appendingPathComponent("tt-preview-\(UUID().uuidString)")
        main = dir.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        for a in [["init", "-q", "-b", "main"], ["config", "user.name", "t"], ["config", "user.email", "t@t"], ["config", "commit.gpgsign", "false"]] { _ = Worktrees.git(a, in: main) }
        try "1".write(to: main.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        for a in [["add", "-A"], ["commit", "-q", "-m", "base"]] { _ = Worktrees.git(a, in: main) }
    }

    private let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!

    private func queue(_ a: FakeAgent) -> JobQueue {
        let p = AgentProfiles(custom: [AgentProfile(id: "fake", title: "Fake", agent: AgentID(rawValue: "fake"), model: "m1")], defaultID: "fake")
        return JobQueue(storeURL: dir.appendingPathComponent("queue.json"), agents: AgentRegistry([a]), profiles: { p }, dangerMode: { DangerMode() },
                        worktreesRoot: dir.appendingPathComponent("wt"), drafts: DiffDrafts(dir: dir.appendingPathComponent("drafts")),
                        previews: PreviewDrafts(dir: dir.appendingPathComponent("previews")), recordSpend: { _, _, _, _ in })
    }

    private func element() -> PreviewElement {
        PreviewElement(path: "main > button", text: "Купить", html: "<button>Купить</button>", url: "http://localhost:3000/", x: 0, y: 0, width: 10, height: 10,
                       viewWidth: 100, viewHeight: 100)
    }

    /// A finished task with a worktree and a draft.
    private func prepared(_ a: FakeAgent) throws -> (JobQueue, Job, Worktrees.Info) {
        let q = queue(a)
        let j = Job(kind: .runTask, title: "Задача", projectID: nil, projectName: "p", cwd: main, prompt: "сделай", systemPrompt: "")
        j.state = .done
        j.profile = "fake"
        j.agent = a.id
        j.sessionID = "s1"
        let made = try #require(Worktrees.create(for: main, title: "t", jobID: j.id, root: dir.appendingPathComponent("wt")))
        j.worktree = made.0
        j.baseCommit = made.base
        q.jobs.append(j)
        q.openPreviewDraft(j)
        try q.previews.put(PreviewDraft(element: element(), comment: "сделай синей"), shot: png, for: j.id)
        return (q, j, made.0)
    }

    private func until(_ ok: () -> Bool) async throws {
        for _ in 0..<300 where !ok() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(ok())
    }

    private func send(_ q: JobQueue, _ j: Job, _ a: FakeAgent) async throws -> FakeRun {
        let n = a.runs.count
        #expect(await q.sendPreview(j, shown: q.previewMessage(j, q.previews.draft(j.id)!)!) == nil)
        try await until { a.runs.count > n && a.runs.last?.request != nil }
        return a.runs.last!
    }

    @Test func nothingIsSentByItself() async throws {
        let a = FakeAgent(), (q, j, w) = try prepared(a)
        try q.previews.put(PreviewDraft(element: element()), shot: png, for: j.id)
        q.previews.setComment("текст", for: j.id)
        q.previews.save(j.id)
        q.openPreviewDraft(j)
        q.pump()
        try await Task.sleep(for: .milliseconds(300))
        #expect(a.runs.isEmpty && j.replies.isEmpty && q.jobs.count == 1)
        #expect(!FileManager.default.fileExists(atPath: w.path.appendingPathComponent(PreviewFolder.name).path))
        // What isn't what the person saw doesn't go either.
        #expect(await q.sendPreview(j, shown: "другое") != nil)
        #expect(a.runs.isEmpty && j.replies.isEmpty)
        // After a restart the draft waits for the person.
        let after = queue(a)
        after.openPreviewDraft(j)
        #expect(after.previews.draft(j.id)?.comment == "текст" && after.previews.shot(j.id) == png)
        try await Task.sleep(for: .milliseconds(300))
        #expect(a.runs.isEmpty)
    }

    @Test func pathForAgentsWithoutImages() async throws {
        let a = FakeAgent(), (q, j, w) = try prepared(a)
        let shown = try #require(q.previewMessage(j, q.previews.draft(j.id)!))
        let r = try await send(q, j, a)
        #expect(r.request?.prompt == shown && r.request?.images.isEmpty == true && r.request?.resume == "s1")
        let name = try #require(j.replies[0].shots?.first), file = w.path.appendingPathComponent(PreviewFolder.path(name))
        #expect(shown.contains(file.path) && shown.contains("main > button") && shown.contains("<<<PAGE-ELEMENT"))
        #expect(try Data(contentsOf: file) == png)
        #expect(q.previews.draft(j.id)?.delivery?.state == .sending)
        r.onTurnStarted?()
        #expect(q.previews.draft(j.id) == nil)
        r.finish()
        try await until { !j.isActive && q.jobs.last?.isActive == false }
        // Never in the branch, gone with the worktree.
        try "2".write(to: w.path.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: w.path.appendingPathComponent(PreviewFolder.path(".gitignore")))
        #expect(Worktrees.commitAll(w, message: "m").ok)
        #expect(!Worktrees.git(["ls-tree", "-r", "--name-only", "HEAD"], in: w.path).out.contains(PreviewFolder.name))
        Worktrees.remove(w, deleteBranch: true, force: true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func imageForAgentsThatTakeIt() async throws {
        let a = FakeAgent("fake", [.resume, .images]), (q, j, _) = try prepared(a)
        let r = try await send(q, j, a)
        #expect(r.request?.images == [png] && r.request?.prompt.contains("main > button") == true && r.request?.prompt.contains(".png") == false)
        r.finish()
    }

    @Test func checkpointHasNoSnapshot() async throws {
        let a = FakeAgent(), (q, j, w) = try prepared(a)
        let r = try await send(q, j, a)
        let list = try Checkpoints.list(branch: w.branch, in: main, git: DiffLoader.runEnv)
        #expect(!list.isEmpty)
        for c in list { #expect(!Worktrees.git(["ls-tree", "-r", "--name-only", c.oid], in: main).out.contains(PreviewFolder.name)) }
        r.finish()
    }

    @Test func missingSnapshotIsARefusal() async throws {
        let a = FakeAgent("fake", [.resume, .images]), (q, j, w) = try prepared(a)
        let r = try await send(q, j, a)
        r.finish { $0.isError = true; $0.turns = 0; $0.gotResult = false }
        try await until { j.replies[0].canRepeat }
        #expect(q.previews.draft(j.id)?.delivery?.state == .unclear)
        // Repeated with the snapshot.
        q.repeatReply(j, j.replies[0])
        try await until { a.runs.count == 2 && a.runs[1].request != nil }
        #expect(a.runs[1].request?.images == [png])
        a.runs[1].finish { $0.isError = true; $0.turns = 0; $0.gotResult = false }
        try await until { j.replies[0].canRepeat }
        try FileManager.default.removeItem(at: w.path.appendingPathComponent(PreviewFolder.path(j.replies[0].shots![0])))
        let n = a.runs.count
        q.repeatReply(j, j.replies[0])
        try await until { j.replies[0].state == .failed }
        #expect(j.replies[0].error.contains("Снимок"))
        #expect(a.runs.dropFirst(n).allSatisfy { $0.request == nil })
    }

    @Test func noWorktreeNoComment() async throws {
        let a = FakeAgent(), (q, j, w) = try prepared(a)
        j.worktree = nil
        #expect(q.previewBlocked(j)?.contains("worktree") == true && q.previewMessage(j, q.previews.draft(j.id)!) == nil)
        #expect(await q.sendPreview(j, shown: "x") != nil)
        #expect(a.runs.isEmpty)
        j.worktree = w
    }

    @Test func claudeGetsImageBlocks() throws {
        #expect((ClaudeStream.opening(prompt: "п")[1]["message"] as? [String: Any])?["content"] as? String == "п")
        let m = ClaudeStream.opening(prompt: "п", images: [png])[1]["message"] as? [String: Any]
        let c = try #require(m?["content"] as? [[String: Any]])
        #expect(c.count == 2 && c[0]["type"] as? String == "image" && c[1]["text"] as? String == "п")
        let s = c[0]["source"] as? [String: String]
        #expect(s?["media_type"] == "image/png" && s?["data"] == png.base64EncodedString())
        #expect(ClaudeAgent().capabilities.contains(.images) && SSHAgent().capabilities.contains(.images))
        // The form of its image input isn't checked on a live server: it gets a path.
        #expect(!CodexAgent().capabilities.contains(.images))
    }

    // MARK: Live page

    /// HTTP server of one answer per path.
    private final class Server: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var seen: [String] = []
        var paths: [String] { lock.withLock { seen } }
        var port: Int { Int(listener.port?.rawValue ?? 0) }

        init(_ answer: @escaping @Sendable (String) -> String) async throws {
            listener = try NWListener(using: .tcp)
            listener.newConnectionHandler = { [weak self] c in
                c.start(queue: .global())
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, _, _ in
                    let path = String(decoding: d ?? Data(), as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    self?.lock.withLock { self?.seen.append(path) }
                    c.send(content: Data(answer(path).utf8), completion: .contentProcessed { _ in c.cancel() })
                }
            }
            listener.start(queue: .global())
            for _ in 0..<200 where port == 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        deinit { listener.cancel() }
    }

    nonisolated private static func html(_ s: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(s.utf8.count)\r\nConnection: close\r\n\r\n\(s)"
    }

    private func loaded(_ p: PreviewPage, _ path: String = "/") async throws {
        for _ in 0..<500 where p.web?.isLoading != false || p.web?.url?.path != path { try await Task.sleep(for: .milliseconds(20)) }
        try #require(p.web?.url?.path == path)
    }

    @Test func livePageStaysOnItsServer() async throws {
        let foreign = try await Server { _ in Self.html("foreign") }
        let f = foreign.port
        let own = try await Server { path in
            switch path {
            case "/out": "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(f)/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            case "/frame": Self.html("<iframe src='http://127.0.0.1:\(f)/frame'></iframe><img src='http://127.0.0.1:\(f)/img'><script>fetch('http://127.0.0.1:\(f)/fetch',{mode:'no-cors'}).catch(()=>0)</script><img src='/redirected'>")
            case "/redirected": "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(f)/via\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            default: Self.html("<h1 id=t>hi</h1>")
            }
        }
        let p = PreviewPage(policy: PreviewPolicy(port: own.port)) { true }
        await p.open()
        try await loaded(p)
        #expect(p.canPick)
        let base = "http://localhost:\(own.port)"
        // Redirect of the page.
        _ = p.web?.load(URLRequest(url: URL(string: base + "/out")!))
        try await until { p.outside != nil }
        #expect(p.outside?.port == f)
        try await Task.sleep(for: .milliseconds(300))
        #expect(p.web?.url?.port == own.port || p.web?.url == nil)
        // Schemes.
        for s in ["file:///etc/hosts", "data:text/html,x"] {
            _ = p.web?.load(URLRequest(url: URL(string: s)!))
            try await Task.sleep(for: .milliseconds(200))
            #expect(p.web?.url?.scheme != "file" && p.web?.url?.scheme != "data")
        }
        _ = p.web?.load(URLRequest(url: URL(string: base + "/frame")!))
        try await loaded(p, "/frame")
        try await Task.sleep(for: .milliseconds(700))
        #expect(own.paths.contains("/redirected"))
        #expect(foreign.paths.isEmpty, "\(foreign.paths)")
        let rtc = try await p.web?.callAsyncJavaScript("return typeof RTCPeerConnection", arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(rtc == "undefined")
        // The bridge isn't there.
        let bridge = try await p.web?.callAsyncJavaScript("return typeof globalThis.ttCancel", arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(bridge == "undefined")
        #expect(p.web?.configuration.websiteDataStore.isPersistent == false)
        p.close("x")
        #expect(!p.canPick && p.web == nil)
        #expect(await p.pick() == nil)
    }

    @Test func pickIsOffWhenThePortIsNotOurs() async throws {
        let own = try await Server { _ in Self.html("<h1>hi</h1>") }
        var ours = true
        let p = PreviewPage(policy: PreviewPolicy(port: own.port)) { ours }
        await p.open()
        try await loaded(p)
        #expect(p.canPick)
        ours = false
        #expect(await p.pick() == nil)
        #expect(!p.canPick && p.web == nil)
        let q = PreviewPage(policy: PreviewPolicy(port: own.port)) { false }
        await q.open()
        #expect(q.web == nil && !q.canPick)
    }

    /// Events made by the page don't pick; leaving the page cancels.
    @Test func pageCantPickItself() async throws {
        let own = try await Server { _ in Self.html("<h1 id=t>hi</h1>") }
        let p = PreviewPage(policy: PreviewPolicy(port: own.port)) { true }
        await p.open()
        try await loaded(p)
        let task = Task { await p.pick() }
        try await until { p.picking }
        try await Task.sleep(for: .milliseconds(200))
        _ = try await p.web?.callAsyncJavaScript("document.getElementById('t').dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:20,clientY:30})); document.getElementById('t').click()", arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(300))
        #expect(p.picking)
        p.cancelPick()
        #expect(await task.value?.element == nil)
        #expect(!p.picking)
    }

    /// A real click through a window.
    @Test func realClickPicks() async throws {
        let own = try await Server { _ in
            Self.html("<body style='margin:0'><button id=t style='width:200px;height:100px'>Buy<input id=i value=SECRET></button><script>window.n=0;document.getElementById('t').onclick=()=>window.n++</script>")
        }
        let p = PreviewPage(policy: PreviewPolicy(port: own.port)) { true }
        await p.open()
        try await loaded(p)
        let web = try #require(p.web)
        let win = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = web
        win.orderFrontRegardless()
        defer { win.orderOut(nil) }
        let task = Task { await p.pick() }
        try await until { p.picking }
        try await Task.sleep(for: .milliseconds(400))
        // Below the field: the button itself.
        let at = CGPoint(x: 10, y: web.bounds.height - 90)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = try #require(NSEvent.mouseEvent(with: t, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            // Straight to the view: the window of a test isn't active and would swallow the first click.
            if t == .leftMouseDown { web.mouseDown(with: e) } else { web.mouseUp(with: e) }
            try await Task.sleep(for: .milliseconds(100))
        }
        let deadline = Task { try? await Task.sleep(for: .seconds(8)); p.cancelPick() }
        let r = try #require(await task.value)
        deadline.cancel()
        #expect(r.element.path == "button#t" && r.element.width == 200 && r.element.url.hasPrefix("http://localhost:\(own.port)"))
        #expect(r.element.html.contains("<button") && !r.element.html.contains("SECRET"))
        #expect(r.png.count > 100)
        // The page didn't get the click.
        let n = try await web.callAsyncJavaScript("return window.n", arguments: [:], in: nil, contentWorld: .page) as? Int
        #expect(n == 0)
    }
}
