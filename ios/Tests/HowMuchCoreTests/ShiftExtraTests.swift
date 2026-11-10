import XCTest
@testable import HowMuchCore

final class ShiftExtraTests: XCTestCase {
    private func shift(extra: Decimal? = 20) throws -> Shift {
        var shift = try Shift(event: "Roadshow", day: "2026-11-02", startMinute: 9 * 60, endMinute: 17 * 60, rate: 15)
        shift.extra = extra; shift.extraNote = extra == nil ? nil : "Transport allowance"
        return shift
    }

    func testExtraCountsInTotalsButNotInPay() throws {
        let work = try shift()
        XCTAssertEqual(work.pay, 120)
        XCTAssertEqual(work.total, 140)
        XCTAssertEqual(work.earned(at: work.endDate), 140)
        let breakdown = EarningsBreakdown(shifts: [work], now: work.endDate.addingTimeInterval(60))
        XCTAssertEqual(breakdown.owed, 140)
        var data = TrackerData(); data.shifts = [work]
        XCTAssertNoThrow(try data.validate(), "older apps check pay against its rules, so pay stays without the extra")
    }

    func testClearedExtraIsSentAsNullAndOldDataStillLoads() throws {
        let cleared = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shift(extra: nil))) as! [String: Any]
        XCTAssertTrue(cleared["extra"] is NSNull, "the server keeps a missing extra, so a cleared one must be explicit")
        let saved = try JSONEncoder().encode(shift())
        XCTAssertEqual(try JSONDecoder().decode(Shift.self, from: saved).extra, 20)
        var old = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        old.removeValue(forKey: "extra"); old.removeValue(forKey: "extraNote")
        XCTAssertNil(try JSONDecoder().decode(Shift.self, from: JSONSerialization.data(withJSONObject: old)).extra)
    }

    func testFinishingTemplatesAndRepeatsKeepTheExtra() throws {
        let work = try shift()
        XCTAssertEqual(try work.extended(byMinutes: 60).extra, 20)
        XCTAssertEqual(try work.finishing(atMinute: 18 * 60).total, 155)
        XCTAssertEqual(try JobTemplate(name: "Roadshow", shift: work).makeShift(on: "2026-11-09").extraNote, "Transport allowance")
        XCTAssertEqual(try ShiftSeries.make(from: work, every: 7, count: 3).map(\.total), [140, 140, 140])
    }

    func testInvalidExtrasAreRejected() throws {
        for bad: Decimal in [0, -1, Decimal(string: "1.234")!] {
            var data = TrackerData(); data.shifts = [try shift(extra: bad)]
            XCTAssertThrowsError(try data.validate())
        }
    }
}
