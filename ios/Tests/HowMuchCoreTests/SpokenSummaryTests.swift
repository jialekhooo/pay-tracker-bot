import XCTest
@testable import HowMuchCore

final class SpokenSummaryTests: XCTestCase {
    // Shifts place their times in the phone's time zone, so the test clock does too.
    private var calendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current; calendar.firstWeekday = 2; return calendar }
    /// Wednesday 4 Nov 2026, noon.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))! }
    private func shift(_ day: String, _ event: String = "Roadshow", rate: Decimal = 20, currency: String = "SGD",
                       paid: Bool = false, due: String? = nil) throws -> Shift {
        var rules = PayRules(); rules.currency = currency
        return try Shift(event: event, day: day, startMinute: 9 * 60, endMinute: 18 * 60, breakMinutes: 60, rate: rate, rules: rules, paid: paid, paymentDue: due)
    }

    func testWeekSplitsWorkedPayFromBookedPay() throws {
        let shifts = [try shift("2026-11-02"), try shift("2026-11-03"), try shift("2026-11-05"), try shift("2026-10-30")]
        XCTAssertEqual(SpokenSummary.earnings(shifts, period: .week, now: now, calendar: calendar),
                       "This week you've earned SGD 320 from 2 shifts, with SGD 160 more booked.")
    }

    func testMonthBeforeAnyShiftHasFinished() throws {
        let early = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8))!
        XCTAssertEqual(SpokenSummary.earnings([try shift("2026-11-20", rate: Decimal(string: "18.5")!)], period: .month, now: early, calendar: calendar),
                       "You haven't finished a shift this month yet. SGD 148 is booked across 1 shift.")
        XCTAssertEqual(SpokenSummary.earnings([], period: .month, now: early, calendar: calendar), "You have no shifts this month.")
    }

    func testCurrenciesStaySeparate() throws {
        let shifts = [try shift("2026-11-02"), try shift("2026-11-03", rate: 10, currency: "MYR")]
        XCTAssertEqual(SpokenSummary.earnings(shifts, period: .week, now: now, calendar: calendar),
                       "This week you've earned SGD 160 and MYR 80 from 2 shifts.")
    }

    func testOwedCountsFinishedUnpaidShiftsAndOverdueOnes() throws {
        let shifts = [try shift("2026-10-01", "Wedding reception", due: "2026-10-15"),
                      try shift("2026-10-20", "Brand launch", due: "2026-11-30"),
                      try shift("2026-10-21", paid: true),
                      try shift("2026-11-06")]
        XCTAssertEqual(SpokenSummary.owed(shifts, now: now),
                       "You're owed SGD 320 for 2 shifts. SGD 160 of it is overdue, the oldest from Wedding reception.")
        XCTAssertEqual(SpokenSummary.owed([try shift("2026-10-21", paid: true)], now: now), "Nothing is owed. Every finished shift is marked paid.")
    }

    func testAmountsShowCentsOnlyWhenNeeded() {
        XCTAssertEqual(SpokenSummary.amount(1234, "SGD"), "SGD 1,234")
        XCTAssertEqual(SpokenSummary.amount(Decimal(string: "72.5")!, "SGD"), "SGD 72.50")
    }

    func testExtendingAShiftMovesTheFinishAndRecalculatesPay() throws {
        let base = try shift("2026-11-04")
        let later = try base.extended(byMinutes: 30)
        XCTAssertEqual(later.endMinute, 18 * 60 + 30)
        XCTAssertEqual(later.pay, 170)
        let overnight = try Shift(event: "Gala", day: "2026-11-04", startMinute: 18 * 60, endMinute: 23 * 60 + 45, rate: 20)
        XCTAssertEqual(try overnight.extended(byMinutes: 30).endMinute, 15)
        let long = try Shift(event: "Long", day: "2026-11-04", startMinute: 6 * 60, endMinute: 5 * 60 + 45, rate: 20)
        XCTAssertThrowsError(try long.extended(byMinutes: 30))
    }
}
