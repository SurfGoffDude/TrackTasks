import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct MergeReadinessTests {
    @Test func batchSkipsWithReason() {
        let a = UUID(), b = UUID(), c = UUID()
        var m = MergeBatch([a, b, c])
        #expect(m.next() == a)
        m.record("A", skipped: nil)
        #expect(m.next() == b)
        m.record("B", skipped: "красная")
        #expect(m.next() == c)
        m.record("C", skipped: nil)
        #expect(m.next() == nil)
        #expect(m.merged == 2 && m.total == 3 && m.done == 3)
        #expect(m.summary == "B: красная")
    }

    @Test func stopLeavesTheRest() {
        var m = MergeBatch([UUID(), UUID()])
        _ = m.next()
        m.stop()
        m.record("A", skipped: "остановлено")
        #expect(m.next() == nil)
        #expect(m.summary.contains("не начато: 1"))
    }

    @Test func checkState() {
        let c = SafeMerge.Check(state: .passed, branchCommit: "v", mainCommit: "m", mainBranch: "main", command: "t")
        func st(_ c: SafeMerge.Check?, _ main: String = "m", _ cmd: String = "t") -> MergeReadiness.CheckState {
            MergeReadiness.state(c, tip: "v", main: main, mainBranch: "main", command: cmd)
        }
        #expect(st(c) == .fresh)
        #expect(st(c, "m2") == .stale)
        #expect(st(c, "m", "other") == .stale)
        #expect(st(nil) == .none)
        #expect(MergeReadiness.state(c, tip: "v", main: "m", mainBranch: "main", command: "t", taskCommand: "x") == .stale)
        var both = c
        both.taskCommand = "x"
        #expect(MergeReadiness.state(both, tip: "v", main: "m", mainBranch: "main", command: "t", taskCommand: "x") == .fresh)
        #expect(st(both) == .stale)
        #expect(st(nil, "m", "") == .unverified)
        var red = c
        red.state = .red
        #expect(st(red) == .red)
    }

    @Test func overlapsOnlyInsideOneProject() {
        let a = UUID(), b = UUID(), c = UUID()
        let o = MergeReadiness.overlaps([.init(id: a, project: "p", files: ["x", "y"]), .init(id: b, project: "p", files: ["y"]),
                                         .init(id: c, project: "q", files: ["y"])])
        #expect(o[a] == [.init(other: b, files: ["y"])])
        #expect(o[c] == [])
    }
}
