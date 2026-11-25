import Foundation
import Testing
@testable import TrackTasksCore

@Suite("CIVerdict")
struct CIVerdictTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let pr = PullRequest(number: 7, url: "u", headOid: "new")
    private func link() -> PullRequestLink { PullRequestLink(pr: pr, remote: "origin", pushedOid: "new") }

    private func run(_ name: String, _ conclusion: String = "SUCCESS", status: String = "COMPLETED",
                     hour: Int = 10) -> String {
        #"{"name":"\#(name)","workflowName":"CI","status":"\#(status)","conclusion":"\#(conclusion)","detailsUrl":"https://github.com/o/r/actions/runs/1","startedAt":"2026-11-23T\#(hour):00:00Z","completedAt":"\#(status == "COMPLETED" ? "2026-11-23T\(hour):05:00Z" : "0001-01-01T00:00:00Z")"}"#
    }
    /// Asked at `at`, answered a second later.
    private func answer(_ l: inout PullRequestLink, _ checks: [String], at: TimeInterval, head: String = "new") throws {
        let json = #"{"number":7,"url":"u","state":"OPEN","headRefOid":"\#(head)","statusCheckRollup":[\#(checks.joined(separator: ","))]}"#
        let s = try #require(PullRequestStatus.parse(json, now: t0 + at + 1))
        l.update(pr: pr, status: s, asked: t0 + at)
    }

    @Test func greenNeedsTwoAnswersWithAPause() throws {
        var l = link()
        #expect(l.ci == .unknown)
        try answer(&l, [run("a"), run("b")], at: 0)
        #expect(l.ci == .confirming)
        // Manual refresh right away, twice; the order of checks doesn't matter.
        try answer(&l, [run("b"), run("a")], at: 2)
        try answer(&l, [run("a"), run("b")], at: 4)
        #expect(l.ci == .confirming)
        // Counted from the first answer, not from the last refresh.
        try answer(&l, [run("b"), run("a")], at: 31)
        #expect(l.ci == .green)
        try answer(&l, [run("a"), run("b")], at: 32)
        #expect(l.ci == .green)
        #expect(try JSONDecoder().decode(PullRequestLink.self, from: JSONEncoder().encode(l)) == l)
    }

    /// Sent together with the first request, answered much later.
    @Test func slowTwinRequestProvesNothing() throws {
        var l = link()
        try answer(&l, [run("a")], at: 0)
        var s = try #require(l.status)
        s.updated = t0 + 100
        l.update(pr: pr, status: s, asked: t0)
        #expect(l.ci == .confirming)
    }

    @Test func oldGreenAfterPush() throws {
        var l = link()
        try answer(&l, [run("a")], at: 0, head: "old")
        try answer(&l, [run("a")], at: 100, head: "old")
        #expect(l.ci == .wrongCommit && l.ciWarning == nil)
        // It doesn't count as the first answer for the new commit.
        try answer(&l, [run("a")], at: 200)
        #expect(l.ci == .confirming)
        try answer(&l, [run("a")], at: 300)
        #expect(l.ci == .green)
        // Somebody pushed on top, then GitHub showed our commit again.
        try answer(&l, [run("a")], at: 400, head: "other")
        #expect(l.ci == .wrongCommit)
        try answer(&l, [run("a")], at: 500)
        #expect(l.ci == .confirming)
    }

    @Test func wrongRedStillWarns() throws {
        var l = link()
        try answer(&l, [run("a", "FAILURE")], at: 0, head: "old")
        #expect(l.ci == .wrongCommit)
        #expect(l.ciWarning?.contains("другом коммите (old)") == true)
    }

    @Test func redIsSeenAtOnce() throws {
        var l = link()
        try answer(&l, [run("a"), run("b", "FAILURE")], at: 0)
        #expect(l.ci == .red && l.ciWarning == "CI красный — CI / b")
    }

    @Test func checksAppearLater() throws {
        var l = link()
        try answer(&l, [], at: 0)
        try answer(&l, [], at: 100)
        #expect(l.ci == CIVerdict.none)
        try answer(&l, [run("a")], at: 200)
        #expect(l.ci == .confirming)
        try answer(&l, [run("a"), run("b", "", status: "IN_PROGRESS")], at: 300)
        #expect(l.ci == .running)
        try answer(&l, [run("a"), run("b")], at: 400)
        #expect(l.ci == .confirming)
        try answer(&l, [run("a"), run("b")], at: 500)
        #expect(l.ci == .green)
    }

    @Test func changedSetStartsOver() throws {
        var l = link()
        try answer(&l, [run("a")], at: 0)
        try answer(&l, [run("a"), run("b")], at: 100)
        #expect(l.ci == .confirming)
        try answer(&l, [run("a"), run("b")], at: 110)
        #expect(l.ci == .confirming)
        try answer(&l, [run("a"), run("b")], at: 140)
        #expect(l.ci == .green)
        try answer(&l, [run("b")], at: 240)
        #expect(l.ci == .confirming)
    }

    @Test func rerunStartsOver() throws {
        var l = link()
        try answer(&l, [run("a")], at: 0)
        try answer(&l, [run("a")], at: 100)
        #expect(l.ci == .green)
        try answer(&l, [run("a"), run("a", "", status: "IN_PROGRESS", hour: 11)], at: 200)
        #expect(l.ci == .running)
        // Also when the whole re-run fell between two requests.
        var missed = link()
        try answer(&missed, [run("a")], at: 0)
        for (i, v) in [(1, CIVerdict.confirming), (2, .green)] {
            try answer(&missed, [run("a"), run("a", hour: 11)], at: Double(i) * 100)
            #expect(missed.ci == v)
        }
        // Overlapping runs: the red one is not hidden.
        try answer(&l, [run("a"), run("a", "FAILURE")], at: 300)
        #expect(l.ci == .red)
    }

    @Test func noAnswerAboutChecksBreaksTheRow() throws {
        var l = link()
        try answer(&l, [run("a")], at: 0)
        l.update(pr: pr, status: nil, asked: t0 + 50)
        #expect(l.ci == .unknown)
        try answer(&l, [run("a")], at: 100)
        #expect(l.ci == .confirming)
    }

    @Test func oldRecordIsNotGreen() throws {
        let json = #"{"pr":{"number":7,"url":"u","state":"OPEN","isDraft":false,"head":"h","headOid":"new","base":"main"},"remote":"origin","pushedOid":"new","leftover":false,"status":{"checks":[{"name":"a","state":"pass"}],"conflict":false,"headOid":"new","updated":0}}"#
        let l = try JSONDecoder().decode(PullRequestLink.self, from: Data(json.utf8))
        #expect(l.confirmation == nil && l.status?.ci == .green && l.ci == .confirming)
    }
}
