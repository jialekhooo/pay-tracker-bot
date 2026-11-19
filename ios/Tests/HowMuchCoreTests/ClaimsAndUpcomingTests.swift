import XCTest
@testable import HowMuchCore

final class ClaimsAndUpcomingTests: XCTestCase {
    func testLegacyCabAndAllClaimCategoriesArchiveRoundTrip() throws {
        let shift = try Shift(event: "Work", day: "2026-11-03", startMinute: 540, endMinute: 1020, rate: 15)
        let id = UUID()
        let legacy = "{\"id\":\"\(id)\",\"shiftID\":\"\(shift.id)\",\"day\":\"2026-11-03\",\"amount\":12.34,\"note\":\"Taxi\"}"
        let decoded = try JSONDecoder().decode(CabClaim.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.category, .cab); XCTAssertEqual(decoded.id, id)
        var data = TrackerData(); data.shifts = [shift]
        data.claims = ClaimCategory.allCases.map { CabClaim(shiftID: shift.id, day: shift.day, amount: Decimal(string: "12.34")!, note: $0.title, category: $0) }
        try data.validate()
        XCTAssertEqual(try JSONDecoder().decode(TrackerData.self, from: JSONEncoder().encode(data)), data)
        XCTAssertEqual(data.shifts[0].pay, 120)
        XCTAssertEqual(data.claims.reduce(0) { $0 + $1.amount }, Decimal(string: "37.02")!)
        XCTAssertThrowsError(try JSONDecoder().decode(CabClaim.self, from: Data(legacy.dropLast().appending(",\"category\":\"unknown\"}").utf8)))
    }
    func testUpcomingGroupsUseNearestShiftAndKeepCurrenciesAndCompletedWorkSeparate() throws {
        var usd = PayRules(); usd.currency = "USD"
        let records = [
            try Shift(event: "Roadshow", day: "2026-11-02", startMinute: 540, endMinute: 1020, rate: 15),
            try Shift(event: "Roadshow", location: "Venue", day: "2026-11-04", startMinute: 540, endMinute: 1020, rate: 15),
            try Shift(event: "ROADSHOW", location: "Venue", day: "2026-11-05", startMinute: 540, endMinute: 1020, rate: 15),
            try Shift(event: "Roadshow", day: "2026-11-06", startMinute: 540, endMinute: 1020, rate: 15, rules: usd),
            try Shift(event: "Working now", day: "2026-11-03", startMinute: 540, endMinute: 1080, rate: 20)
        ]
        let now = TrackerCalendar.localDate("2026-11-03")!
        let groups = UpcomingEvents.groups(records, now: now)
        XCTAssertEqual(groups.count, 3); XCTAssertEqual(groups[0].event, "Working now")
        XCTAssertEqual(groups[1].currency, "SGD"); XCTAssertEqual(groups[1].shifts.count, 2)
        XCTAssertEqual(groups[1].scheduledPay, 240)
        XCTAssertFalse(groups.flatMap(\.shifts).contains { $0.id == records[0].id })
        XCTAssertEqual(UpcomingEvents.groups(records, now: now, ascending: false).map(\.id), groups.reversed().map(\.id))
        let range = records.filter { $0.day == "2026-11-04" }
        XCTAssertEqual(UpcomingEvents.groups(range, now: now).flatMap(\.shifts), range)
        XCTAssertTrue(UpcomingEvents.groups([], now: now).isEmpty)
    }
    func testUpcomingGroupingPreferenceMigratesAndRoundTrips() throws {
        let old = try JSONEncoder().encode(AppPreferences())
        XCTAssertNil(try JSONDecoder().decode(AppPreferences.self, from: old).groupUpcomingByEvent)
        var preferences = AppPreferences(); preferences.groupUpcomingByEvent = true
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences)).groupUpcomingByEvent, true)
        preferences.groupUpcomingByEvent = false
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences)).groupUpcomingByEvent, false)
    }
}
