import Foundation
import Testing
@testable import TrackTasksCore

struct JobGuideTests {
    private func facts(_ state: JobFacts.State, _ change: (inout JobFacts) -> Void = { _ in }) -> JobFacts {
        var f = JobFacts()
        f.state = state
        change(&f)
        return f
    }
    private func offering(_ a: JobAction..., blocked: String? = nil) -> [JobAction: JobOffer] {
        Dictionary(uniqueKeysWithValues: a.map { ($0, JobOffer($0.rawValue, icon: "", blocked: blocked)) })
    }

    @Test func everyStateHasStatusAndNextStep() {
        for s in JobFacts.State.allCases {
            let g = JobGuide.of(facts(s))
            #expect(!g.status.isEmpty && !g.next.isEmpty, "\(s)")
        }
    }

    @Test func waitsForThePerson() {
        let cases: [(JobGuide.Need, JobFacts)] = [
            (.permission, facts(.running) { $0.permissions = 1 }),
            (.permission, facts(.done) { $0.permissions = 1; $0.child = "Ревью" }),
            (.questions, facts(.done) { $0.questions = .ask(2) }),
            (.questions, facts(.failed) { $0.questions = .send }),
            (.plan, facts(.pending) { $0.plan = .awaiting }),
            (.pipeline, facts(.done) { $0.gate = "стоп"; $0.pipelineOpen = true }),
            (.pipeline, facts(.pending) { $0.gate = "стоп" }),
            (.red, facts(.done) { $0.verifyFailed = true }),
            (.red, facts(.done) { $0.mergeRed = true; $0.awaitsMerge = true }),
            (.conflict, facts(.done) { $0.conflict = true; $0.awaitsMerge = true }),
            (.conflict, facts(.done) { $0.mainConflict = true; $0.autopilot = true; $0.awaitsMerge = true }),
            (.taskCheck, facts(.done) { $0.taskCheck = "нет"; $0.awaitsMerge = true }),
            (.taskCheck, facts(.done) { $0.taskCheckToRun = true }),
            (.remarks, facts(.done) { $0.remarks = true }),
            (.rollback, facts(.done) { $0.rolledBack = true; $0.awaitsMerge = true }),
            (.pullRequest, facts(.done) { $0.prOpen = true; $0.awaitsMerge = true }),
            (.failure, facts(.failed)),
            (.merge, facts(.done) { $0.awaitsMerge = true }),
        ]
        for (need, f) in cases { #expect(JobGuide.of(f).need == need) }
    }

    @Test func nobodyIsNeeded() {
        let calm = [facts(.pending), facts(.running), facts(.cancelled), facts(.done), facts(.failed) { $0.isChild = true },
                    facts(.done) { $0.merged = true; $0.verifyFailed = true },
                    facts(.done) { $0.awaitsMerge = true; $0.child = "Ревью" },
                    facts(.done) { $0.awaitsMerge = true; $0.merging = "Сливаю…" },
                    facts(.done) { $0.awaitsMerge = true; $0.autopilot = true; $0.mergeRed = true }]
        for f in calm { #expect(JobGuide.of(f).need == nil) }
    }

    @Test func mainActions() {
        let cases: [(JobAction, JobFacts)] = [
            (.approveScripts, facts(.failed) { $0.setup = true }),
            (.retry, facts(.failed)), (.retry, facts(.cancelled)),
            (.resolveMain, facts(.done) { $0.mainConflict = true }),
            (.resolveConflict, facts(.done) { $0.conflict = true }),
            (.fixCheck, facts(.done) { $0.mergeRed = true }),
            (.approveTaskCheck, facts(.done) { $0.taskCheck = "нет" }),
            (.recheckMain, facts(.done) { $0.taskCheckToRun = true }),
            (.diff, facts(.done) { $0.verifyFailed = true }),
            (.fixReview, facts(.done) { $0.remarks = true }),
            (.pullBase, facts(.done) { $0.prMerged = true; $0.awaitsMerge = true }),
            (.merge, facts(.done) { $0.awaitsMerge = true }),
            (.mergeAll, facts(.done) { $0.awaitsMerge = true; $0.isGroup = true }),
            (.commit, facts(.done)),
        ]
        for (a, f) in cases {
            var f = f
            #expect(JobGuide.of(f).primary == nil)
            f.offers = offering(a)
            #expect(JobGuide.of(f).primary == a)
            #expect(JobGuide.of(f).next.contains(a.rawValue))
            f.offers = offering(a, blocked: "занято")
            #expect(JobGuide.of(f).primary == a && JobGuide.of(f).next.contains("занято"))
        }
    }

    /// Any mix of facts: at most one main action, one of those the card has, and nothing dangerous.
    @Test func atMostOneMainAction() {
        let flags: [WritableKeyPath<JobFacts, Bool>] = [\.pipelineOpen, \.awaitsMerge, \.conflict, \.mergeRed, \.remarks, \.rolledBack, \.autopilot, \.verifyFailed]
        let offers = [[:], offering(.merge, .retry, .discard), Dictionary(uniqueKeysWithValues: JobAction.allCases.map { ($0, JobOffer($0.rawValue, icon: "")) })]
        for s in JobFacts.State.allCases {
            for bits in 0..<(1 << flags.count) {
                var f = facts(s)
                for (i, k) in flags.enumerated() { f[keyPath: k] = bits & (1 << i) != 0 }
                for o in offers {
                    f.offers = o
                    let g = JobGuide.of(f)
                    if let p = g.primary {
                        #expect(o[p] != nil && p != .discard && g.card == nil)
                    }
                    var asks = f
                    asks.permissions = 1
                    #expect(JobGuide.of(asks).primary == nil && JobGuide.of(asks).card == .permission)
                    asks = f
                    asks.questions = .ask(1)
                    #expect(JobGuide.of(asks).primary == nil && JobGuide.of(asks).card == .questions)
                    if s == .pending {
                        asks = f
                        asks.plan = .awaiting
                        #expect(JobGuide.of(asks).primary == nil && JobGuide.of(asks).card == .plan)
                    }
                }
            }
        }
    }

    @Test func groupPointsAtItsRepository() {
        let f = facts(.done) { $0.conflict = true; $0.isGroup = true; $0.repoActions = [.resolveConflict]; $0.offers = offering(.mergeAll) }
        let g = JobGuide.of(f)
        #expect(g.primary == nil && g.next.contains("репозитория"))
    }

    @Test func deletionIsAlone() {
        #expect(JobAction.allCases.filter { $0.place == .danger } == [.discard])
    }

    @Test func hunkOfRows() {
        var t = DiffTable()
        t.rows = [.hunk("a"), .pair(left: nil, right: nil), .hunk("b"), .pair(left: nil, right: nil)]
        #expect(t.hunk(of: [1]) == 0 && t.hunk(of: [2, 3]) == 1)
        #expect(t.hunk(of: [1, 3]) == nil && t.hunk(of: []) == nil && t.hunk(of: [9]) == nil)
    }
}
