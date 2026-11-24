import XCTest
@testable import HowMuchCore

final class FreePlanTests: XCTestCase {
    private func data(_ events: [String]) throws -> TrackerData {
        var data = TrackerData()
        for (index, name) in events.enumerated() {
            data.shifts.append(try Shift(event: name, day: "2026-11-\(String(format: "%02d", index + 1))", startMinute: 9 * 60, endMinute: 12 * 60, rate: 20))
        }
        return data
    }

    func testFiveEventsFitAndASixthDoesNot() throws {
        let four = try data(["A", "B", "C", "D"]), five = try data(["A", "B", "C", "D", "E"]), six = try data(["A", "B", "C", "D", "E", "F"])
        XCTAssertFalse(FreePlan.exceedsLimit(before: four, after: five))
        XCTAssertTrue(FreePlan.exceedsLimit(before: five, after: six))
        XCTAssertFalse(FreePlan.needsPro(forEvent: "E", in: four))
        XCTAssertTrue(FreePlan.needsPro(forEvent: "F", in: five))
    }

    func testMoreShiftsInAnExistingEventAreFree() throws {
        let five = try data(["A", "B", "C", "D", "E"])
        let more = try data(["A", "B", "C", "D", "E", "e ", "a"])  // same events, other case and spacing
        XCTAssertEqual(FreePlan.events(in: more).count, 5)
        XCTAssertFalse(FreePlan.exceedsLimit(before: five, after: more))
        XCTAssertFalse(FreePlan.needsPro(forEvent: " b ", in: five))
    }

    func testAnAccountAboveTheLimitKeepsItsEventsButCantAddMore() throws {
        let eight = try data(["A", "B", "C", "D", "E", "F", "G", "H"])
        let seven = try data(["A", "B", "C", "D", "E", "F", "G"])
        let nine = try data(["A", "B", "C", "D", "E", "F", "G", "H", "I"])
        XCTAssertFalse(FreePlan.exceedsLimit(before: eight, after: eight))
        XCTAssertFalse(FreePlan.exceedsLimit(before: eight, after: seven))
        XCTAssertTrue(FreePlan.exceedsLimit(before: eight, after: nine))
        // Deleting an event frees a slot only once the account is back under the limit.
        XCTAssertTrue(FreePlan.exceedsLimit(before: seven, after: try data(["A", "B", "C", "D", "E", "F", "G", "X"])))
        XCTAssertFalse(FreePlan.exceedsLimit(before: try data(["A", "B", "C", "D"]), after: try data(["A", "B", "C", "D", "X"])))
    }
}
