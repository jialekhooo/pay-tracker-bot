import XCTest
@testable import HowMuchCore

final class WorkPlanningTests: XCTestCase {
    func testRecurringShiftsKeepRulesAndClearImportPaymentAndIdentity() throws {
        var rules = PayRules(); rules.currency = "SGD"; rules.overtimeAfter = 8
        let original = try Shift(sourceID: "telegram-42", event: "Weekend crew", location: "Venue", day: "2026-11-07", startMinute: 1320, endMinute: 360, breakMinutes: 30, rate: 20, rules: rules, paid: true, paymentDue: "2026-11-21")
        let batch = try ShiftSeries.make(from: original, every: 7, count: 3)
        XCTAssertEqual(batch.map(\.day), ["2026-11-07", "2026-11-14", "2026-11-21"])
        XCTAssertEqual(Set(batch.map(\.id)).count, 3)
        XCTAssertTrue(batch.allSatisfy { !$0.paid && $0.sourceID == nil && $0.paymentDue == nil && $0.pay == original.pay && $0.location == "Venue" })
        XCTAssertEqual(batch[0].overtimeAfter, 8)
        XCTAssertThrowsError(try ShiftSeries.make(from: original, every: 0, count: 3))
        XCTAssertThrowsError(try ShiftSeries.make(from: original, every: 7, count: 53))
    }
    func testDailyAndFortnightlyCrossMonthAndLeapDay() throws {
        let shift = try Shift(event: "Leap", day: "2028-02-28", startMinute: 540, endMinute: 1020, rate: 20, fixedPay: 180)
        XCTAssertEqual(try ShiftSeries.make(from: shift, every: 1, count: 3).map(\.day), ["2028-02-28", "2028-02-29", "2028-03-01"])
        XCTAssertEqual(try ShiftSeries.make(from: shift, every: 14, count: 2).last?.day, "2028-03-13")
        XCTAssertEqual(try JobTemplate(name: "Lump sum", shift: shift).makeShift(on: "2028-03-01").fixedPay, 180)
        XCTAssertThrowsError(try JobTemplate(name: " ", shift: shift).validate())
    }
    func testFinancialSummaryTreatsLegacyCostsAsReimbursementsAndSeparatesCurrencies() throws {
        let shift = try Shift(event: "Crew", day: "2026-11-07", startMinute: 540, endMinute: 1020, rate: 20)
        var usd = PayRules(); usd.currency = "USD"
        let other = try Shift(event: "Crew", day: "2026-11-08", startMinute: 540, endMinute: 1020, rate: 100, rules: usd)
        var data = TrackerData(); data.shifts = [shift, other]
        data.claims = [CabClaim(shiftID: shift.id, day: shift.day, amount: 30, note: "Repaid cab"), CabClaim(shiftID: other.id, day: other.day, amount: 99, note: "USD")]
        data.expenses = [CabClaim(shiftID: shift.id, day: shift.day, amount: 12, note: "Own food", category: .food)]
        let summary = EventFinancialSummary(data: data, event: "crew", currency: "SGD")
        XCTAssertEqual(summary.workPay, 160); XCTAssertEqual(summary.reimbursements, 42)
        XCTAssertEqual(summary.expectedCredit, 202); XCTAssertEqual(summary.netWorkPay, 160)
        XCTAssertEqual(summary.effectiveHourly, Decimal(string: "20.00"))
        XCTAssertNil(EventFinancialSummary(data: data, event: "Missing", currency: "SGD").effectiveHourly)
    }
    func testAttachmentsAndExpensesRoundTripAndPhotoRemovalIsExplicitNull() throws {
        let shift = try Shift(event: "Crew", day: "2026-11-07", startMinute: 540, endMinute: 1020, rate: 20)
        var claim = CabClaim(shiftID: shift.id, day: shift.day, amount: 12, note: "Food", category: .food); claim.receiptID = UUID()
        var data = TrackerData(); data.shifts = [shift]; data.claims = [claim]; data.expenses = [claim]
        var settings = AppPreferences(); settings.jobTemplates = [JobTemplate(name: "Usual", shift: shift)]; data.preferences = settings
        XCTAssertEqual(try JSONDecoder().decode(TrackerData.self, from: JSONEncoder().encode(data)), data.reimbursementsOnly)
        claim.receiptID = nil
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(claim)) as? [String: Any])
        XCTAssertTrue(object["receiptID"] is NSNull)
        let old = "{\"id\":\"\(claim.id)\",\"shiftID\":\"\(shift.id)\",\"day\":\"2026-11-07\",\"amount\":12,\"note\":\"Old\"}"
        XCTAssertNil(try JSONDecoder().decode(CabClaim.self, from: Data(old.utf8)).receiptID)
    }
    func testIndependentLegacyReimbursementChangesMergeWithoutLosingClaims() throws {
        let shift = try Shift(event: "Crew", day: "2026-11-07", startMinute: 540, endMinute: 1020, rate: 20)
        var base = TrackerData(); base.shifts = [shift]
        var a = base; var b = base
        a.expenses = [CabClaim(shiftID: shift.id, day: shift.day, amount: 5, note: "Own")]
        b.claims = [CabClaim(shiftID: shift.id, day: shift.day, amount: 10, note: "Repaid")]
        let merged = try AccountMerge.merge(base: base, local: a, remote: b)
        XCTAssertTrue(merged.expenses?.isEmpty != false); XCTAssertEqual(Set(merged.claims.map(\.id)), Set((a.expenses! + b.claims).map(\.id)))
    }
    func testReceiptSuggestionsDoNotChooseSubtotalOrTaxAndValidateDates() {
        let value = ReceiptSuggestions(text: "Subtotal 100.00\nGST 9.00\nTotal SGD 109.00\n2026-11-05")
        XCTAssertEqual(value.amount, 109); XCTAssertEqual(value.day, "2026-11-05")
        XCTAssertNil(ReceiptSuggestions(text: "Subtotal 100.00\nGST 9.00\n2026-02-30").amount)
        XCTAssertNil(ReceiptSuggestions(text: "2026-02-30").day)
        XCTAssertEqual(ReceiptSuggestions(text: "Amount Paid S$1,234.50\n05/11/2026").amount, Decimal(string: "1234.50"))
        XCTAssertEqual(ReceiptSuggestions(text: "05/11/2026").day, "2026-11-05")
    }
    func testReceiptTotalsAcrossColumnsAndAmbiguity() {
        XCTAssertEqual(ReceiptSuggestions(text: "Total\nS$15.80\nGrabCoins 40").amount, Decimal(string: "15.80"))
        XCTAssertEqual(ReceiptSuggestions(text: "Subtotal 100.00\nTotal 109.00\nGrand Total 110.00\nTax 9.00").amount, 110)
        XCTAssertNil(ReceiptSuggestions(text: "Total 10.00\nTotal 11.00").amount)
        XCTAssertNil(ReceiptSuggestions(text: "Total\nGST 9.00\n15.80").amount)
        XCTAssertNil(ReceiptSuggestions(text: "Total -10.00").amount)
        XCTAssertEqual(ReceiptSuggestions(text: "Total S$15. 80").amount, Decimal(string: "15.80"))
        XCTAssertEqual(ReceiptSuggestions(text: "Total: SGD\n15.80").amount, Decimal(string: "15.80"))
    }
    func testLegacyReimbursementMigrationIsIdempotentAndKeepsReceipts() throws {
        let shift = try Shift(event: "Crew", day: "2026-11-07", startMinute: 540, endMinute: 1020, rate: 20)
        var first = CabClaim(shiftID: shift.id, day: shift.day, amount: 10, note: "Cab")
        first.receiptID = UUID()
        var second = first; second.note = "Food"; second.amount = 12
        var data = TrackerData(); data.shifts = [shift]; data.claims = [first]; data.expenses = [second]
        let migrated = try JSONDecoder().decode(TrackerData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(migrated.claims.count, 2)
        XCTAssertEqual(migrated.claims[1].receiptID, first.receiptID)
        XCTAssertNotEqual(migrated.claims[0].id, migrated.claims[1].id)
        XCTAssertEqual(migrated, migrated.reimbursementsOnly)
        XCTAssertEqual(migrated, try JSONDecoder().decode(TrackerData.self, from: JSONEncoder().encode(migrated)))
    }
    func testPublicTransportOptInUsesTransitDirectionsAndFutureAccountScopedReminders() throws {
        let shift = try Shift(event: "Private", day: "2026-11-07", startMinute: 540, endMinute: 1020, rate: 20)
        var options = TravelReminderOptions(); options.enabled = true; options.origin = "A"; options.transit = true
        XCTAssertNoThrow(try options.validate())
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(options.directionsURL(destination: "B")), resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "transit")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(options.directionsURL(destination: "B", modern: false)), resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "r")
        let leave = shift.startDate.addingTimeInterval(-3600)
        let now = leave.addingTimeInterval(-1800)
        let plan = TransitReminderPlan.make(shift: shift, options: options, accountID: "A", leaveAt: leave, showDetails: false, now: now)
        XCTAssertEqual(plan.count, 2); XCTAssertTrue(plan.allSatisfy { $0.id.contains(".A.transit.") && !$0.body.contains("Private") })
        XCTAssertTrue(TransitReminderPlan.make(shift: shift, options: options, accountID: "B", leaveAt: leave, showDetails: true, now: shift.endDate).isEmpty)
        XCTAssertTrue(TransitReminderPlan.make(shift: shift, options: options, accountID: "A", leaveAt: leave, showDetails: false, now: leave.addingTimeInterval(1)).isEmpty)
        options.enabled = false
        XCTAssertTrue(TransitReminderPlan.make(shift: shift, options: options, accountID: "A", leaveAt: leave, showDetails: true, now: now).isEmpty)
    }
}
