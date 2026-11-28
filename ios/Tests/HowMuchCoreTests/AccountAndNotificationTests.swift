import XCTest
@testable import HowMuchCore

final class AccountAndNotificationTests: XCTestCase {
    private func shift(_ event: String = "Roadshow", day: String = "2026-11-06", id: UUID = UUID()) throws -> Shift {
        try Shift(id: id, event: event, day: day, startMinute: 540, endMinute: 1080, breakMinutes: 60, rate: 15, paymentDue: "2026-11-20")
    }
    func testIndependentRecordChangesMergeWithoutOverwriting() throws {
        var base = TrackerData(); base.shifts = [try shift()]
        var local = base; local.shifts.append(try shift("Wedding"))
        var remote = base; remote.shifts[0].paid = true
        let merged = try AccountMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.shifts.count, 2)
        XCTAssertTrue(merged.shifts.first { $0.id == base.shifts[0].id }!.paid)
    }
    func testSharedEditConflictDoesNotSilentlyOverwrite() throws {
        var base = TrackerData(); base.shifts = [try shift()]
        var local = base; local.shifts[0].location = "Marina"
        var remote = base; remote.shifts[0].location = "Suntec"
        XCTAssertThrowsError(try AccountMerge.merge(base: base, local: local, remote: remote))
        XCTAssertEqual(local.shifts[0].location, "Marina")
        XCTAssertEqual(remote.shifts[0].location, "Suntec")
    }
    func testDeletionsAndIndependentNewJobsMerge() throws {
        var base = TrackerData(); base.shifts = [try shift()]
        var local = base; local.shifts = []
        var remote = base; let added = try shift("Wedding"); remote.shifts.append(added)
        let result = try AccountMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(result.shifts, [added])
    }
    func testFirstLoginDoesNotCombineTwoExistingDatasetsWithoutConsent() throws {
        var local = TrackerData(); local.shifts = [try shift()]
        var remote = TrackerData(); remote.shifts = [try shift("Wedding")]
        XCTAssertThrowsError(try AccountMerge.merge(base: nil, local: local, remote: remote))
        XCTAssertEqual(try AccountMerge.merge(base: nil, local: TrackerData(), remote: remote), remote)
    }
    func testDefaultsIncludeAllRequestedNotificationTypesAndHideDetails() throws {
        var data = TrackerData(); data.shifts = [try shift()]
        let now = try XCTUnwrap(TrackerCalendar.localDate("2026-11-03"))
        let reminders = JobReminderPlan.make(data: data, accountID: "owner-A", now: now)
        XCTAssertEqual(Set(reminders.map(\.kind)), ["start", "end", "upcoming", "payment_due"])
        XCTAssertTrue(reminders.allSatisfy { $0.id.hasPrefix("howmuch.owner-A.") })
        XCTAssertTrue(reminders.allSatisfy { !$0.body.contains("Roadshow") })
        XCTAssertTrue(reminders.allSatisfy { $0.fireDate > now })
    }
    func testPaidJobsHaveNoPaymentDueAlertAndDisabledTypesStayOff() throws {
        var data = TrackerData(); var work = try shift(); work.paid = true; data.shifts = [work]
        var prefs = AppPreferences(); var options = JobNotificationOptions()
        options.upcoming = false; options.ends = false; prefs.notifications = options; data.preferences = prefs
        let now = try XCTUnwrap(TrackerCalendar.localDate("2026-11-03"))
        XCTAssertEqual(JobReminderPlan.make(data: data, accountID: "A", now: now).map(\.kind), ["start"])
        options.enabled = false; prefs.notifications = options; data.preferences = prefs
        XCTAssertTrue(JobReminderPlan.make(data: data, accountID: "A", now: now).isEmpty)
    }
    func testEventDueDateAndDayBeforeAlertsAreGroupedAndIdentifiersAreAccountScoped() throws {
        var data = TrackerData(); data.shifts = [try shift(), try shift()]
        let now = try XCTUnwrap(TrackerCalendar.localDate("2026-11-03"))
        let a = JobReminderPlan.make(data: data, accountID: "A", now: now)
        let b = JobReminderPlan.make(data: data, accountID: "B", now: now)
        XCTAssertEqual(a.filter { $0.kind == "payment_due" }.count, 1)
        XCTAssertEqual(a.filter { $0.kind == "upcoming" }.count, 1)
        XCTAssertTrue(Set(a.map(\.id)).isDisjoint(with: Set(b.map(\.id))))
    }
    func testOvernightEndNotificationUsesFollowingDay() throws {
        let work = try Shift(event: "Night", day: "2026-11-06", startMinute: 1320, endMinute: 120, rate: 20)
        var data = TrackerData(); data.shifts = [work]
        let now = try XCTUnwrap(TrackerCalendar.localDate("2026-11-03"))
        let end = try XCTUnwrap(JobReminderPlan.make(data: data, accountID: "A", now: now).first { $0.kind == "end" })
        XCTAssertEqual(Shift.dayString(end.fireDate), "2026-11-07")
        XCTAssertEqual(end.fireDate, work.endDate)
    }
    func testNotificationCopyIncludesTimesAndKeepsNamesPrivate() throws {
        var data = TrackerData(); var work = try shift(); work.location = "Private venue"; data.shifts = [work]
        let now = try XCTUnwrap(TrackerCalendar.localDate("2026-11-03"))
        let plan = JobReminderPlan.make(data: data, accountID: "A", now: now)
        XCTAssertEqual(plan.first { $0.kind == "start" }?.title, "Shift starts at 09:00")
        XCTAssertEqual(plan.first { $0.kind == "end" }?.title, "Shift ended at 18:00")
        XCTAssertTrue(plan.allSatisfy { !$0.title.contains("Roadshow") && !$0.body.contains("Private venue") && !$0.body.contains("Roadshow") })
        var prefs = AppPreferences(); var options = JobNotificationOptions(); options.showDetails = true; prefs.notifications = options; data.preferences = prefs
        let detailed = JobReminderPlan.make(data: data, accountID: "A", now: now)
        XCTAssertEqual(detailed.first { $0.kind == "start" }?.body, "Roadshow · 09:00–18:00 · Private venue")
        XCTAssertTrue(detailed.first { $0.kind == "end" }!.body.contains("any claims"))
    }
    func testTomorrowDigestRoutesToEarliestJobRegardlessOfInputOrder() throws {
        var data = TrackerData()
        let late = try Shift(event: "Late", day: "2026-11-06", startMinute: 1080, endMinute: 1200, rate: 15)
        let early = try shift("Early")
        data.shifts = [late, early]
        let now = try XCTUnwrap(TrackerCalendar.localDate("2026-11-03"))
        let digest = try XCTUnwrap(JobReminderPlan.make(data: data, accountID: "A", now: now).first { $0.kind == "upcoming" })
        XCTAssertEqual(digest.title, "Tomorrow: 2 shifts")
        XCTAssertEqual(digest.shiftID, early.id)
        XCTAssertTrue(digest.body.contains("09:00"))
    }

    func testMultipleStartRemindersRoundTripAndSkipPassedChoices() throws {
        var data = TrackerData(); let work = try shift(); data.shifts = [work]
        var prefs = AppPreferences(); var options = JobNotificationOptions()
        options.startReminderMinutes = [120, 60, 30, 0, 30]
        prefs.notifications = options; data.preferences = prefs
        let decoded = try JSONDecoder().decode(TrackerData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(decoded.settings.jobNotifications.startReminderMinutes, [120, 60, 30, 0])
        let early = work.startDate.addingTimeInterval(-3 * 3600)
        let reminders = JobReminderPlan.make(data: decoded, accountID: "A", now: early).filter { $0.kind == "start" }
        XCTAssertEqual(reminders.map { Int(work.startDate.timeIntervalSince($0.fireDate) / 60) }, [120, 60, 30, 0])
        XCTAssertEqual(Set(reminders.map(\.id)).count, 4)
        let later = work.startDate.addingTimeInterval(-45 * 60)
        let remaining = JobReminderPlan.make(data: decoded, accountID: "A", now: later).filter { $0.kind == "start" }
        XCTAssertEqual(remaining.map { Int(work.startDate.timeIntervalSince($0.fireDate) / 60) }, [30, 0])
        options.startReminderMinutes = [60, 30]; prefs.notifications = options; data.preferences = prefs
        XCTAssertTrue(JobReminderPlan.make(data: data, accountID: "A", now: work.startDate.addingTimeInterval(-10 * 60)).filter { $0.kind == "start" }.isEmpty)
    }
    func testOldNotificationPreferencesKeepTheirSingleTime() throws {
        let json = #"{"enabled":true,"upcoming":true,"starts":true,"ends":true,"paymentDue":true,"leadMinutes":60,"dayBeforeMinute":1200,"dueMinute":540,"showDetails":false}"#
        let options = try JSONDecoder().decode(JobNotificationOptions.self, from: Data(json.utf8))
        XCTAssertNil(options.startLeadMinutes)
        XCTAssertEqual(options.startReminderMinutes, [60])
        var empty = options; empty.startReminderMinutes = []
        XCTAssertThrowsError(try empty.validate())
        empty.starts = false; XCTAssertNoThrow(try empty.validate())
        empty.startReminderMinutes = [-1]; XCTAssertThrowsError(try empty.validate())
    }

}

extension AccountAndNotificationTests {
    func testTravelIsOptInAndOldPreferencesRemainReadable() throws {
        let original = AppPreferences()
        XCTAssertFalse(original.travelEnabled)
        let roundTrip = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(original))
        XCTAssertFalse(roundTrip.travelEnabled)
        var options = TravelReminderOptions()
        XCTAssertNoThrow(try options.validate())
        options.enabled = true
        XCTAssertThrowsError(try options.validate())
        options.origin = "Singapore Botanic Gardens, Singapore"
        XCTAssertNoThrow(try options.validate())
        var preferences = original; preferences.travel = options
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
        options.mode = "transit"
        XCTAssertThrowsError(try options.validate())
        options.mode = "automobile"; options.arrivalBuffer = 121
        XCTAssertThrowsError(try options.validate())
    }
}

extension AccountAndNotificationTests {
    func testTravelMapsLinksPreserveAddressesAndChosenMode() throws {
        var options = TravelReminderOptions(); options.origin = "A & B, Singapore"
        for mode in ["automobile", "walking", "cycling"] {
            options.mode = mode
            let parts = try XCTUnwrap(URLComponents(url: XCTUnwrap(options.directionsURL(destination: "C #1, Singapore")), resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.host, "maps.apple.com")
            XCTAssertEqual(parts.path, "/directions")
            XCTAssertEqual(parts.queryItems?.first { $0.name == "source" }?.value, options.origin)
            XCTAssertEqual(parts.queryItems?.first { $0.name == "destination" }?.value, "C #1, Singapore")
            XCTAssertEqual(parts.queryItems?.first { $0.name == "mode" }?.value, mode == "automobile" ? "driving" : mode)
        }
        XCTAssertNil(options.directionsURL(destination: "C", modern: false)) // Never silently launch driving for a cyclist on older iOS.
        options.mode = "walking"
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(options.directionsURL(destination: "C", modern: false)), resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "w")
        XCTAssertNil(options.directionsURL(destination: " "))
    }
}
