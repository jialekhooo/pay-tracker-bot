import XCTest
@testable import HowMuchCore

final class HowMuchCoreTests: XCTestCase {
    func testPayParityWithPython() throws {
        var rules = PayRules()
        XCTAssertEqual(PayEngine.calculate(hours: Decimal(string: "5.5")!, rate: 25, rules: rules), Decimal(string: "137.50"))
        rules.overtimeAfter = 8
        XCTAssertEqual(PayEngine.calculate(hours: 10, rate: 10, rules: rules), 110)
        XCTAssertEqual(PayEngine.calculate(hours: Decimal(string: "1.005")!, rate: 1, rules: PayRules()), Decimal(string: "1.01"))
    }

    func testOvernightBreaksAndClashes() throws {
        let shift = try Shift(event: "Night", day: "2026-11-03", startMinute: 22 * 60, endMinute: 2 * 60, breakMinutes: 30, rate: 20)
        XCTAssertEqual(shift.hours, Decimal(string: "3.5"))
        XCTAssertEqual(shift.pay, 70)
        let next = try Shift(event: "Early", day: "2026-11-04", startMinute: 60, endMinute: 180, rate: 20)
        XCTAssertTrue(shift.overlaps(next))
        let adjacent = try Shift(event: "Adjacent", day: "2026-11-04", startMinute: 120, endMinute: 180, rate: 20)
        XCTAssertFalse(shift.overlaps(adjacent))
        let paidBreak = try Shift(event: "Day", day: "2026-11-03", startMinute: 540, endMinute: 1080, breakMinutes: 60, paidBreak: true, rate: 15)
        XCTAssertEqual(paidBreak.pay, 135)
    }

    func testInvalidInputsAreRejected() {
        XCTAssertThrowsError(try Shift(event: "", day: "2026-11-03", startMinute: 0, endMinute: 60, rate: 15))
        XCTAssertThrowsError(try Shift(event: "Event", day: "2026-02-30", startMinute: 0, endMinute: 60, rate: 15))
        XCTAssertThrowsError(try Shift(event: "Event", day: "2026-11-03", startMinute: 0, endMinute: 60, breakMinutes: 60, rate: 15))
        XCTAssertNil(ShiftCSV.decimal("12oops"))
        XCTAssertNil(ShiftCSV.decimal("NaN"))
    }

    func testBothTelegramExportFormatsPreservePay() throws {
        let bot = "id,date,start,end,event,location,break_hours,break_paid,hours,pay,currency\r\n1,2026-11-03,22:00,02:00,Night,MBS,0.5,unpaid,3.5,123.45,SGD\r\n"
        let mini = "Shift ID,Date,Start,End,Event,Location,Hours,Break hours,Paid break,Pay,Currency\n1,2026-11-03,22:00,02:00,Night,MBS,3.5,0.5,No,123.45,SGD\n"
        let a = try XCTUnwrap(ShiftCSV.decode(bot).first)
        let b = try XCTUnwrap(ShiftCSV.decode(mini).first)
        XCTAssertEqual(a.pay, Decimal(string: "123.45"))
        XCTAssertEqual(a.fixedPay, a.pay)
        XCTAssertEqual(a.pay, b.pay)
        XCTAssertEqual(a.hours, b.hours)
        XCTAssertEqual(a.breakMinutes, 30)
        let oneMinute = bot.replacingOccurrences(of: "0.5,unpaid", with: "0.01666666666666666666666666667,unpaid")
        XCTAssertEqual(try ShiftCSV.decode(oneMinute).first?.breakMinutes, 1)
        XCTAssertThrowsError(try ShiftCSV.decode(bot.replacingOccurrences(of: "0.5,unpaid", with: "0.501,unpaid")))
    }

    func testCSVQuotedRoundTripAndFailureIsAtomic() throws {
        let shift = try Shift(event: "Wedding, \"VIP\"\nEvening", location: "Marina Bay", day: "2026-11-03", startMinute: 540, endMinute: 1080, rate: 20)
        let roundTrip = try XCTUnwrap(ShiftCSV.decode(ShiftCSV.encode([shift])).first)
        XCTAssertEqual(roundTrip.event, shift.event)
        XCTAssertEqual(roundTrip.pay, shift.pay)
        XCTAssertThrowsError(try ShiftCSV.decode("date,start,end,event,pay,currency\n2026-11-03,09:00,18:00,Valid,10,SGD\n2026-11-03,99:00,18:00,Bad,10,SGD"))
        XCTAssertThrowsError(try ShiftCSV.decode("date,start,end,event,pay,currency\n\"unfinished"))
    }

    func testCSVPreservesPaidStatusAndDueDatesAndAcceptsOlderExports() throws {
        let paid = try Shift(event: "Paid shift", day: "2026-11-03", startMinute: 540, endMinute: 1080,
                             rate: 20, paid: true, paymentDue: "2026-11-20")
        let unpaid = try Shift(event: "Unpaid shift", day: "2026-11-04", startMinute: 540, endMinute: 1080, rate: 20)
        let result = try ShiftCSV.decode(ShiftCSV.encode([paid, unpaid]))
        XCTAssertTrue(result[0].paid); XCTAssertEqual(result[0].paymentDue, "2026-11-20")
        XCTAssertFalse(result[1].paid); XCTAssertNil(result[1].paymentDue)
        XCTAssertEqual(result[0].pay, paid.pay)
        let old = "date,start,end,event,pay,currency\n2026-11-03,09:00,18:00,Old,10,SGD"
        XCTAssertFalse(try XCTUnwrap(ShiftCSV.decode(old).first).paid)
        XCTAssertNil(try ShiftCSV.decode(old).first?.paymentDue)
        let header = "date,start,end,event,pay,currency,paid,payment_due\n"
        for flag in ["Yes", "true", "1", "paid"] {
            XCTAssertTrue(try XCTUnwrap(ShiftCSV.decode(header + "2026-11-03,09:00,18:00,Valid,10,SGD," + flag + ",2026-11-20").first).paid)
        }
        XCTAssertThrowsError(try ShiftCSV.decode(header + "2026-11-03,09:00,18:00,Bad,10,SGD,maybe,2026-11-20"))
        XCTAssertThrowsError(try ShiftCSV.decode(header + "2026-11-03,09:00,18:00,Bad,10,SGD,Yes,2026-02-30"))
    }

    func testArchiveRoundTripPreservesClaimsAndRules() throws {
        var data = TrackerData()
        let shift = try Shift(event: "Roadshow", day: "2026-11-03", startMinute: 540, endMinute: 1080, rate: 20, paid: true)
        data.shifts = [shift]
        data.claims = [CabClaim(shiftID: shift.id, day: shift.day, amount: Decimal(string: "12.34")!, note: "Taxi")]
        XCTAssertNoThrow(try data.validate())
        XCTAssertEqual(try JSONDecoder().decode(TrackerData.self, from: JSONEncoder().encode(data)), data)
        data.shifts[0].day = "invalid"
        XCTAssertThrowsError(try data.validate())
    }

    func testReimportSkipsDuplicatesAndRetainsDifferentRecords() throws {
        let shift = try Shift(sourceID: "1", event: "Roadshow", day: "2026-11-03", startMinute: 540, endMinute: 1080, rate: 20)
        let incoming = try ShiftCSV.decode(ShiftCSV.encode([shift, shift]))
        var data = TrackerData()
        XCTAssertEqual(data.importShifts(incoming), 1)
        XCTAssertEqual(data.importShifts(incoming), 0)
        var different = shift
        different.event = "Wedding"
        XCTAssertEqual(data.importShifts([different]), 1)
        let native = try Shift(event: "Native", day: "2026-11-03", startMinute: 540, endMinute: 1080, rate: 15)
        data.shifts.append(native)
        XCTAssertEqual(data.importShifts(try ShiftCSV.decode(ShiftCSV.encode([native]))), 0)
    }

    func testCalendarIncludesOvernightSpilloverButNotMidnightFinish() throws {
        let overnight = try Shift(event: "Overnight", day: "2026-10-31", startMinute: 1320, endMinute: 360, rate: 20)
        let midnight = try Shift(event: "Ends at midnight", day: "2026-10-31", startMinute: 1080, endMinute: 0, rate: 20)
        let today = try Shift(event: "Today", day: "2026-11-01", startMinute: 540, endMinute: 1080, rate: 20)
        let records = [today, midnight, overnight]
        let first = try XCTUnwrap(TrackerCalendar.localDate("2026-10-31"))
        let second = try XCTUnwrap(TrackerCalendar.localDate("2026-11-01"))
        XCTAssertEqual(TrackerCalendar.shifts(on: first, from: records).map(\.id), [midnight.id, overnight.id])
        XCTAssertEqual(TrackerCalendar.shifts(on: second, from: records).map(\.id), [overnight.id, today.id])
        XCTAssertTrue(TrackerCalendar.shifts(on: TrackerCalendar.localDate("2026-11-02")!, from: records).isEmpty)
    }

    func testCalendarGridUsesMondayAndHandlesLeapYears() throws {
        let november = try XCTUnwrap(TrackerCalendar.localDate("2026-11-03"))
        let days = TrackerCalendar.monthDays(november)
        XCTAssertEqual(days.count % 7, 0)
        XCTAssertEqual(days.prefix(6).compactMap { $0 }.count, 0) // Nov 1, 2026 is Sunday.
        XCTAssertEqual(days.compactMap { $0 }.count, 30)
        let leap = try XCTUnwrap(TrackerCalendar.localDate("2028-02-01"))
        XCTAssertEqual(TrackerCalendar.monthDays(leap).compactMap { $0 }.count, 29)
    }

    func testCalendarExportRollsOverAndEscapesAndFoldsUTF8() throws {
        let event = String(repeating: "展覽", count: 40) + ", VIP; Evening\nNight"
        let shift = try Shift(event: event, location: "Marina, Bay", day: "2026-11-03", startMinute: 22 * 60, endMinute: 2 * 60, rate: 20)
        let ics = CalendarExport.encode([shift], now: shift.startDate)
        XCTAssertTrue(ics.contains("UID:\(shift.id.uuidString)@howmuch"))
        XCTAssertTrue(ics.contains("LOCATION:Marina\\, Bay"))
        XCTAssertTrue(ics.contains("\\; Evening\\nNight"))
        XCTAssertTrue(ics.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "")
        XCTAssertTrue(unfolded.contains("SUMMARY:" + event.replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: "\n", with: "\\n")))
        XCTAssertEqual(shift.endDate.timeIntervalSince(shift.startDate), 4 * 3600)
    }

    func testLiveEarningsAndDefaultDueDate() throws {
        let shift = try Shift(event: "Roadshow", day: "2026-11-03", startMinute: 540, endMinute: 1020, rate: 20)
        XCTAssertEqual(shift.earned(at: shift.startDate), 0)
        XCTAssertEqual(shift.earned(at: shift.startDate.addingTimeInterval(4 * 3600)), 80)
        XCTAssertEqual(shift.earned(at: shift.endDate), 160)
        XCTAssertEqual(shift.state(at: shift.startDate.addingTimeInterval(60)), "Working now")
        let due = TrackerCalendar.defaultDueDate(for: shift.startDate, existing: [], event: shift.event)
        XCTAssertEqual(Shift.dayString(due), "2026-11-20")
    }

    func testOlderArchivesKeepDefaultsAndNewPreferencesRoundTrip() throws {
        var data = TrackerData()
        let old = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(TrackerData.self, from: old)
        XCTAssertEqual(decoded.settings.defaultBreakMinutes, 0)
        var settings = AppPreferences(); settings.reminderMinute = 19 * 60 + 30
        settings.defaultBreakMinutes = 60; settings.eventRates["roadshow"] = 22
        data.preferences = settings
        XCTAssertNoThrow(try data.validate())
        XCTAssertEqual(try JSONDecoder().decode(TrackerData.self, from: JSONEncoder().encode(data)), data)
        settings.reminderMinute = 1440; data.preferences = settings
        XCTAssertThrowsError(try data.validate())
    }
}
