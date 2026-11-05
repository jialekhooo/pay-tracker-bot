import XCTest
@testable import HowMuchCore

final class ReceiptLabelTests: XCTestCase {
    func testRideAppTotalsUseWhatWasPaidNotTheFare() {
        let grab = "Grab\nWed, 5 Nov 2026 18:42\nFare S$ 18.40\nPlatform fee 0.90\nYou paid S$19.30\nPaid by Mastercard 1234"
        XCTAssertEqual(ReceiptSuggestions(text: grab).amount, Decimal(string: "19.30"))
    }

    func testNETSAndPlainAmountLabelsAreTotals() {
        let food = "TOAST BOX\n05/11/26 12:31\nKaya Toast Set  5.80\nSUBTOTAL 8.40\nGST 9% 0.76\nNETS 9.16"
        XCTAssertEqual(ReceiptSuggestions(text: food).amount, Decimal(string: "9.16"))
        let shop = "POPULAR BOOKSTORE\n4 Nov 2026\nA4 paper x2  11.80\nMarkers  6.50\nAmount 18.30"
        XCTAssertEqual(ReceiptSuggestions(text: shop).amount, Decimal(string: "18.30"))
    }
}

final class ReviewFixTests: XCTestCase {
    private let today = TrackerCalendar.calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9))!

    func testThousandsAndCountsAreReadCorrectly() {
        XCTAssertEqual(JobMessageParser.parse("Roadshow 12 Nov 10am-6pm\nTotal $1,200", today: today).fixedPay, 1200)
        let days = JobMessageParser.parse("Roadshow 12-14 Nov 10am-6pm\nTotal 3 days\n$15/hr", today: today)
        XCTAssertEqual(days.rate, 15); XCTAssertNil(days.fixedPay)
        XCTAssertEqual(JobMessageParser.parse("Event 12 Nov 9am-5pm $1,000/day", today: today).fixedPay, 1000)
    }

    func testLeadingZeroTimesAreMorning() {
        let job = JobMessageParser.parse("Setup 12 Nov 06:00-10:00", today: today)
        XCTAssertEqual(job.dates.first?.startMinute, 6 * 60); XCTAssertEqual(job.dates.first?.endMinute, 10 * 60)
        let long = JobMessageParser.parse("Setup 12 Nov 06:00-12:00", today: today)
        XCTAssertEqual(long.dates.first?.endMinute, 12 * 60)
    }

    func testMonthFirstDateKeepsItsTime() {
        let job = JobMessageParser.parse("Promoter Nov 15, 10-6pm", today: today)
        XCTAssertEqual(job.dates.map(\.day), ["2026-11-15"])
        XCTAssertEqual(job.dates.first?.startMinute, 10 * 60); XCTAssertEqual(job.dates.first?.endMinute, 18 * 60)
    }

    func testLumpSumSharesAddUpExactly() {
        let job = JobMessageParser.parse("Event 12-14 Nov 10am-6pm\nTotal $100", today: today)
        XCTAssertEqual(job.fixedPay, Decimal(string: "33.33")); XCTAssertEqual(job.lumpSum, 100)
    }

    func testExportedBreaksRoundTripExactly() throws {
        let shift = try Shift(event: "Gala", day: "2026-11-02", startMinute: 600, endMinute: 1080, breakMinutes: 50, rate: 15)
        let csv = ShiftCSV.encode([shift])
        XCTAssertTrue(csv.contains("0.83")); XCTAssertFalse(csv.contains("0.8333"))
        XCTAssertEqual(try ShiftCSV.decode(csv).first?.breakMinutes, 50)
    }

    func testPennyKeepsCurrenciesApartAndOnlyCountsWorkedWeeks() throws {
        let past = try Shift(event: "A", day: "2026-10-01", startMinute: 540, endMinute: 1080, rate: 20, rules: { var r = PayRules(); r.currency = "SGD"; return r }(), paymentDue: "2026-10-10")
        let ringgit = try Shift(event: "B", day: "2026-10-02", startMinute: 540, endMinute: 1080, rate: 10, rules: { var r = PayRules(); r.currency = "MYR"; return r }(), paymentDue: "2026-10-10")
        let pet = PetProgress(shifts: [past, ringgit], now: today, currency: "SGD")
        XCTAssertEqual(pet.overdue, 180)
        XCTAssertTrue(pet.message(name: "Penny", currency: "SGD").contains("SGD 180 and MYR 90"))
        var booked: [Shift] = []
        for week in 1...12 { booked.append(try Shift(event: "C", day: Shift.dayString(TrackerCalendar.calendar.date(byAdding: .weekOfYear, value: week, to: today)!), startMinute: 540, endMinute: 600, rate: 20)) }
        XCTAssertFalse(PetProgress(shifts: booked, now: today).hasAchievement("on-a-roll"))
    }
}

final class FieldMergeTests: XCTestCase {
    func testPaidOnTheServerAndANoteEditHereBothSurvive() throws {
        let shift = try Shift(event: "Roadshow", location: "ION", day: "2026-11-02", startMinute: 540, endMinute: 1080, rate: 20)
        var base = TrackerData(); base.shifts = [shift]
        var local = base; local.shifts[0].location = "ION Orchard B2"
        var remote = base; remote.shifts[0].paid = true
        let merged = try AccountMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.shifts[0].location, "ION Orchard B2")
        XCTAssertTrue(merged.shifts[0].paid)
    }

    func testDifferentSettingsChangedOnEachSideBothSurvive() throws {
        var base = TrackerData(); base.preferences = AppPreferences()
        var local = base; local.preferences?.displayName = "Jia Le"
        var remote = base; remote.preferences?.remindersEnabled = true
        let merged = try AccountMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.preferences?.displayName, "Jia Le")
        XCTAssertEqual(merged.preferences?.remindersEnabled, true)
    }

    func testTheSameFieldChangedOnBothSidesStillAsks() throws {
        let shift = try Shift(event: "Roadshow", day: "2026-11-02", startMinute: 540, endMinute: 1080, rate: 20)
        var base = TrackerData(); base.shifts = [shift]
        var local = base; local.shifts[0].location = "A"
        var remote = base; remote.shifts[0].location = "B"
        XCTAssertThrowsError(try AccountMerge.merge(base: base, local: local, remote: remote))
    }
}
