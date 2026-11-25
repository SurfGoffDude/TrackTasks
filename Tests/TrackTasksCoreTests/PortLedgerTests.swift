import Testing
import Foundation
@testable import TrackTasksCore

@Suite struct PortLedgerTests {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)/ports.json") }

    @Test func parallelClaimsDiffer() async throws {
        let l = PortLedger(url: tmp(), isAlive: { _, _ in true }, isFree: { _ in true })
        let ports = await withTaskGroup(of: Int?.self) { g in
            for i in 0..<20 { g.addTask { try? l.claim(from: 5000, pid: 111, folder: "/f\(i)", name: "dev") } }
            var r: [Int] = []
            for await p in g { if let p { r.append(p) } }
            return r
        }
        #expect(ports.count == 20)
        #expect(Set(ports).count == 20)
    }

    @Test func deadProcessIsReleased() throws {
        let alive = Locked(true)
        let l = PortLedger(url: tmp(), isAlive: { pid, _ in pid != 222 || alive.value }, isFree: { _ in true })
        let a = try l.claim(from: 6000, pid: 222, folder: "/a", name: "x")
        #expect(try l.claim(from: 6000, pid: 111, folder: "/b", name: "y") != a)
        alive.value = false
        #expect(try l.claim(from: 6000, pid: 111, folder: "/c", name: "z") == a)
        #expect(l.entries().allSatisfy { $0.pid != 222 })
    }

    @Test func reusedPidIsNotOwner() throws {
        // Record of pid 333 with a start time that differs from the current process with that pid.
        let me = getpid()
        let l = PortLedger(url: tmp(), isFree: { _ in true })
        let p = try l.claim(from: 7000, pid: me, folder: "/a", name: "x")
        #expect(try l.claim(from: 7000, pid: me, folder: "/b", name: "y") != p)
        // Same pid, other start time → dead.
        let old = PortLedger.Entry(port: 7100, pid: me, started: (PortLedger.startTime(of: me) ?? 0) - 1000, folder: "/z", name: "z")
        try JSONEncoder().encode([old]).write(to: l.url)
        #expect(try l.claim(from: 7100, pid: me, folder: "/c", name: "w") == 7100)
    }

    @Test func noFreePortFails() throws {
        var l = PortLedger(url: tmp(), isAlive: { _, _ in true }, isFree: { _ in true })
        l.range = 2
        _ = try l.claim(from: 8000, folder: "/a", name: "a")
        _ = try l.claim(from: 8000, folder: "/b", name: "b")
        #expect(throws: PortLedger.Failure.noFreePort(from: 8000, to: 8001)) { try l.claim(from: 8000, folder: "/c", name: "c") }
        l.release(folder: "/a")
        #expect(try l.claim(from: 8000, folder: "/d", name: "d") == 8000)
    }

    @Test func busyPortSkipped() throws {
        let l = PortLedger(url: tmp(), isAlive: { _, _ in true }, isFree: { $0 != 9000 })
        #expect(try l.claim(from: 9000, folder: "/a", name: "a") == 9001)
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}
