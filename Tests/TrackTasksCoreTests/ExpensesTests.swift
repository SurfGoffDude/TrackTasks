import XCTest
@testable import TrackTasksCore

final class ExpensesTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func exp(_ amount: Double, _ period: Expense.Period, _ date: Date, projects: [String] = ["/p/a"],
                     currency: String = "₽", until: Date? = nil) -> Expense {
        Expense(projects: projects, title: "x", amount: amount, currency: currency, category: .hosting,
                date: date, period: period, until: until)
    }

    // MARK: once

    func testOncePaymentInsidePeriod() {
        let x = exp(500, .once, day(2026, 3, 10))
        let ps = x.payments(from: day(2026, 3, 1), to: day(2026, 3, 31), now: day(2026, 11, 16), calendar: cal)
        XCTAssertEqual(ps.map(\.amount), [500])
        XCTAssertEqual(x.total(from: day(2026, 3, 1), to: day(2026, 3, 31), now: day(2026, 11, 16), calendar: cal), 500)
    }

    func testOncePaymentOutsidePeriod() {
        let x = exp(500, .once, day(2026, 3, 10))
        let now = day(2026, 11, 16)
        XCTAssertTrue(x.payments(from: day(2026, 4, 1), to: day(2026, 4, 30), now: now, calendar: cal).isEmpty)
        XCTAssertTrue(x.payments(from: day(2026, 1, 1), to: day(2026, 2, 28), now: now, calendar: cal).isEmpty)
    }

    func testFuturePaymentNotCounted() {
        let x = exp(500, .once, day(2026, 12, 1))
        XCTAssertEqual(x.total(from: .distantPast, to: day(2027, 1, 1), now: day(2026, 11, 16), calendar: cal), 0)
    }

    // MARK: recurring

    func testMonthlyFrom31stClampsInFebruaryAndReturns() {
        let x = exp(100, .monthly, day(2026, 1, 31))
        let ps = x.payments(from: .distantPast, to: day(2026, 4, 30), now: day(2026, 11, 16), calendar: cal)
        let days = ps.map { cal.component(.day, from: $0.date) }
        let months = ps.map { cal.component(.month, from: $0.date) }
        XCTAssertEqual(months, [1, 2, 3, 4])
        XCTAssertEqual(days, [31, 28, 31, 30])
        XCTAssertEqual(ps.map { Expense.monthKey($0.date, calendar: cal) }, ["2026-01", "2026-02", "2026-03", "2026-04"])
    }

    func testMonthlyLeapFebruary() {
        let x = exp(100, .monthly, day(2028, 1, 31))
        let ps = x.payments(from: day(2028, 2, 1), to: day(2028, 2, 29), now: day(2028, 12, 1), calendar: cal)
        XCTAssertEqual(ps.count, 1)
        XCTAssertEqual(cal.component(.day, from: ps[0].date), 29)
    }

    func testMonthlyStopsAtUntilAndNow() {
        let x = exp(100, .monthly, day(2026, 1, 5), until: day(2026, 3, 20))
        XCTAssertEqual(x.total(from: .distantPast, now: day(2026, 11, 16), calendar: cal), 300)
        let open = exp(100, .monthly, day(2026, 1, 5))
        // Jan…Nov 5th, now = Nov 16.
        XCTAssertEqual(open.total(from: .distantPast, to: day(2030, 1, 1), now: day(2026, 11, 16), calendar: cal), 1100)
        XCTAssertFalse(x.isActive(at: day(2026, 11, 16)))
        XCTAssertTrue(open.isActive(at: day(2026, 11, 16)))
    }

    func testYearly() {
        let x = exp(1200, .yearly, day(2024, 2, 29))
        let ps = x.payments(from: .distantPast, now: day(2026, 11, 16), calendar: cal)
        XCTAssertEqual(ps.count, 3)
        XCTAssertEqual(ps.map { Expense.monthKey($0.date, calendar: cal) }, ["2024-02", "2025-02", "2026-02"])
        XCTAssertEqual(x.total(from: day(2025, 1, 1), now: day(2026, 11, 16), calendar: cal), 2400)
        XCTAssertEqual(x.perMonth(at: day(2026, 11, 16)), 100, accuracy: 1e-9)
    }

    func testPerMonth() {
        let now = day(2026, 11, 16)
        XCTAssertEqual(exp(300, .monthly, day(2026, 1, 1)).perMonth(at: now), 300)
        XCTAssertEqual(exp(300, .once, day(2026, 1, 1)).perMonth(at: now), 0)
        XCTAssertEqual(exp(300, .monthly, day(2026, 1, 1), until: day(2026, 5, 1)).perMonth(at: now), 0)
    }

    // MARK: overrides

    func testOverrideAndSkippedMonth() {
        var x = exp(100, .monthly, day(2026, 1, 10))
        x.overrides = ["2026-02": 250, "2026-03": 0]
        let now = day(2026, 4, 20)
        let ps = x.payments(from: .distantPast, now: now, calendar: cal)
        XCTAssertEqual(ps.map(\.amount), [100, 250, 100])
        XCTAssertEqual(ps.map(\.overridden), [false, true, false])
        XCTAssertEqual(x.total(from: .distantPast, now: now, calendar: cal), 450)

        let withSkipped = x.payments(from: .distantPast, includeSkipped: true, now: now, calendar: cal)
        XCTAssertEqual(withSkipped.map(\.amount), [100, 250, 0, 100])
    }

    func testSettingOverride() {
        let x = exp(100, .monthly, day(2026, 1, 10))
        let a = x.settingOverride(month: "2026-02", amount: 150)
        XCTAssertEqual(a.overrides, ["2026-02": 150])
        XCTAssertEqual(a.settingOverride(month: "2026-02", amount: 100).overrides, [:], "same as usual = no override")
        XCTAssertEqual(a.settingOverride(month: "2026-02", amount: nil).overrides, [:])
        XCTAssertEqual(x.settingOverride(month: "2026-03", amount: 0).overrides, ["2026-03": 0], "0 = skipped")
    }

    func testOverridesFromEditorTexts() {
        let o = Expense.overrides(fromTexts: ["2026-01": "1 200,5", "2026-02": "100", "2026-03": "abc", "2026-04": "0"], base: 100)
        XCTAssertEqual(o, ["2026-01": 1200.5, "2026-04": 0])
    }

    // MARK: shares and totals

    func testShareSplitBetweenThreeProjects() {
        let x = exp(300, .once, day(2026, 3, 1), projects: ["/p/a", "/p/b", "/p/c"])
        XCTAssertEqual(x.share("/p/a"), 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(x.share("/p/z"), 0)
        XCTAssertTrue(x.isShared)
        let now = day(2026, 11, 16)
        let parts = ["/p/a", "/p/b", "/p/c"].map { ExpenseMath.spent([x], project: $0, from: .distantPast, now: now, calendar: cal)["₽"] ?? 0 }
        for p in parts { XCTAssertEqual(p, 100, accuracy: 1e-9) }
        XCTAssertEqual(parts.reduce(0, +), 300, accuracy: 1e-9)
        XCTAssertEqual(ExpenseMath.spent([x], project: "/p/z", from: .distantPast, now: now, calendar: cal), [:])
        XCTAssertEqual(ExpenseMath.spent([x], from: .distantPast, now: now, calendar: cal), ["₽": 300])
    }

    func testGeneralExpenseCountsOnlyInOverallTotal() {
        let x = exp(50, .monthly, day(2026, 11, 1), projects: [], currency: "$")
        let now = day(2026, 11, 16)
        XCTAssertTrue(x.isGeneral)
        XCTAssertEqual(ExpenseMath.spent([x], project: "/p/a", from: .distantPast, now: now, calendar: cal), [:])
        XCTAssertEqual(ExpenseMath.spent([x], from: .distantPast, now: now, calendar: cal), ["$": 50])
        XCTAssertEqual(ExpenseMath.monthly([x], now: now), ["$": 50])
    }

    func testSeveralCurrencies() {
        let now = day(2026, 11, 16)
        let items = [
            exp(1000, .once, day(2026, 11, 2)),
            exp(500, .once, day(2026, 11, 3)),
            exp(12, .monthly, day(2026, 10, 1), currency: "$"),
            exp(120, .yearly, day(2026, 1, 1), currency: "€"),
        ]
        let m = ExpenseMath.spent(items, project: "/p/a", from: day(2026, 11, 1), now: now, calendar: cal)
        XCTAssertEqual(m, ["₽": 1500, "$": 12])
        let monthly = ExpenseMath.monthly(items, project: "/p/a", now: now)
        XCTAssertEqual(monthly["$"] ?? 0, 12, accuracy: 1e-9)
        XCTAssertEqual(monthly["€"] ?? 0, 10, accuracy: 1e-9)
        XCTAssertNil(monthly["₽"])
    }

    func testAddingClaude() {
        XCTAssertEqual(ExpenseMath.adding(claude: 2.5, to: ["₽": 10, "$": 1]), ["₽": 10, "$": 3.5])
        XCTAssertEqual(ExpenseMath.adding(claude: 0.001, to: ["₽": 10]), ["₽": 10])
    }

    // MARK: parsing and formatting

    func testParseAmount() {
        XCTAssertEqual(parseAmount("1 234,50"), 1234.5)
        XCTAssertEqual(parseAmount("1\u{00A0}234,50"), 1234.5)
        XCTAssertEqual(parseAmount("1\u{202F}234,50"), 1234.5)
        XCTAssertEqual(parseAmount("99.9"), 99.9)
        XCTAssertEqual(parseAmount("0"), 0)
        XCTAssertNil(parseAmount(""))
        XCTAssertNil(parseAmount("abc"))
    }

    func testMoneyFormatOrder() {
        let s = MoneyFormat.money(["$": 12, "₽": 1000, "£": 3, "€": 0.001])
        XCTAssertTrue(s.hasSuffix("$12 + £3"), s)
        XCTAssertTrue(s.hasPrefix("1"), s)
        XCTAssertTrue(s.contains("₽"), s)
        XCTAssertFalse(s.contains("€"), s)
        XCTAssertEqual(MoneyFormat.money([:], empty: "0"), "0")
    }

    // MARK: storage compatibility

    /// expenses.json as written by older versions: single `project`, no currency/category/period,
    /// plus the current format with overrides/flags. Everything must survive decode → encode → decode.
    func testOldExpensesJSONReadsWithoutLoss() throws {
        let json = """
        [
          {"amount": 990, "date": "2026-05-01T09:00:00Z", "project": "/Users/me/Projects/old", "title": "VPS"},
          {"amount": 12.5, "category": "api", "currency": "$", "date": "2026-01-31T00:00:00Z",
           "excludeFromExport": true, "id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF", "note": "ключ",
           "overrides": {"2026-02": 0, "2026-03": 20}, "period": "monthly",
           "projects": ["/Users/me/Projects/a", "/Users/me/Projects/b"], "title": "OpenAI",
           "until": "2026-06-30T00:00:00Z"},
          {"amount": 1200, "category": "domain", "currency": "₽", "date": "2025-02-10T00:00:00Z",
           "period": "yearly", "projects": [], "title": "домен"}
        ]
        """
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let items = try d.decode([Expense].self, from: Data(json.utf8))
        XCTAssertEqual(items.count, 3)

        let old = items[0]
        XCTAssertEqual(old.projects, ["/Users/me/Projects/old"])
        XCTAssertEqual(old.currency, "₽")
        XCTAssertEqual(old.category, .other)
        XCTAssertEqual(old.period, .once)
        XCTAssertEqual(old.amount, 990)

        let cur = items[1]
        XCTAssertEqual(cur.id.uuidString, "6F9619FF-8B86-D011-B42D-00CF4FC964FF")
        XCTAssertEqual(cur.overrides, ["2026-02": 0, "2026-03": 20])
        XCTAssertTrue(cur.excludeFromExport)
        XCTAssertEqual(cur.note, "ключ")
        XCTAssertNotNil(cur.until)
        XCTAssertTrue(items[2].isGeneral)

        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let again = try d.decode([Expense].self, from: e.encode(items))
        XCTAssertEqual(again, items)
        // The legacy `project` key is migrated, not written back.
        XCTAssertFalse(String(decoding: try e.encode(items), as: UTF8.self).contains("\"project\""))
    }
}
