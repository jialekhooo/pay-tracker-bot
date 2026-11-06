import XCTest
@testable import HowMuchCore

final class JobMessageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return calendar
    }
    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 5))! }
    private func parse(_ text: String) -> PastedJob { JobMessageParser.parse(text, today: today, calendar: calendar) }
    private func slots(_ job: PastedJob) -> [String] {
        job.dates.map { "\($0.day) \(Shift.clock($0.startMinute))-\(Shift.clock($0.endMinute))" }
    }

    func testWhatsAppOfferWithVenueAddressAndDateRanges() {
        let job = parse("""
        ni hao! you free for this?

        Location: The Singapore EDITION Hotel
        Address: 38 Cuscaden Rd, Singapore 249731

        12th Nov 1200-2100hrs
        13-14th Nov 0800-2000hrs
        15th Nov 0900-2000hrs
        """)
        XCTAssertEqual(slots(job), ["2026-11-12 12:00-21:00", "2026-11-13 08:00-20:00",
                                    "2026-11-14 08:00-20:00", "2026-11-15 09:00-20:00"])
        XCTAssertEqual(job.location, "The Singapore EDITION Hotel, 38 Cuscaden Rd, Singapore 249731")
        XCTAssertEqual(job.name, "The Singapore EDITION Hotel")
        XCTAssertNil(job.rate); XCTAssertNil(job.fixedPay)
        XCTAssertTrue(job.skipped.isEmpty, "\(job.skipped)")
    }

    func testTelegramBotStyleLines() {
        // 12 August is months behind 5 November, so it means next year.
        XCTAssertEqual(slots(parse("Wedding gig 12/8 6pm-11.30pm 25/h @ Marina Bay Sands")), ["2027-08-12 18:00-23:30"])
        let wedding = parse("Wedding gig 12/12 6pm-11.30pm 25/h @ Marina Bay Sands")
        XCTAssertEqual(slots(wedding), ["2026-12-12 18:00-23:30"])
        XCTAssertEqual(wedding.event, "Wedding gig")
        XCTAssertEqual(wedding.location, "Marina Bay Sands")
        XCTAssertEqual(wedding.rate, 25)

        let iso = parse("2026-08-12 18:00 23:30 Wedding gig")
        XCTAssertEqual(slots(iso), ["2026-08-12 18:00-23:30"])
        XCTAssertEqual(iso.event, "Wedding gig")

        let roadshow = parse("Roadshow today 9am to 5pm")
        XCTAssertEqual(slots(roadshow), ["2026-11-05 09:00-17:00"])
        XCTAssertEqual(roadshow.event, "Roadshow")

        let superReturn = parse("28/11 0700 - 1900 SuperReturn @ MBS 20/h")
        XCTAssertEqual(slots(superReturn), ["2026-11-28 07:00-19:00"])
        XCTAssertEqual(superReturn.event, "SuperReturn"); XCTAssertEqual(superReturn.location, "MBS"); XCTAssertEqual(superReturn.rate, 20)
    }

    func testLabelledFieldsTimesOnTheirOwnLineAndPay() {
        let job = parse("""
        Event: Hermes Private Sale
        Venue: Marina Bay Sands Expo
        Dates: 13, 14 & 16 Nov
        Time: 9am - 6pm
        Pay: $15/hr
        Break: 1hr
        Contact: Jia Le 9123 4567
        Attire: all black
        """)
        XCTAssertEqual(job.event, "Hermes Private Sale")
        XCTAssertEqual(job.location, "Marina Bay Sands Expo")
        XCTAssertEqual(slots(job), ["2026-11-13 09:00-18:00", "2026-11-14 09:00-18:00", "2026-11-16 09:00-18:00"])
        XCTAssertEqual(job.rate, 15)
        XCTAssertEqual(job.breakMinutes, 60)
        XCTAssertTrue(job.skipped.isEmpty, "\(job.skipped)")
    }

    func testMonthFirstRangesOvernightAndNextYear() {
        XCTAssertEqual(slots(parse("Nov 20-22 10pm-2am")), ["2026-11-20 22:00-02:00", "2026-11-21 22:00-02:00", "2026-11-22 22:00-02:00"])
        XCTAssertEqual(slots(parse("5 Jan 9-6")), ["2027-01-05 09:00-18:00"])
        XCTAssertEqual(slots(parse("30 Nov - 2 Dec 0800-1700")), ["2026-11-30 08:00-17:00", "2026-12-01 08:00-17:00", "2026-12-02 08:00-17:00"])
        XCTAssertEqual(slots(parse("Wed 12 Nov (Wed) 11-2pm")), ["2026-11-12 11:00-14:00"])
    }

    func testPerDayAndLumpSumPay() {
        let daily = parse("12 Nov 9am-6pm\n$150/day")
        XCTAssertEqual(daily.fixedPay, 150); XCTAssertNil(daily.rate)

        let lump = parse("SGD 500 lump sum\n12-15 Nov 9am-6pm")
        XCTAssertEqual(lump.dates.count, 4)
        XCTAssertEqual(lump.fixedPay, 125)
        XCTAssertEqual(lump.currency, "SGD")
        XCTAssertFalse(lump.notes.isEmpty)
    }

    func testUnreadableLinesAreReportedNotGuessed() {
        let job = parse("Hello!\nNeed 3 pax\nAround 4 hours")
        XCTAssertTrue(job.dates.isEmpty)
        XCTAssertEqual(job.skipped, ["Need 3 pax", "Around 4 hours"])
    }

    func testDatesWithoutAnyTimeAreFlagged() {
        let job = parse("12 Nov and 13 Nov")
        XCTAssertTrue(job.dates.isEmpty)
        XCTAssertEqual(job.notes.count, 1)
    }

    func testFinishingLaterRecalculatesPayWithOvertime() throws {
        var rules = PayRules(); rules.overtimeAfter = 8
        let shift = try Shift(event: "Expo", day: "2026-11-12", startMinute: 9 * 60, endMinute: 17 * 60, rate: 20, rules: rules)
        XCTAssertEqual(shift.pay, 160)
        let later = try shift.finishing(atMinute: 19 * 60)
        XCTAssertEqual(later.id, shift.id)
        XCTAssertEqual(later.pay, 160 + 2 * 30)
        let finish = calendar.date(byAdding: .hour, value: 10, to: shift.startDate)!
        XCTAssertThrowsError(try LiveShiftPlanner.endMinute(for: shift.startDate.addingTimeInterval(-60), of: shift))
        XCTAssertNoThrow(try LiveShiftPlanner.endMinute(for: finish, of: shift))
    }

    func testLiveShiftSelectionAndFinishPrompts() throws {
        let morning = try Shift(event: "A", day: "2026-11-12", startMinute: 9 * 60, endMinute: 12 * 60, rate: 15)
        let evening = try Shift(event: "B", day: "2026-11-12", startMinute: 18 * 60, endMinute: 22 * 60, rate: 15)
        let flat = try Shift(event: "C", day: "2026-11-12", startMinute: 13 * 60, endMinute: 14 * 60, rate: 0, fixedPay: 50)
        let all = [evening, morning, flat]
        XCTAssertEqual(LiveShiftPlanner.current(in: all, at: morning.startDate.addingTimeInterval(-10 * 60))?.id, morning.id)
        XCTAssertNil(LiveShiftPlanner.current(in: all, at: morning.startDate.addingTimeInterval(-40 * 60)))
        XCTAssertEqual(LiveShiftPlanner.current(in: all, at: evening.startDate.addingTimeInterval(60))?.id, evening.id)
        let afterwards = flat.endDate.addingTimeInterval(60)
        XCTAssertEqual(LiveShiftPlanner.awaitingFinish(in: all, confirmed: [], at: afterwards).map(\.id), [morning.id])
        XCTAssertTrue(LiveShiftPlanner.awaitingFinish(in: all, confirmed: [morning.id], at: afterwards).isEmpty)
    }

    func testFinishLinkRoundTripsOnlyForItsAccount() {
        let account = UUID().uuidString.lowercased(), id = UUID()
        let url = WidgetLink.finish(id).url(accountID: account)
        XCTAssertEqual(WidgetLink.parse(url, accountID: account), .finish(id))
        XCTAssertNil(WidgetLink.parse(url, accountID: UUID().uuidString))
    }

    func testEachDayCanHaveItsOwnTimeOnALaterLine() {
        let job = parse("""
        *LAST 3 SLOTS*
        Event crew wanted for AI pop up | 19, 21, 22 Nov | New Bahru
        $$13/h

        Dates and time
        19th: 3.30pm - 6pm (Briefing + private showcase)
        21,22nd: 9am - 6pm

        Attire: Plain black tshirt, black pants/ jeans (non-faded, non-ripped), plain black or white sneakers

        Scope: Help to greet people and explain the activities within the space

        Those available please PM me
        """)
        XCTAssertEqual(job.dates, [
            PastedJobDate(day: "2026-11-19", startMinute: 15 * 60 + 30, endMinute: 18 * 60),
            PastedJobDate(day: "2026-11-21", startMinute: 9 * 60, endMinute: 18 * 60),
            PastedJobDate(day: "2026-11-22", startMinute: 9 * 60, endMinute: 18 * 60),
        ])
        XCTAssertEqual(job.rate, 13)
        XCTAssertEqual(job.location, "New Bahru")
        XCTAssertEqual(job.event, "AI pop up")
    }

    func testDayTimesAcceptRangesAndAmpersands() {
        let job = parse("Roadshow 12-14 Nov @ VivoCity\n12 & 13: 10am-6pm\n14th: 2pm-10pm")
        XCTAssertEqual(job.dates.map { "\($0.day) \($0.startMinute)-\($0.endMinute)" },
                       ["2026-11-12 600-1080", "2026-11-13 600-1080", "2026-11-14 840-1320"])
        // A clock time at the start of a line is not mistaken for a day.
        let clock = parse("Roadshow 12 Nov\n10:00am - 6pm")
        XCTAssertEqual(clock.dates, [PastedJobDate(day: "2026-11-12", startMinute: 600, endMinute: 1080)])
    }

    func testHeadingLineNamesTheEventWhenNoDateLineDoes() {
        let job = parse("Nike Pop-up\n19 Nov 3.30pm-6pm\n$15/h")
        XCTAssertEqual(job.event, "Nike Pop-up")
        XCTAssertEqual(job.rate, 15)
        XCTAssertEqual(slots(job), ["2026-11-19 15:30-18:00"])
        // Recruiting words in front of the heading are dropped.
        XCTAssertEqual(parse("Crew wanted for Nike Pop-up\n19th Nov: 3.30pm - 6pm\n21,22nd Nov: 9am - 6pm").event, "Nike Pop-up")
        // A name on the date line still wins over the heading.
        XCTAssertEqual(parse("Weekend gigs\nWedding gig 12/11 6pm-11pm").event, "Wedding gig")
        // An event label wins too.
        XCTAssertEqual(parse("Weekend gigs\nEvent: Hermes Sale\n12 Nov 9am-6pm").event, "Hermes Sale")
    }

    func testGreetingsQuestionsAndLaterPlainLinesAreNotEventNames() {
        XCTAssertNil(parse("Hi all\n12 Nov 9am-6pm").event)
        XCTAssertNil(parse("Anyone free this weekend?\n12 Nov 9am-6pm").event)
        XCTAssertNil(parse("Looking for promoters\n12 Nov 9am-6pm").event)
        XCTAssertNil(parse("12 Nov 9am-6pm\nDates and time\nThose available please PM me").event)
    }
}
