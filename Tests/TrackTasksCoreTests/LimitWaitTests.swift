import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct LimitWaitTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var five: RunLimit { RunLimit(window: "five_hour", resetsAt: now.addingTimeInterval(3600)) }
    private func refusal(_ l: RunLimit, session: String? = "s", canResume: Bool = true, retried: Date? = nil) -> String? {
        LimitWait.refusal(l, session: session, canResume: canResume, retried: retried, now: now)
    }

    @Test func waitsOnlyForAKnownFiveHourReset() {
        #expect(refusal(five) == nil)
        #expect(refusal(RunLimit(window: "five_hour"))?.contains("время сброса неизвестно") == true)
        #expect(refusal(RunLimit())?.contains("время сброса неизвестно") == true)
        #expect(refusal(RunLimit(window: "seven_day", resetsAt: five.resetsAt))?.contains("Недельный лимит") == true)
        #expect(refusal(RunLimit(window: "five_hour", resetsAt: now)) != nil)
        #expect(refusal(five, session: nil) != nil)
        #expect(refusal(five, canResume: false) != nil)
    }

    @Test func oneRetryPerWindow() {
        #expect(refusal(five, retried: five.resetsAt!.addingTimeInterval(-40))?.contains("уже был") == true)
        #expect(refusal(five, retried: five.resetsAt!.addingTimeInterval(-5 * 3600)) == nil)
    }

    @Test func claudeRefusal() {
        #expect(RunLimit(claude: ["status": "rejected", "rateLimitType": "five_hour", "resetsAt": 1_800_000_000.0]) == RunLimit(window: "five_hour", resetsAt: now))
        #expect(RunLimit(claude: ["status": "rejected"]) == RunLimit())
        #expect(RunLimit(claude: ["status": "allowed_warning", "rateLimitType": "five_hour"]) == nil)
        #expect(RunLimit(claude: ["status": "rejected", "rateLimitType": "five_hour", "isUsingOverage": true]) == nil)
    }

    @Test func brokenRecordIsReadAsNothing() throws {
        let r = try JSONDecoder().decode([LenientLimitWait].self, from: Data(#"[{"window":7},"x"]"#.utf8))
        #expect(r.map(\.value) == [nil, nil])
    }
}
