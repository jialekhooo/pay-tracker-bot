import XCTest
@testable import HowMuchCore

final class SavedPayerTests: XCTestCase {
    func testLegacyPayersMigrateOnceAndShareCompanyAcrossEvents() throws {
        var preferences = AppPreferences(); preferences.payers = ["event one": "REFIX PTE. LTD.", "event two": "refix pte. ltd."]
        let migrated = preferences.migratedPayers
        XCTAssertEqual(migrated.savedPayers?.count, 1)
        XCTAssertEqual(migrated.payer(for: "Event one")?.id, migrated.payer(for: "Event two")?.id)
        XCTAssertEqual(migrated, migrated.migratedPayers)
        try migrated.validate()
    }
    func testEditingCompanyUpdatesAllAssignmentsAndUnlinkDoesNotRemigrate() throws {
        var p = AppPreferences(); p.payers = ["a":"OLD BANK", "b":"OLD BANK"]; p = p.migratedPayers
        var payer = try XCTUnwrap(p.savedPayers?.first); payer.name = "Friendly company"; payer.bankNames = ["NEW BANK", "SECOND BANK"]
        p.savePayer(payer)
        XCTAssertEqual(p.payer(for:"a")?.bankNames, ["NEW BANK","SECOND BANK"])
        XCTAssertEqual(p.payers["b"], "NEW BANK")
        p.assignPayer(nil, to:"a")
        XCTAssertNil(p.migratedPayers.payer(for:"a")); XCTAssertNotNil(p.payer(for:"b"))
        try p.validate()
    }
    func testRenameMovesPayerAndRemovingCompanyClearsTemplates() throws {
        var data = TrackerData(); data.shifts = [try Shift(event:"Original",day:"2026-11-10",startMinute:540,endMinute:600,rate:15)]
        var settings = data.settings; let payer = SavedPayer(name:"Company",bankNames:["BANK LTD"]); settings.savePayer(payer); settings.assignPayer(payer.id,to:"Original")
        settings.jobTemplates = [JobTemplate(name:"Usual job",shift:data.shifts[0],payerID:payer.id)]; data.preferences = settings
        try data.updateEventDetails(event:"Original",name:"Renamed",location:nil)
        XCTAssertEqual(data.settings.payer(for:"Renamed")?.id,payer.id); XCTAssertNil(data.settings.payer(for:"Original"))
        settings = data.settings; settings.removePayer(payer.id)
        XCTAssertNil(settings.payer(for:"Renamed")); XCTAssertNil(settings.jobTemplates?.first?.payerID)
        try settings.validate()
    }
    func testDuplicateBankAliasesCannotBelongToDifferentCompanies() {
        var p = AppPreferences(); p.savedPayers = [SavedPayer(name:"A",bankNames:["BANK LTD"]),SavedPayer(name:"B",bankNames:[" bank  ltd "])]
        XCTAssertThrowsError(try p.validate())
    }
}
