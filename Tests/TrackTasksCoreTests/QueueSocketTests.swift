import Foundation
import Testing
@testable import TrackTasksCore

/// Short path: sun_path holds 104 bytes.
private final class Place: Sendable {
    let dir = URL(fileURLWithPath: "/tmp/tt-\(UUID().uuidString.prefix(8))")
    var url: URL { dir.appendingPathComponent("ipc/tt.sock") }
    deinit { try? FileManager.default.removeItem(at: dir) }

    func mode(_ u: URL) -> Int {
        var st = stat()
        return lstat(u.path, &st) == 0 ? Int(st.st_mode & 0o777) : -1
    }

    /// Raw connection: sends bytes, returns the response (nil = closed without one).
    func raw(_ bytes: Data) throws -> QueueResponse? {
        let fd = try QueueSocket.make()
        defer { close(fd) }
        // As in QueueSocketClient: in a full parallel run the server may wait seconds for a thread.
        QueueSocket.timeout(fd, read: 60, write: 5)
        #expect(try QueueSocket.withAddress(url.path) { connect(fd, $0, $1) } == 0)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)
        guard let d = try? QueueSocket.receive(fd, limit: QueueProtocol.maxResponse) else { return nil }
        return try JSONDecoder().decode(QueueResponse.self, from: d)
    }

    func frame(_ json: String) -> Data {
        let n = UInt32(json.utf8.count).bigEndian
        return withUnsafeBytes(of: n) { Data($0) } + Data(json.utf8)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func with<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&value) } }
}

private func failure(_ f: () throws -> Void) -> QueueFailure? {
    do { try f(); return nil } catch { return error as? QueueFailure }
}

@Suite struct QueueSocketTests {
    @Test func rights() throws {
        let p = Place()
        let s = QueueSocketServer(url: p.url) { _ in QueueResponse(paused: true) }
        try s.start()
        #expect(p.mode(p.url) == 0o600)
        #expect(p.mode(p.url.deletingLastPathComponent()) == 0o700)
        #expect(try QueueSocketClient(url: p.url).send(QueueRequest(.list)).paused == true)
        s.stop()
        #expect(p.mode(p.url) == -1)
    }

    @Test func otherUserIsRejectedBeforeReading() throws {
        let p = Place()
        let calls = Box(0)
        let s = QueueSocketServer(url: p.url, peerUID: { _ in getuid() + 1 }) { _ in
            calls.with { $0 += 1 }
            return QueueResponse()
        }
        try s.start()
        #expect(failure { _ = try QueueSocketClient(url: p.url).send(QueueRequest(.list)) }?.code == .unavailable)
        #expect(try p.raw(p.frame(#"{"protocol":1,"op":"list"}"#)) == nil)
        // Unknown user is a stranger too.
        let p2 = Place()
        let s2 = QueueSocketServer(url: p2.url, peerUID: { _ in nil }) { _ in
            calls.with { $0 += 1 }
            return QueueResponse()
        }
        try s2.start()
        #expect(try p2.raw(p2.frame(#"{"protocol":1,"op":"list"}"#)) == nil)
        #expect(calls.with { $0 } == 0)
    }

    @Test func clientChecksServer() throws {
        let p = Place()
        let s = QueueSocketServer(url: p.url) { _ in QueueResponse() }
        try s.start()
        let c = QueueSocketClient(url: p.url, peerUID: { _ in getuid() + 1 })
        #expect(failure { _ = try c.send(QueueRequest(.list)) }?.message.contains("другому пользователю") == true)
    }

    @Test func appClosed() throws {
        let p = Place()
        #expect(failure { _ = try QueueSocketClient(url: p.url).send(QueueRequest(.list)) }
            == QueueFailure(.unavailable, "TrackTasks не запущен: открой приложение и повтори"))
    }

    @Test func staleSocketIsReplacedAndSecondServerRefused() throws {
        let p = Place()
        try FileManager.default.createDirectory(at: p.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Left by a crash: bound, nobody listens.
        let fd = try QueueSocket.make()
        #expect(try QueueSocket.withAddress(p.url.path) { bind(fd, $0, $1) } == 0)
        close(fd)
        #expect(failure { _ = try QueueSocketClient(url: p.url).send(QueueRequest(.list)) }?.code == .unavailable)

        let s = QueueSocketServer(url: p.url) { _ in QueueResponse() }
        try s.start()
        let second = QueueSocketServer(url: p.url) { _ in QueueResponse(paused: true) }
        #expect(failure { try second.start() }?.code == .conflict)
        second.stop()
        #expect(try QueueSocketClient(url: p.url).send(QueueRequest(.list)).paused == nil)
    }

    @Test func foreignFileIsNotDeleted() throws {
        let p = Place()
        try FileManager.default.createDirectory(at: p.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: p.url)
        let s = QueueSocketServer(url: p.url) { _ in QueueResponse() }
        #expect(failure { try s.start() }?.code == .io)
        #expect(FileManager.default.fileExists(atPath: p.url.path))
    }

    @Test func badRequests() throws {
        let p = Place()
        let s = QueueSocketServer(url: p.url) { _ in QueueResponse() }
        try s.start()
        #expect(try p.raw(p.frame("{"))?.error?.code == .usage)
        #expect(try p.raw(Data([0xff, 0xff, 0xff, 0xff]))?.error?.code == .usage)
        #expect(try p.raw(p.frame(#"{"protocol":2,"op":"list"}"#))?.error?.code == .version)
        // Client hangs up mid-frame; the server goes on.
        _ = try p.raw(Data([0, 0, 0, 50, 1]))
        #expect(try p.raw(p.frame(#"{"protocol":1,"op":"list"}"#))?.error == nil)
    }

    @Test func tooBigRequestIsNotSent() throws {
        let p = Place()
        let calls = Box(0)
        let s = QueueSocketServer(url: p.url) { _ in
            calls.with { $0 += 1 }
            return QueueResponse()
        }
        try s.start()
        func answer(_ n: Int) -> QueueRequest { QueueRequest(.answer, job: "j", text: String(repeating: "x", count: n)) }
        let c = QueueSocketClient(url: p.url)
        #expect(failure { _ = try c.send(answer(QueueProtocol.maxRequest)) }?.code == .usage)
        #expect(calls.with { $0 } == 0)
        // Checked before connecting: no server — the same answer.
        #expect(failure { _ = try QueueSocketClient(url: Place().url).send(answer(QueueProtocol.maxRequest)) }?.code == .usage)
        // Exactly at the limit goes through.
        let overhead = try JSONEncoder().encode(answer(0)).count
        _ = try c.send(answer(QueueProtocol.maxRequest - overhead))
        #expect(calls.with { $0 } == 1)
    }

    @Test func approvalsDoNotExist() throws {
        #expect(Set(QueueOp.allCases.map(\.rawValue)) == ["list", "add", "cancel", "answer", "log", "open"])
        let p = Place()
        let calls = Box(0)
        let s = QueueSocketServer(url: p.url) { _ in
            calls.with { $0 += 1 }
            return QueueResponse()
        }
        try s.start()
        for op in ["permission", "allow", "respond", "approve", "approvePlan", "approveScript", "merge", "mergeAll", "pr", "pause", "settings"] {
            #expect(try p.raw(p.frame(#"{"protocol":1,"op":"\#(op)","job":"x","allow":true}"#))?.error?.code == .usage)
        }
        #expect(calls.with { $0 } == 0)
        // Nor fields for it in the known operations.
        let r = QueueRequest(.answer, project: "p", tasks: [], withDeps: true, job: "j", text: "t", tail: 1)
        let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any]
        #expect(Set(o?.keys.map { $0 } ?? []) == ["protocol", "op", "project", "tasks", "withDeps", "job", "text", "tail"])
    }

    @Test func parallelClientsGetTheirOwnAnswers() throws {
        let p = Place()
        // Like the app: handlers take turns, a job is added once.
        let queue = Box<[String]>([])
        let s = QueueSocketServer(url: p.url) { r in
            queue.with { q in
                let t = r.tasks?.first ?? ""
                if q.contains(t) { return QueueResponse(error: QueueFailure(.conflict, t)) }
                q.append(t)
                return QueueResponse(log: [t])
            }
        }
        try s.start()
        let added = Box(0), refused = Box(0), odd = Box(0)
        // Two clients, the same twenty tasks.
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            for i in 0..<20 {
                do {
                    let r = try QueueSocketClient(url: p.url).send(QueueRequest(.add, tasks: ["t\(i)"]))
                    (r.log == ["t\(i)"] ? added : odd).with { $0 += 1 }
                } catch {
                    (error as? QueueFailure == QueueFailure(.conflict, "t\(i)") ? refused : odd).with { $0 += 1 }
                }
            }
        }
        #expect(added.with { $0 } == 20)
        #expect(refused.with { $0 } == 20)
        #expect(odd.with { $0 } == 0)
    }

    @Test func find() throws {
        func job(_ id: String, _ state: String, _ path: String? = "/p/tasks/a.md", kind: String = "runTask") -> QueueJob {
            QueueJob(id: id, kind: kind, state: state, title: id, project: "p", projectPath: "/p", taskPath: path)
        }
        let jobs = [job("AAAA1111", "done"), job("AAAA2222", "running"), job("BBBB0000", "done", kind: "review"),
                    job("CCCC0000", "failed", "/p/tasks/c.md"), job("CCCC1111", "done", "/p/tasks/c.md")]
        #expect(try QueueJob.find("aaaa1111", in: jobs).id == "AAAA1111")
        #expect(try QueueJob.find("bbbb", in: jobs).id == "BBBB0000")
        #expect(try QueueJob.find("a", in: jobs).id == "AAAA2222")
        #expect(try QueueJob.find("c.md", in: jobs).id == "CCCC1111")
        for bad in ["aaaa", "", "bbb", "zzzz"] { #expect(failure { _ = try QueueJob.find(bad, in: jobs) }?.code == .notFound) }
        let same = [job("AAAA1111", "done"), job("AAAA2222", "done", "/q/tasks/a.md")]
        #expect(failure { _ = try QueueJob.find("a.md", in: same) }?.code == .notFound)
    }

    @Test func logTail() {
        #expect(QueueResponse.tail(["a", "b", "c"], 2) == ["b", "c"])
        let big = String(repeating: "x", count: QueueProtocol.maxLog + 10)
        let t = QueueResponse.tail(["old", big], 2)
        #expect(t.count == 1 && t[0].utf8.count <= QueueProtocol.maxLog + 3)
    }
}
