import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

@Suite struct VerifyTimeoutTests {
    @Test func timeoutTellsWhereItHung() throws {
        let start = Date()
        var root: pid_t = 0
        let r = Verify.execute("echo before; /bin/sleep 120; true", in: FileManager.default.temporaryDirectory, timeout: 1) { root = $0.pid! }
        #expect(r.timedOut && !r.ok)
        #expect(r.output.contains("before\n"))
        #expect(r.output.contains("/bin/sleep 120"), "\(r.output)")
        #expect(r.output.contains("Стек sleep") && r.output.contains("nanosleep"), "\(r.output)")
        #expect(Date().timeIntervalSince(start) < 100)
        #expect(kill(root, 0) != 0)
    }

    @Test func noStacksWhenItEnds() {
        let r = Verify.execute("echo fine", in: FileManager.default.temporaryDirectory)
        #expect(r.ok && r.output == "fine\n")
    }
}
