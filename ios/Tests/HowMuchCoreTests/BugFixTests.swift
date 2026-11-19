import XCTest
@testable import HowMuchCore

/// Regressions found in the November 2026 bug sweep.
final class BugFixTests: XCTestCase {
    func testAFreeDayAfterAnEarlyBumpInOrOvernightShiftIsPartlyFree() throws {
        let bumpIn = try Shift(event: "Bump-in", day: "2026-12-15", startMinute: 300, endMinute: 480, rate: 15)
        let gala = try Shift(event: "Gala", day: "2026-12-15", startMinute: 1080, endMinute: 1380, rate: 15)
        XCTAssertEqual(Availability.day("2026-12-15", shifts: [bumpIn, gala], blocked: []), .partly("from 8am to 6pm"))
        let overnight = try Shift(event: "Night", day: "2026-12-14", startMinute: 1320, endMinute: 120, rate: 15)
        XCTAssertEqual(Availability.day("2026-12-15", shifts: [overnight, gala], blocked: []), .partly("from 8am to 6pm"))
    }

    func testCSVKeepsTheExtraSeparateSoReimportingIsNotADuplicate() throws {
        var shift = try Shift(sourceID: "7", event: "Roadshow", day: "2026-11-03", startMinute: 540, endMinute: 1080, rate: 20)
        shift.extra = 10; shift.extraNote = "Transport"
        let csv = ShiftCSV.encode([shift])
        XCTAssertTrue(csv.contains("\"\(shift.total)\""), "Pay column is the full amount for spreadsheets")
        let back = try XCTUnwrap(try ShiftCSV.decode(csv).first)
        XCTAssertEqual(back.pay, shift.pay)
        XCTAssertEqual(back.extra, 10)
        XCTAssertEqual(back.extraNote, "Transport")
        XCTAssertEqual(back.total, shift.total)
        var data = TrackerData(); data.shifts = [shift]
        XCTAssertEqual(data.importShifts([back]), 0)
    }

    func testSettingsChangedOnTwoDevicesMergeWhenTheSyncedCopyHadNone() throws {
        let base = TrackerData()
        XCTAssertNil(base.preferences)
        var local = base; var mine = AppPreferences(); mine.displayName = "Jia"; local.preferences = mine
        var remote = base; var theirs = AppPreferences(); theirs.remindersEnabled = true; remote.preferences = theirs
        let merged = try AccountMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.preferences?.displayName, "Jia")
        XCTAssertEqual(merged.preferences?.remindersEnabled, true)
    }

    func testPurchasesAtTheSamePriceOnTwoDevicesBothCostCoins() throws {
        var start = AppPreferences(); start.pet = PetPreferences(closet: PetCloset())
        var base = TrackerData(); base.preferences = start
        func buying(_ item: String) -> TrackerData {
            var data = base; var closet = PetCloset(); closet.bought = [item]; closet.spent = 40
            data.preferences?.pet?.closet = closet
            return data
        }
        let merged = try AccountMerge.merge(base: base, local: buying("party-hat"), remote: buying("bow-tie"))
        let closet = try XCTUnwrap(merged.preferences?.pet?.closet)
        XCTAssertEqual(closet.bought, ["party-hat", "bow-tie"])
        XCTAssertEqual(closet.spent, 80)
        // One device buying while the other only changes the outfit still counts the price once.
        var dressed = base; dressed.preferences?.pet?.closet?.outfit["hat"] = "cap"
        let once = try AccountMerge.merge(base: base, local: buying("party-hat"), remote: dressed)
        XCTAssertEqual(once.preferences?.pet?.closet?.spent, 40)
    }

    func testAPayLabelLeftOnAOneLinePostIsNotTheEventName() {
        for text in ["22/11 9am-6pm, Rate $12/hr", "Sat 22 Nov 10am-6pm pay $100/day", "Fri, 28/11/26 1pm-10pm. Pay $12.50 / hr"] {
            let event = JobMessageParser.parse(text).event ?? ""
            XCTAssertFalse(["rate", "pay"].contains(event.lowercased()), "\(text) → \(event)")
        }
    }
}
