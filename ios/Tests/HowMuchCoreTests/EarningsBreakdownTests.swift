import XCTest
@testable import HowMuchCore

final class EarningsBreakdownTests: XCTestCase {
    private var calendar: Calendar { TrackerCalendar.calendar }
    private func shift(_ day: String, _ start: Int, _ end: Int, paid: Bool = false) throws -> Shift {
        try Shift(event: "Roadshow", day: day, startMinute: start * 60, endMinute: end * 60, rate: 20, paid: paid)
    }

    func testOnlyWorkedTimeCountsAsEarned() throws {
        let paid = try shift("2026-11-02", 9, 18, paid: true)    // 9h, SGD 180, received
        let owed = try shift("2026-11-03", 9, 18)                // 9h, SGD 180, not received
        let today = try shift("2026-11-05", 10, 14)              // 4h, SGD 80, halfway at noon
        let later = try shift("2026-11-20", 9, 18)               // booked, SGD 180
        let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))!
        let money = EarningsBreakdown(shifts: [paid, owed, today, later], now: noon)
        XCTAssertEqual(money.paid, 180)
        XCTAssertEqual(money.owed, 220)       // 180 + half of today's 80
        XCTAssertEqual(money.booked, 220)     // the other 40 today + 180 later
        XCTAssertEqual(money.earned, 400)
        XCTAssertEqual(money.total, 620)
        XCTAssertEqual(money.hoursWorked, 20) // 9 + 9 + 2 so far today
        XCTAssertEqual(money.shiftsWorked, 2)
        XCTAssertEqual(money.shiftsBooked, 2)
    }

    func testAPaidAdvanceOnAFutureShiftStaysBooked() throws {
        let advance = try shift("2026-11-20", 9, 18, paid: true)
        let money = EarningsBreakdown(shifts: [advance], now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 5))!)
        XCTAssertEqual(money.earned, 0)
        XCTAssertEqual(money.booked, 180)
    }
}
