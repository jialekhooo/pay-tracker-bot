import XCTest
@testable import HowMuchCore

final class AvailabilityTests: XCTestCase {
    private let calendar = TrackerCalendar.calendar
    private func date(_ day: Int, _ month: Int = 12) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day))! }

    func testMessageGroupsFreePartlyAndBusyDays() throws {
        let morning = try Shift(event: "Setup", day: "2026-12-15", startMinute: 9 * 60, endMinute: 14 * 60, rate: 15)
        let fullDay = try Shift(event: "Roadshow", day: "2026-12-14", startMinute: 10 * 60, endMinute: 22 * 60, rate: 15)
        let evening = try Shift(event: "Gala", day: "2026-12-18", startMinute: 18 * 60, endMinute: 23 * 60, rate: 15)
        let text = Availability.message(from: date(12), to: date(19), shifts: [morning, fullDay, evening], blocked: ["2026-12-19"], calendar: calendar)
        XCTAssertEqual(text, """
        My availability, 12–19 Dec:
        Free all day: 12, 13, 16, 17 Dec
        Part of the day: 15 Dec after 2pm, 18 Dec before 6pm
        Not available: 14, 19 Dec
        """)
    }

    func testRangesAcrossMonthsAndOvernightShifts() throws {
        // A shift from 10pm to 6am also takes the next morning.
        let overnight = try Shift(event: "Countdown", day: "2026-12-31", startMinute: 22 * 60, endMinute: 6 * 60, rate: 15)
        XCTAssertEqual(Availability.day("2027-01-01", shifts: [overnight], blocked: [], calendar: calendar), .partly("after 6am"))
        let text = Availability.message(from: date(29), to: calendar.date(from: DateComponents(year: 2027, month: 1, day: 3))!, shifts: [], blocked: [], calendar: calendar)
        XCTAssertTrue(text.contains("Free all day: 29–31 Dec, 1–3 Jan"), text)
    }

    func testGapBetweenShiftsAndOverlappingBookings() throws {
        let morning = try Shift(event: "Setup", day: "2026-12-15", startMinute: 480, endMinute: 600, rate: 15)
        let evening = try Shift(event: "Gala", day: "2026-12-15", startMinute: 1080, endMinute: 1320, rate: 15)
        XCTAssertEqual(Availability.day("2026-12-15", shifts: [evening, morning], blocked: []), .partly("from 10am to 6pm"))
        let overlap = try Shift(event: "Extension", day: "2026-12-15", startMinute: 540, endMinute: 900, rate: 15)
        XCTAssertEqual(Availability.day("2026-12-15", shifts: [morning, evening, overlap], blocked: []), .busy)
        XCTAssertEqual(Availability.day("2026-12-15", shifts: [morning, evening], blocked: ["2026-12-15"]), .busy)
    }
}
