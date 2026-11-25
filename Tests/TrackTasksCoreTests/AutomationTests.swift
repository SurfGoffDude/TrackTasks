import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Automation")
struct AutomationTests {
    static let url = URL(fileURLWithPath: "/p/automations/a.md")
    static let project = URL(fileURLWithPath: "/p")

    func file(_ extra: String = "schedule: daily\ntime: \"09:00\"", enabled: String = "true", title: String = "\"Обзор\"") -> String {
        "---\ntitle: \(title)\nenabled: \(enabled)\n\(extra)\n---\n\nТекст\n"
    }
    func parse(_ text: String) -> Automation { Automation.parse(text, url: Self.url) }
    func cal(_ zone: String = "Europe/Berlin") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }
    func at(_ s: String, _ c: Calendar) -> Date {
        let n = s.split(whereSeparator: { "- :".contains($0) }).map { Int($0)! }
        return c.date(from: DateComponents(year: n[0], month: n[1], day: n[2], hour: n[3], minute: n[4]))!
    }
    func text(_ d: Date?, _ c: Calendar) -> String {
        guard let d else { return "nil" }
        let p = c.dateComponents([.hour, .minute], from: d)
        return Automation.Rule.dayKey(d, c) + String(format: " %02d:%02d", p.hour!, p.minute!)
    }
    let daily = Automation.Rule(.daily, hour: 9, minute: 0)

    // MARK: Format

    @Test func parsesFields() {
        let a = parse(file("schedule: weekly # каждую неделю\ntime: 9:05\ndays: [mon, Чт]\nqueue: true\npriority: high\nsize: s\nagent: claude",
                           title: "\"A # b\" # комментарий"))
        #expect(a.errors.isEmpty && a.isActive && a.queue)
        #expect(a.title == "A # b" && a.body == "Текст")
        #expect(a.rule == .init(.weekly, hour: 9, minute: 5, weekdays: [2, 5]))
        #expect(a.priority == .high && a.size == "s" && a.agent == "claude")
    }

    @Test(arguments: ["", "false", "yes", "1"]) func onlyTrueEnables(_ v: String) { #expect(!parse(file(enabled: v)).isActive) }

    @Test func missingEnabledIsOff() { #expect(!parse("---\ntitle: a\nschedule: daily\ntime: 09:00\n---\n").isActive) }

    @Test(arguments: ["schedule: hourly\ntime: 09:00", "schedule: daily", "schedule: daily\ntime: 24:00", "schedule: daily\ntime: 9",
                      "schedule: daily\ntime: -1:00", "schedule: weekly\ntime: 09:00", "schedule: weekly\ntime: 09:00\ndays: [mon, xx]",
                      "schedule: monthly\ntime: 09:00", "schedule: monthly\ntime: 09:00\nday: 32",
                      "schedule: daily\ntime: 09:00\nqueue: да", "schedule: daily\ntime: 09:00\nsize: xl"])
    func errorsKeepItOff(_ extra: String) {
        let a = parse(file(extra))
        #expect(!a.errors.isEmpty && !a.isActive)
    }

    @Test func fingerprintIgnoresOnlyTheSwitch() {
        let on = file(), off = Frontmatter.setting("enabled", to: "false", in: on)
        #expect(parse(on).fingerprint == parse(off).fingerprint)
        for other in [on + "x", on.replacingOccurrences(of: "09:00", with: "10:00"), on.replacingOccurrences(of: "---\n\n", with: "queue: true\n---\n\n")] {
            #expect(parse(on).fingerprint != parse(other).fingerprint)
        }
    }

    @Test func templateIsValidAndOff() {
        let a = parse(Automation.template(title: "x"))
        #expect(a.errors.isEmpty && !a.enabled && !a.queue)
    }

    @Test func onlyScheduleFilesOfTheFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-aut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = Automation.dir(in: dir)
        try FileManager.default.createDirectory(at: f.appendingPathComponent("sub.md"), withIntermediateDirectories: true)
        try Data(file().utf8).write(to: f.appendingPathComponent("a.md"))
        try Data("# Заметки\n".utf8).write(to: f.appendingPathComponent("README.md"))
        try Data("x".utf8).write(to: f.appendingPathComponent("run.py"))
        #expect(Automation.all(in: dir).map(\.fileName) == ["a.md"])
        #expect(Codec.project(at: dir, category: "c").automations.count == 1)
        #expect(Automation.isFile("automations/a.md") && !Automation.isFile("automations/run.py") && !Automation.isFile("automations/x/a.md"))
    }

    @Test func taskOfSchedule() {
        let t = parse(file("schedule: daily\ntime: 09:00\npriority: low\nsize: s\nagent: codex"))
            .task(stamp: "24.11.2026", created: "2026-11-24", dod: ["Тесты"], in: URL(fileURLWithPath: "/p/tasks"))
        let back = Codec.task(from: Codec.serialize(t), url: t.url)
        #expect(back.title == "Обзор — 24.11.2026" && back.automation == "a.md" && back.status == .todo)
        #expect(back.priority == .low && back.size == "s" && back.agent == "codex" && back.body.contains("- [ ] Тесты"))
    }

    // MARK: Moments

    @Test func nextIsStrictlyAfter() {
        let c = cal()
        #expect(text(daily.next(after: at("2026-11-24 08:59", c), calendar: c), c) == "2026-11-24 09:00")
        #expect(text(daily.next(after: at("2026-11-24 09:00", c), calendar: c), c) == "2026-11-25 09:00")
        let midnight = Automation.Rule(.daily, hour: 0, minute: 0)
        #expect(text(midnight.next(after: at("2026-11-24 12:00", c), calendar: c), c) == "2026-11-25 00:00")
        // 24.11.2026 is Tuesday.
        let week = Automation.Rule(.weekly, hour: 9, minute: 0, weekdays: [2])
        #expect(text(week.next(after: at("2026-11-24 10:00", c), calendar: c), c) == "2026-11-30 09:00")
    }

    @Test func lastDayOfShortMonth() {
        let c = cal(), r = Automation.Rule(.monthly, hour: 9, minute: 0, day: 31)
        #expect(text(r.next(after: at("2027-01-31 10:00", c), calendar: c), c) == "2027-02-28 09:00")
        #expect(text(r.next(after: at("2027-02-28 10:00", c), calendar: c), c) == "2027-03-31 09:00")
        #expect(text(r.next(after: at("2028-02-01 10:00", c), calendar: c), c) == "2028-02-29 09:00")
    }

    /// Berlin: 29.03.2026 02:00→03:00, 25.10.2026 03:00→02:00.
    @Test func springSkippedTime() {
        let c = cal(), r = Automation.Rule(.daily, hour: 2, minute: 30)
        let s = r.next(after: at("2026-03-28 12:00", c), calendar: c)
        #expect(text(s, c) == "2026-03-29 03:00")
        #expect(text(r.next(after: s!, lastDay: "2026-03-29", calendar: c), c) == "2026-03-30 02:30")
        // The hour itself is not lost for an ordinary time.
        #expect(text(daily.next(after: at("2026-03-28 12:00", c), calendar: c), c) == "2026-03-29 09:00")
    }

    @Test func autumnRepeatedTimeRunsOnce() {
        let c = cal(), r = Automation.Rule(.daily, hour: 2, minute: 30)
        let first = r.next(after: at("2026-10-24 12:00", c), calendar: c)!
        #expect(text(first, c) == "2026-10-25 02:30")
        #expect(c.timeZone.isDaylightSavingTime(for: first))
        // The second 02:30, an hour later.
        #expect(r.due(since: first, now: first.addingTimeInterval(3600), calendar: c) == nil)
        #expect(text(r.next(after: first, calendar: c), c) == "2026-10-26 02:30")
    }

    @Test func midnightSkippedByClockChange() {
        // Cairo: 24.04.2026 00:00→01:00.
        let c = cal("Africa/Cairo"), r = Automation.Rule(.daily, hour: 0, minute: 0)
        let s = r.next(after: at("2026-04-23 12:00", c), calendar: c)!
        #expect(Automation.Rule.dayKey(s, c) == "2026-04-24")
        #expect(text(r.next(after: s, lastDay: "2026-04-24", calendar: c), c) == "2026-04-25 00:00")
    }

    @Test func weekOfSleepGivesOne() {
        let c = cal()
        let s = daily.due(since: at("2026-11-17 09:00", c), now: at("2026-11-24 08:00", c), calendar: c)
        #expect(text(s, c) == "2026-11-23 09:00")
        #expect(daily.due(since: s!, now: at("2026-11-24 08:00", c), calendar: c) == nil)
    }

    @Test func missedMonthIsFound() {
        let c = cal(), r = Automation.Rule(.monthly, hour: 9, minute: 0, day: 1)
        #expect(text(r.due(since: at("2026-09-01 09:00", c), now: at("2026-11-30 08:00", c), calendar: c), c) == "2026-11-01 09:00")
    }

    // MARK: State

    func observed(_ a: Automation, _ d: Date, _ s: AutomationState = AutomationState()) -> AutomationState {
        var s = s
        s.observe([a], project: Self.project, now: d)
        return s
    }

    @Test func firstSeenDoesNotCatchUp() {
        let c = cal(), a = parse(file()), s = observed(a, at("2026-11-24 10:00", c))
        #expect(s.due(a, now: at("2026-11-24 10:01", c), calendar: c) == nil)
        #expect(text(s.next(a, now: at("2026-11-24 10:01", c), calendar: c), c) == "2026-11-25 09:00")
        #expect(s.due(a, now: at("2026-11-25 09:00", c), calendar: c) != nil)
    }

    @Test func switchedOffNeverRuns() {
        let c = cal(), off = parse(file(enabled: "false")), s = observed(off, at("2026-11-01 10:00", c))
        #expect(s.due(off, now: at("2026-11-24 10:00", c), calendar: c) == nil)
        #expect(s.next(off, now: at("2026-11-24 10:00", c), calendar: c) == nil)
        // Not observed as on yet: also nothing.
        #expect(s.due(parse(file()), now: at("2026-11-24 10:00", c), calendar: c) == nil)
    }

    @Test func reenabledAndEditedStartFromNow() {
        let c = cal(), on = parse(file()), off = parse(file(enabled: "false")), later = parse(file("schedule: daily\ntime: 08:00"))
        var s = observed(on, at("2026-11-01 10:00", c))
        s = observed(off, at("2026-11-02 10:00", c), s)
        s = observed(on, at("2026-11-24 10:00", c), s)
        #expect(s.due(on, now: at("2026-11-24 10:01", c), calendar: c) == nil)
        s = observed(later, at("2026-11-26 10:00", c), s)
        #expect(s.due(later, now: at("2026-11-26 10:01", c), calendar: c) == nil)
        // Gone (another branch) and back.
        s.observe([], project: Self.project, now: at("2026-11-27 10:00", c))
        s = observed(later, at("2026-12-10 10:00", c), s)
        #expect(s.due(later, now: at("2026-12-10 10:01", c), calendar: c) == nil)
    }

    @Test func clockBackDoesNotRepeat() {
        let c = cal(), a = parse(file())
        var s = observed(a, at("2026-11-23 10:00", c))
        let slot = s.due(a, now: at("2026-11-24 09:01", c), calendar: c)!
        _ = s.begin(a, slot: slot, now: at("2026-11-24 09:01", c), calendar: c)
        s = observed(a, at("2026-11-24 08:30", c), s)
        #expect(s.due(a, now: at("2026-11-24 09:05", c), calendar: c) == nil)
        #expect(text(s.next(a, now: at("2026-11-24 08:30", c), calendar: c), c) == "2026-11-25 09:00")
    }

    @Test func wrongFutureClockRecovers() {
        let c = cal(), a = parse(file())
        var s = observed(a, at("2026-11-23 10:00", c))
        _ = s.begin(a, slot: at("2031-01-01 09:00", c), now: at("2031-01-01 09:00", c), calendar: c)
        s = observed(a, at("2026-11-24 10:00", c), s)
        #expect(text(s.next(a, now: at("2026-11-24 10:00", c), calendar: c), c) == "2026-11-25 09:00")
    }

    @Test func timeZoneChangeOncePerLocalDay() {
        let moscow = cal("Europe/Moscow"), ny = cal("America/New_York"), a = parse(file())
        var s = observed(a, at("2026-11-23 10:00", moscow))
        let slot = s.due(a, now: at("2026-11-24 09:00", moscow), calendar: moscow)!
        _ = s.begin(a, slot: slot, now: slot, calendar: moscow)
        // The same date in New York comes to 09:00 again.
        #expect(s.due(a, now: at("2026-11-24 09:30", ny), calendar: ny) == nil)
        #expect(text(s.next(a, now: at("2026-11-24 08:00", ny), calendar: ny), ny) == "2026-11-25 09:00")
        // Eastwards.
        let tokyo = cal("Asia/Tokyo")
        #expect(text(s.next(a, now: slot, calendar: tokyo), tokyo) == "2026-11-25 09:00")
    }

    @Test func permissionFollowsTheText() {
        let a = parse(file("schedule: daily\ntime: 09:00\nqueue: true")), now = Date()
        var s = AutomationState()
        #expect(!s.mayQueue(a))
        s.allow(a, true, now: now)
        #expect(s.mayQueue(a))
        #expect(!s.mayQueue(parse(file("schedule: daily\ntime: 09:00\nqueue: true") + "ещё")))
        #expect(!s.mayQueue(parse(file())))
        s.allow(a, false, now: now)
        #expect(!s.mayQueue(a))
    }

    @Test func historyIsLimited() {
        let a = parse(file()), c = cal()
        var s = AutomationState()
        for _ in 0..<60 { _ = s.begin(a, slot: nil, now: Date(), calendar: c) }
        #expect(s.entries[a.id]?.history.count == 50)
    }

    @Test func storesAndReportsBrokenFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-aut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("automations.json"), a = parse(file())
        #expect(AutomationState.load(url).problem == nil)
        var s = observed(a, Date(timeIntervalSince1970: 1_000_000))
        let run = s.begin(a, slot: Date(timeIntervalSince1970: 1_000_100), now: Date(timeIntervalSince1970: 1_000_100), calendar: cal())
        s.finish(a.id, run, .queued, task: "t.md")
        try s.save(url)
        #expect(AutomationState.load(url).state == s)
        try Data("{\"version\": 9}".utf8).write(to: url)
        #expect(AutomationState.load(url).problem != nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        try Data("oops".utf8).write(to: url)
        #expect(AutomationState.load(url).problem != nil)
    }
}
