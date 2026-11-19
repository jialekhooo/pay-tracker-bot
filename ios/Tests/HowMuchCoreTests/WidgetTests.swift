import XCTest
@testable import HowMuchCore

final class WidgetTests: XCTestCase {
    let owner = "00000000-0000-4000-8000-000000000001"
    let other = "00000000-0000-4000-8000-000000000002"
    var now: Date { TrackerCalendar.localDate("2026-11-04")! }
    func shift(_ event: String, _ day: String, start: Int = 9*60, end: Int = 18*60, currency: String = "SGD", paid: Bool = false) throws -> Shift {
        var rules = PayRules(); rules.currency = currency
        return try Shift(event: event, location: "Suntec", day: day, startMinute: start, endMinute: end,
            breakMinutes: 60, rate: 20, rules: rules, paid: paid)
    }
    func testUpcomingIncludesWorkingAndOvernightExcludesEndedAndFiltersCurrency() throws {
        var data = TrackerData()
        let ended = try shift("Ended", "2026-11-03")
        let working = try shift("Working", "2026-11-04")
        let overnight = try shift("Overnight", "2026-11-04", start: 22*60, end: 6*60)
        let usd = try shift("USD", "2026-11-05", currency: "USD")
        data.shifts = [usd, overnight, ended, working]
        let snapshot = WidgetSnapshot(data: data, accountID: owner, updatedAt: now)
        XCTAssertEqual(snapshot.upcoming(at: now).map(\.id), [working.id, overnight.id, usd.id])
        XCTAssertEqual(snapshot.upcoming(at: now, currency: "USD").map(\.id), [usd.id])
        XCTAssertEqual(snapshot.upcoming(at: overnight.endDate).map(\.id), [usd.id])
    }
    func testEventsGroupCaseInsensitivelyAndNeverMixCurrenciesOrCompletedWork() throws {
        var data = TrackerData()
        data.shifts = [try shift("Roadshow", "2026-11-03"), try shift("Roadshow", "2026-11-05"),
            try shift("roadshow", "2026-11-06"), try shift("Roadshow", "2026-11-07", currency: "USD")]
        let events = WidgetSnapshot(data: data, accountID: owner, updatedAt: now).events(at: now)
        XCTAssertEqual(events.count, 2); XCTAssertEqual(events[0].shifts.count, 2)
        XCTAssertEqual(events[0].pay, 320); XCTAssertEqual(events[1].pay, 160)
    }
    func testMonthlySummaryUsesScheduledWorkOnlyAndCompletedUnpaidBalance() throws {
        var data = TrackerData()
        data.shifts = [try shift("Paid", "2026-11-02", paid: true), try shift("Due", "2026-11-03"),
            try shift("Future", "2026-11-06"), try shift("Other month", "2026-10-02"), try shift("USD", "2026-11-06", currency: "USD")]
        data.claims = [CabClaim(shiftID: data.shifts[0].id, day: "2026-11-02", amount: 100, note: "Private claim", category: .food)]
        let month = WidgetSnapshot(data: data, accountID: owner, updatedAt: now).month(at: now, currency: "SGD")
        XCTAssertEqual(month.shifts.count, 3); XCTAssertEqual(month.pay, 480); XCTAssertEqual(month.hours, 24)
        XCTAssertEqual(month.awaitingPayment, 160)
    }
    func testProjectionExcludesSensitiveUnnecessaryFieldsAndRoundTrips() throws {
        var data = TrackerData(); data.shifts = [try shift("Shift", "2026-11-05")]
        var prefs = AppPreferences(); prefs.displayName = "Private profile"; prefs.avatar = Data([1,2,3]); prefs.payers = ["Shift":"Private payer"]; data.preferences = prefs
        data.claims = [CabClaim(shiftID: data.shifts[0].id, day: "2026-11-05", amount: 10, note: "Private claim")]
        let snapshot = WidgetSnapshot(data: data, accountID: owner, updatedAt: now)
        let bytes = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: bytes), snapshot)
        let json = String(decoding: bytes, as: UTF8.self)
        for secret in ["Private profile", "Private payer", "Private claim", "avatar", "payers", "claims", "breakMinutes", "rate"] { XCTAssertFalse(json.contains(secret)) }
    }
    func testFileAccountReplacementClearCorruptionAndExpiry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = WidgetSnapshot(data: TrackerData(), accountID: owner, updatedAt: now)
        try WidgetSnapshotFile.write(first, directory: directory)
        XCTAssertEqual(WidgetSnapshotFile.read(directory: directory, now: now)?.accountID, owner)
        XCTAssertNil(WidgetSnapshotFile.read(directory: directory, now: now.addingTimeInterval(WidgetSnapshot.maximumAge)))
        let second = WidgetSnapshot(data: TrackerData(), accountID: other, updatedAt: now)
        try WidgetSnapshotFile.write(second, directory: directory)
        XCTAssertEqual(WidgetSnapshotFile.read(directory: directory, now: now), second)
        try WidgetSnapshotFile.clear(directory: directory); XCTAssertNil(WidgetSnapshotFile.read(directory: directory, now: now))
        try WidgetSnapshotFile.clear(directory: directory)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("widgets.json"))
        XCTAssertNil(WidgetSnapshotFile.read(directory: directory, now: now))
        XCTAssertFalse(WidgetSnapshot(data: TrackerData(), accountID: "bad", updatedAt: now).isCurrent(at: now))
    }
    func testTimelineSchedulesStartEndMidnightAndSnapshotExpiry() throws {
        var data = TrackerData(); let work = try shift("Job", "2026-11-04", start: 13*60, end: 20*60); data.shifts = [work]
        let snapshot = WidgetSnapshot(data: data, accountID: owner, updatedAt: now.addingTimeInterval(-WidgetSnapshot.maximumAge + 3600))
        let dates = snapshot.timelineDates(from: now)
        XCTAssertEqual(dates.first, now); XCTAssertTrue(dates.contains(work.startDate)); XCTAssertTrue(dates.contains(work.endDate))
        XCTAssertTrue(dates.contains(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!))
        XCTAssertTrue(dates.contains(now.addingTimeInterval(3600))); XCTAssertEqual(dates, dates.sorted())
    }
    func testCalendarGridAlignmentLeapYearAndSixWeekMonth() {
        let snapshot = WidgetSnapshot(data: TrackerData(), accountID: owner, updatedAt: now)
        let november = snapshot.calendarDays(at: now)
        XCTAssertEqual(november.count, 42)
        XCTAssertTrue(november.prefix(6).allSatisfy { $0.date == nil })
        XCTAssertEqual(november.compactMap(\.date).count, 30)
        let february = snapshot.calendarDays(at: TrackerCalendar.localDate("2028-02-10")!)
        XCTAssertEqual(february.compactMap(\.date).count, 29)
        XCTAssertEqual(february.count % 7, 0)
    }
    func testCalendarMarksCompletedUpcomingAndOvernightWorkWithoutMixingCurrencies() throws {
        var data = TrackerData()
        data.shifts = [try shift("Previous month overnight", "2026-10-31", start: 22*60, end: 6*60),
            try shift("Midnight finish", "2026-11-02", start: 18*60, end: 0),
            try shift("Future", "2026-11-06"), try shift("USD", "2026-11-06", currency: "USD")]
        let snapshot = WidgetSnapshot(data: data, accountID: owner, updatedAt: now)
        func count(_ key: String, _ currency: String? = nil) -> Int? {
            snapshot.calendarDays(at: now, currency: currency).first { $0.date.map(Shift.dayString) == key }?.shiftCount
        }
        XCTAssertEqual(count("2026-11-01"), 1)
        XCTAssertEqual(count("2026-11-02"), 1)
        XCTAssertEqual(count("2026-11-03"), 0)
        XCTAssertEqual(count("2026-11-06"), 2)
        XCTAssertEqual(count("2026-11-06", "SGD"), 1)
        XCTAssertEqual(count("2026-11-07"), 0)
        for day in ["2026-02-30", "2026-11-4", "bad"] {
            let url = URL(string: "howmuch://widget/calendar?account=" + owner + "&day=" + day)!
            XCTAssertNil(WidgetLink.parse(url, accountID: owner))
        }
        XCTAssertNil(WidgetLink.parse(URL(string: "howmuch://widget/calendar?account=" + owner + "&day=2026-11-04&day=2026-11-05")!, accountID: owner))
    }
    func testWidgetLinksRoundTripAndRejectOtherAccountsOrMalformedLinks() {
        for link in [WidgetLink.shift(UUID()), .event(UUID()), .earnings, .calendar("2026-11-04")] {
            let url = link.url(accountID: owner)
            XCTAssertEqual(WidgetLink.parse(url, accountID: owner), link)
            XCTAssertNil(WidgetLink.parse(url, accountID: other))
        }
        for text in ["https://widget/earnings?account="+owner, "howmuch://widget/earnings?account="+owner+"&account="+other,
            "howmuch://widget/shift?account="+owner+"&id=bad", "howmuch://widget/unknown?account="+owner, "howmuch://widget/earnings"] {
            XCTAssertNil(WidgetLink.parse(URL(string: text)!, accountID: owner))
        }
    }
}
