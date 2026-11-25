import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Autopilot")
struct AutopilotTests {
    func step(_ edit: (inout Autopilot.Facts) -> Void) -> Autopilot.Step {
        var f = Autopilot.Facts()
        f.verify = "make test"
        f.approvedVerify = "make test"
        f.verdict = .ok
        edit(&f)
        return Autopilot.step(f)
    }
    func parks(_ edit: (inout Autopilot.Facts) -> Void) -> Bool {
        if case .park = step(edit) { return true }
        return false
    }

    @Test func mergesOnlyReviewedWork() {
        #expect(step { _ in } == .merge)
        #expect(step { $0.verdict = nil } == .review)
        #expect(step { $0.verdict = .issues } == .fixReview)
        // Fixed code is reviewed again before the merge.
        #expect(step { $0.verdict = .issues; $0.reviewFixed = true } == .review)
        #expect(step { $0.ready = false } == .wait)
    }

    @Test func unapprovedTaskCheckParks() {
        #expect(step { $0.taskCheck = "не подтверждена" } == .park(Autopilot.taskCheckReason + "не подтверждена"))
        #expect(parks { $0.taskCheck = "x"; $0.verdict = nil })
    }

    @Test func repairsThenParks() {
        #expect(step { $0.checkRed = true } == .fixCheck)
        #expect(step { $0.mergeConflict = true } == .resolveConflict)
        #expect(parks { $0.checkRed = true; $0.repairs = 2 })
        #expect(parks { $0.mergeConflict = true; $0.repairs = 2 })
        #expect(parks { $0.verdict = .issues; $0.fixes = 2 })
        #expect(parks { $0.verdict = nil; $0.reviews = 5 })
        #expect(parks { $0.merges = 3 })
    }

    @Test func neverMergesWithoutTheApprovedCheckOrAnUnfinishedTask() {
        #expect(parks { $0.verify = ""; $0.approvedVerify = "" })
        #expect(parks { $0.verify = "true" })
        #expect(parks { $0.approvedVerify = nil })
        #expect(parks { $0.taskDone = false })
        #expect(parks { $0.livePR = true })
        #expect(parks { $0.rolledBack = true })
    }

    @Test func everyPathEnds() {
        // A review that never approves and repairs that never help.
        for red in [true, false] {
            var f = Autopilot.Facts()
            f.verify = "x"; f.approvedVerify = "x"; f.checkRed = red
            var n = 0
            loop: while n < 50 {
                n += 1
                switch Autopilot.step(f) {
                case .review: f.reviews += 1; f.verdict = .issues; f.reviewFixed = false
                case .fixReview: f.fixes += 1; f.reviewFixed = true
                case .fixCheck, .resolveConflict: f.repairs += 1
                case .merge: f.merges += 1
                case .wait, .park: break loop
                }
            }
            #expect(n < 20)
        }
    }

    @Test func questionsComeBeforeTheUnclosedTask() {
        var f = Autopilot.Facts()
        f.verify = "v"; f.approvedVerify = "v"; f.taskDone = false; f.verdict = .ok
        #expect(Autopilot.step(f) == .park(Autopilot.notClosedReason))
        f.awaitsAnswers = true
        #expect(Autopilot.step(f) == .park("ждёт ответов"))
        f.ready = false
        #expect(Autopilot.step(f) == .wait)
    }

    @Test func mergeNeedsAutopilotAndOwnText() {
        let now = Date(timeIntervalSince1970: 1000), later = now.addingTimeInterval(1)
        var plain = DangerMode(), auto = DangerMode()
        _ = plain.enable("/p", name: "A", typed: "A", .hour, now: now)
        _ = auto.enable("/p", name: "A", typed: "A", .hour, autopilot: true, verify: "v", now: now)
        #expect(!plain.allows(.merge, .init(), project: "/p", now: later))
        #expect(auto.allows(.merge, .init(), project: "/p", now: later))
        #expect(!auto.allows(.merge, .init(foreign: true), project: "/p", now: later))
        #expect(!auto.allows(.merge, .init(), project: "/p", now: now.addingTimeInterval(3600)))
        for a in [DangerMode.Action.push, .createPullRequest, .mergePullRequest] {
            #expect(!auto.allows(a, .init(), project: "/p", now: later))
        }
    }

    @Test func grantsOfTheOldVersionHaveNoAutopilot() throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let m = try dec.decode(DangerMode.self, from: Data(#"{"version":1,"grants":{"/p":{"startedAt":1000}}}"#.utf8))
        let t = Date(timeIntervalSince1970: 2000)
        #expect(m.isOn("/p", now: t))
        #expect(!m.allows(.merge, .init(), project: "/p", now: t))
    }
}
