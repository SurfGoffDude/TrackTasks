import Foundation
import XCTest
@testable import TrackTasks

/// git must not need a thread of the pool its caller may have filled: at launch `recoverMerges` starts
/// a run per unmerged branch, and with as many branches as cores the app's background work stopped for good.
/// XCTest, not Swift Testing: the test itself must not live in the pool it fills.
final class PoolStarvationTests: XCTestCase {
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory())

    private func fillPool(_ work: @escaping @Sendable () -> Void) -> Bool {
        let group = DispatchGroup()
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount * 4 {
            group.enter()
            Task.detached(priority: .userInitiated) { work(); group.leave() }
        }
        return group.wait(timeout: .now() + 30) == .success
    }

    func testRunEnv() {
        let dir = dir
        XCTAssertTrue(fillPool { _ = DiffLoader.runEnv(["--version"], in: dir, env: [:], input: Data("x".utf8)) })
    }

    func testDiff() {
        let dir = dir
        XCTAssertTrue(fillPool { _ = DiffLoader.run(["--version"], in: dir) })
    }

    func testWorktrees() {
        let dir = dir
        XCTAssertTrue(fillPool { Worktrees.git(["--version"], in: dir) })
    }

    func testTimedProcess() {
        XCTAssertTrue(fillPool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/cat")
            let r = TimedProcess.run(p, timeout: 20, input: "x")
            if r.out != "x" { XCTFail("output lost: \(r)") }
        })
    }
}
