import XCTest
@testable import HowMuchCore

final class EventDetailsTests: XCTestCase {
    private func sample() throws -> TrackerData {
        var data = TrackerData()
        var usd = PayRules(); usd.currency = "USD"
        data.shifts = [
            try Shift(sourceID: "import-1", event: "Roadshow", location: "Old venue", day: "2026-11-01", startMinute: 540, endMinute: 1080, breakMinutes: 60, rate: 20, paid: true),
            try Shift(event: "ROADSHOW", location: "Other venue", day: "2026-11-02", startMinute: 600, endMinute: 1080, rate: 15, rules: usd),
            try Shift(event: "Other event", location: "Elsewhere", day: "2026-11-03", startMinute: 540, endMinute: 1080, rate: 10)
        ]
        data.claims = [CabClaim(shiftID: data.shifts[0].id, day: "2026-11-01", amount: 12, note: "Taxi")]
        var preferences = AppPreferences(); preferences.payers["roadshow"] = "EXACT COMPANY"; preferences.eventRates["roadshow"] = 20
        data.preferences = preferences
        return data
    }
    func testSharedRenameAndLocationPreserveWorkClaimsAndSettings() throws {
        var data = try sample(); let before = data
        var replacement = data.shifts[0]; replacement.event = "New Roadshow"; replacement.location = "New venue"
        try data.editShift(original: before.shifts[0], replacement: replacement)
        for index in 0...1 {
            var expected = before.shifts[index]; expected.event = "New Roadshow"; expected.location = "New venue"
            XCTAssertEqual(data.shifts[index], expected)
        }
        XCTAssertEqual(data.shifts[2], before.shifts[2]); XCTAssertEqual(data.claims, before.claims)
        XCTAssertNil(data.settings.payers["roadshow"]); XCTAssertEqual(data.settings.payers["new roadshow"], "EXACT COMPANY")
        XCTAssertEqual(data.settings.eventRates["new roadshow"], 20)
        let encoded = try JSONEncoder().encode(data)
        XCTAssertEqual(try JSONDecoder().decode(TrackerData.self, from: encoded), data)
        var restored = try AccountMerge.merge(base: data, local: before, remote: data)
        var expected = before
        restored.shifts.sort { $0.id.uuidString < $1.id.uuidString }
        expected.shifts.sort { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(restored, expected)
    }
    func testSchedulePayStayLocalAndRenameDoesNotFlattenUnchangedLocations() throws {
        var data = try sample(); let before = data
        var rules = PayRules(); rules.currency = data.shifts[0].currency
        let replacement = try Shift(id: data.shifts[0].id, event: "New name", location: data.shifts[0].location, day: "2026-11-04", startMinute: 600, endMinute: 1080, rate: 30, rules: rules)
        try data.editShift(original: before.shifts[0], replacement: replacement)
        XCTAssertEqual(data.shifts[0].pay, 240)
        var expected = before.shifts[1]; expected.event = "New name"
        XCTAssertEqual(data.shifts[1], expected)
        XCTAssertEqual(data.claims, before.claims)
    }
    func testRenameCollisionAndRemovedOrStaleShiftAreAtomic() throws {
        var data = try sample(); let before = data
        XCTAssertThrowsError(try data.updateEventDetails(event: "Roadshow", name: "Other event", location: "Wrong"))
        XCTAssertEqual(data, before)
        XCTAssertThrowsError(try data.updateEventDetails(event: "Roadshow", name: " ", location: nil))
        XCTAssertEqual(data, before)
        let original = data.shifts[0]
        try data.updateEventDetails(event: "Roadshow", name: "Changed elsewhere", location: "Changed venue")
        let current = data
        var edit = original; edit.location = "Stale overwrite"
        XCTAssertThrowsError(try data.editShift(original: original, replacement: edit)); XCTAssertEqual(data, current)
        data.shifts.removeAll { $0.id == original.id }; let removed = data
        XCTAssertThrowsError(try data.editShift(original: original, replacement: original)); XCTAssertEqual(data, removed)
    }
    func testEventEditorCanClearLocationsAndCaseOnlyRename() throws {
        var data = try sample(); let claims = data.claims
        try data.updateEventDetails(event: "Roadshow", name: "roadshow", location: "")
        XCTAssertTrue(data.shifts.prefix(2).allSatisfy { $0.event == "roadshow" && $0.location.isEmpty })
        XCTAssertEqual(data.settings.payers["roadshow"], "EXACT COMPANY"); XCTAssertEqual(data.claims, claims)
    }
}
