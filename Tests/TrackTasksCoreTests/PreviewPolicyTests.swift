import Foundation
import Testing
@testable import TrackTasksCore

struct PreviewPolicyTests {
    let p = PreviewPolicy(port: 3000, others: [4000, 3000])
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test(arguments: ["http://localhost:3000", "http://localhost:3000/a?b#c", "http://127.0.0.1:3000/", "http://[::1]:3000/x", "HTTP://LOCALHOST:3000/"])
    func shown(_ s: String) { #expect(p.decide(url(s)) == .show) }

    @Test(arguments: ["https://example.com/", "http://localhost:3001/", "http://localhost:4000/", "http://localhost/", "https://localhost:3000/",
                      "http://localhost.evil.com:3000/", "http://127.0.0.1.evil.com:3000/", "http://127.0.0.2:3000/", "http://0.0.0.0:3000/",
                      "http://evillocalhost:3000/", "http://169.254.169.254/"])
    func outside(_ s: String) {
        #expect(p.decide(url(s)) == .offerOutside(url(s)))
        // A frame never asks the person.
        #expect(p.decide(url(s), mainFrame: false) == .deny)
    }

    @Test(arguments: ["file:///etc/passwd", "javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,x", "blob:http://localhost:3000/1",
                      "about:blank", "tracktasks://job/1", "ftp://localhost:3000/", "ws://localhost:3000/", "view-source:http://localhost:3000/",
                      "http://user:pw@localhost:3000/", "http://user@localhost:3000/", "http://localhost:3000@evil.com/", "https://a:b@evil.com/", "x-apple.systempreferences:"])
    func denied(_ s: String) {
        #expect(p.decide(URL(string: s)) == .deny)
        #expect(!p.canPick(URL(string: s), mainFrame: true, serverConfirmed: true))
    }

    @Test func frames() {
        #expect(p.decide(nil) == .deny)
        #expect(p.decide(url("about:srcdoc"), mainFrame: false) == .show && p.decide(url("about:blank"), mainFrame: false) == .show)
        #expect(p.decide(url("file:///a"), mainFrame: false) == .deny)
    }

    @Test func picksOnlyOnTheServersPage() {
        let here = url("http://localhost:3000/a")
        #expect(p.canPick(here, mainFrame: true, serverConfirmed: true))
        #expect(!p.canPick(here, mainFrame: false, serverConfirmed: true))
        #expect(!p.canPick(here, mainFrame: true, serverConfirmed: false))
        #expect(!p.canPick(nil, mainFrame: true, serverConfirmed: true))
        for s in ["http://localhost:4000/", "http://localhost:3001/", "https://example.com/", "http://localhost.evil.com:3000/", "about:blank"] {
            #expect(!p.canPick(url(s), mainFrame: true, serverConfirmed: true))
        }
    }

    @Test func rulesBlockEverythingElse() throws {
        let list = try #require(try JSONSerialization.jsonObject(with: Data(p.rules.utf8)) as? [[String: [String: Any]]])
        #expect(list[0]["action"]?["type"] as? String == "block" && list[0]["trigger"]?["url-filter"] as? String == ".*")
        let allowed = try list.dropFirst().map { r -> NSRegularExpression in
            #expect(r["action"]?["type"] as? String == "ignore-previous-rules")
            let f = try #require(r["trigger"]?["url-filter"] as? String)
            #expect(!f.contains("|"))
            return try NSRegularExpression(pattern: f)
        }
        func passes(_ s: String) -> Bool { allowed.contains { $0.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil } }
        for s in ["http://localhost:3000/a.js", "ws://localhost:3000/hmr", "http://[::1]:3000/", "http://127.0.0.1:4000/api", "data:image/png,x"] { #expect(passes(s)) }
        for s in ["http://localhost:30001/", "http://localhost:5000/", "https://example.com/", "http://127x0.0.1:3000/", "https://example.com/?http://localhost:3000/",
                  "ws://example.com:3000/", "file:///etc/passwd"] { #expect(!passes(s)) }
    }

    @Test func listenerOfOwnTreeOnly() throws {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import socket,time\ns=socket.socket();s.bind(('127.0.0.1',0));s.listen();print(s.getsockname()[1],flush=True);time.sleep(60)"]
        p.standardOutput = out
        try p.run()
        defer { p.terminate() }
        let port = try #require(Int(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(ProcessTree.listens(on: port, root: p.processIdentifier))
        // Somebody else's service.
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["60"]
        try other.run()
        defer { other.terminate() }
        #expect(!ProcessTree.listens(on: port, root: other.processIdentifier))
        #expect(!ProcessTree.listens(on: 1, root: p.processIdentifier))
    }
}
