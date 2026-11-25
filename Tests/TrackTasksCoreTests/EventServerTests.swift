import Foundation
import Network
import Testing
@testable import TrackTasksCore

@Suite(.serialized) struct EventServerTests {
    private let id = String(repeating: "a", count: 32)
    private func request(_ body: String = "{}", line: String? = nil, headers: String? = nil) -> Data {
        Data("\(line ?? "POST /hook/\(id) HTTP/1.1")\r\n\(headers ?? "Host: 127.0.0.1:1\r\nContent-Length: \(body.utf8.count)")\r\n\r\n\(body)".utf8)
    }
    private func status(_ d: Data) -> Int? {
        var h = EventHTTP()
        switch h.feed(d) {
        case .more: return nil
        case .request: return 200
        case .refuse(let r): return r.status
        }
    }

    @Test func parser() {
        #expect(status(request()) == 200 && status(request("")) == 200)
        #expect(status(request(line: "GET /hook/\(id) HTTP/1.1")) == 405)
        #expect(status(request(line: "POST /hook/\(id) HTTP/1.0")) == 400 && status(request(line: "POST  /hook/\(id) HTTP/1.1")) == 400)
        #expect(status(request(line: "POST /x HTTP/1.1")) == 401 && status(request(line: "POST /hook/../x HTTP/1.1")) == 401)
        for (h, code) in [("Host: localhost", 411), ("Content-Length: 2", 403), ("Host: evil.test\r\nContent-Length: 2", 403), ("Host: 127.0.0.1.evil\r\nContent-Length: 2", 403),
                          ("Host: localhost\r\nContent-Length: 2\r\nContent-Length: 2", 400), ("Host: localhost\r\nContent-Length: +2", 411),
                          ("Host: localhost\r\nContent-Length: 2\r\nTransfer-Encoding: chunked", 400), ("Host: localhost\r\nContent-Length: 2\r\nOrigin: http://x", 403),
                          ("Host: localhost\r\nContent-Length: 999999", 413), ("Host: localhost\r\nContent-Length: 1", 400), ("Host : localhost\r\nContent-Length: 2", 400),
                          ("Host: localhost\nContent-Length: 2\r\nX: y", 400), ("Host: localhost\r\n Content-Length: 2", 400), ("Host: localhost\r\nContent-Length: 2\r\nX: \u{0}", 400)] {
            #expect(status(request(headers: h)) == code, "\(h)")
        }
        #expect(status(Data(repeating: 65, count: 20_000)) == 431)
    }

    @Test func byteByByte() {
        var h = EventHTTP(), steps: [EventHTTP.Step] = []
        for b in request("{\"я\":1}") { steps.append(h.feed(Data([b]))) }
        #expect(steps.dropLast().allSatisfy { $0 == .more })
        if case .request(let r)? = steps.last { #expect(r.id == id && r.body == Data("{\"я\":1}".utf8)) } else { Issue.record("no request") }
    }

    // MARK: Real sockets

    private func start(_ s: EventServer, port: UInt16 = 0) async -> EventServer.Status {
        await withCheckedContinuation { c in
            let once = Once()
            s.start(port: port) { st in if once.first() { c.resume(returning: st) } }
        }
    }
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; defer { used = true }; return !used }
    }
    /// Blocking exchange; "" when the server just closed, nil when it could not be reached.
    private func talk(_ host: String, _ port: UInt16, _ parts: [Data], pause: UInt32 = 0) async -> String? {
        await withCheckedContinuation { c in
            DispatchQueue.global().async {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                defer { close(fd) }
                var on: Int32 = 1, t = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, 4)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
                var a = sockaddr_in()
                a.sin_family = sa_family_t(AF_INET)
                a.sin_port = port.bigEndian
                inet_pton(AF_INET, host, &a.sin_addr)
                let up = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                guard up == 0 else { return c.resume(returning: nil) }
                for p in parts {
                    _ = p.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                    if pause > 0 { usleep(pause) }
                }
                var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
                while case let n = read(fd, &buf, buf.count), n > 0 { out.append(contentsOf: buf[0..<n]) }
                c.resume(returning: String(decoding: out, as: UTF8.self))
            }
        }
    }

    @Test func servesOnlyLoopbackAndRestartsOnTheSamePort() async throws {
        let s = EventServer { r in EventResponse(202, "тело \(r.body.count)") }
        guard case .ready(let port) = await start(s) else { Issue.record("not started"); return }
        let bytes = request("{\"a\":1}").map { Data([$0]) }
        #expect(await talk("127.0.0.1", port, bytes)?.hasPrefix("HTTP/1.1 202") == true)
        #expect(await talk("127.0.0.1", port, [request(headers: "Host: localhost\r\nContent-Length: 999999")])?.hasPrefix("HTTP/1.1 413") == true)
        for ip in localAddresses() { #expect(await talk(ip, port, [request()]) == nil, "\(ip)") }

        // A taken port is an error, not another port.
        let second = EventServer { _ in .denied }
        if case .ready(let p) = await start(second, port: port) { Issue.record("second server on \(p)") }
        second.stop()
        s.stop()
        #expect(await talk("127.0.0.1", port, [request()]) == nil)
        let again = EventServer { _ in EventResponse(202, "ok") }
        var st = await start(again, port: port)
        for _ in 0..<20 where st != .ready(port) {
            try await Task.sleep(for: .milliseconds(100))
            st = await start(again, port: port)
        }
        #expect(st == .ready(port))
        again.stop()
    }

    @Test func slowClientIsCutOff() async {
        let s = EventServer(timeout: 0.5) { _ in EventResponse(202, "ok") }
        guard case .ready(let port) = await start(s) else { Issue.record("not started"); return }
        defer { s.stop() }
        let began = Date()
        #expect(await talk("127.0.0.1", port, [Data("POST /hook/".utf8)]) == "")
        #expect(Date().timeIntervalSince(began) < 4)
        #expect(await talk("127.0.0.1", port, [request()])?.hasPrefix("HTTP/1.1 202") == true)
    }

    private func localAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var out: [String] = []
        for p in sequence(first: list, next: { $0?.pointee.ifa_next }) {
            guard let i = p?.pointee, let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), i.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: 64)
            getnameinfo(a, socklen_t(a.pointee.sa_len), &host, 64, nil, 0, NI_NUMERICHOST)
            out.append(String(cString: host))
        }
        return out
    }
}
