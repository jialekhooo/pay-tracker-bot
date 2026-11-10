import XCTest
@testable import HowMuchCore

final class AccountBackupTests: XCTestCase {
    private func sample() throws -> (TrackerData, UUID, Data) {
        var data = TrackerData()
        let shift = try Shift(event: "Gala", day: "2026-12-15", startMinute: 480, endMinute: 600, rate: 15)
        data.shifts = [shift]
        var claim = CabClaim(shiftID: shift.id, day: shift.day, amount: 12, note: "Lunch", category: .food)
        let id = UUID(); claim.receiptID = id; data.claims = [claim]
        return (data, id, Data([0xff, 0xd8, 0, 1, 2, 3, 0xff, 0xd9]))
    }

    func testBackupPreservesRecordsAndExactReceiptBytes() throws {
        let (data, id, photo) = try sample()
        let zip = try AccountBackup(data: data, receipts: [id: photo]).encoded()
        let restored = try AccountBackup.decode(zip)
        XCTAssertEqual(restored.data, data)
        XCTAssertEqual(restored.receipts, [id: photo])
        XCTAssertEqual(zip, try restored.encoded(), "Deterministic archive with no credentials or file paths")
        XCTAssertEqual(try AccountBackup.decode(AccountBackup(data: TrackerData(), receipts: [:]).encoded()).data, TrackerData())
    }

    func testMissingOrUnreferencedReceiptsCannotCreateAFullBackup() throws {
        let (data, id, photo) = try sample()
        XCTAssertThrowsError(try AccountBackup(data: data, receipts: [:]))
        XCTAssertThrowsError(try AccountBackup(data: data, receipts: [UUID(): photo]))
        XCTAssertThrowsError(try AccountBackup(data: data, receipts: [id: Data()]))
    }

    func testPhotoTheAccountNoLongerHasDoesNotBlockABackup() throws {
        let (data, id, _) = try sample()
        let trimmed = AccountBackup.removingReceipts([id], from: data)
        XCTAssertNil(trimmed.claims[0].receiptID)
        XCTAssertEqual(trimmed.claims[0].amount, data.claims[0].amount)
        XCTAssertEqual(AccountBackup.removingReceipts([UUID()], from: data), data)
        XCTAssertEqual(try AccountBackup.decode(AccountBackup(data: trimmed, receipts: [:]).encoded()).data, trimmed)
    }

    func testRestoreRequiresEveryPhotoAndRemapsSharedReferences() throws {
        var (data, id, photo) = try sample()
        var second = data.claims[0]; second.id = UUID(); second.category = .miscellaneous
        data.claims.append(second)
        let backup = try AccountBackup(data: data, receipts: [id: photo])
        XCTAssertThrowsError(try backup.restoringReceipts([:]))
        let fresh = UUID()
        let restored = try backup.restoringReceipts([id: fresh])
        XCTAssertEqual(restored.claims.map(\.receiptID), [fresh, fresh])
        XCTAssertEqual(restored.claims.map(\.id), data.claims.map(\.id))
        XCTAssertEqual(restored.claims.map(\.amount), data.claims.map(\.amount))
        XCTAssertEqual(restored.shifts, data.shifts)
        XCTAssertEqual(backup.data, data, "The source backup is unchanged")
    }

    func testDamagedAndTruncatedArchivesFailWithoutPartialRecords() throws {
        let (data, id, photo) = try sample()
        let zip = try AccountBackup(data: data, receipts: [id: photo]).encoded()
        var damaged = zip
        damaged[45] ^= 1
        XCTAssertThrowsError(try AccountBackup.decode(damaged))
        for size in [0, 4, 21, 45, zip.count - 1] {
            XCTAssertThrowsError(try AccountBackup.decode(Data(zip.prefix(size))))
        }
        damaged = zip; damaged[zip.count - 6] = 255
        XCTAssertThrowsError(try AccountBackup.decode(damaged))
    }

    func testUnexpectedPathsAreRejected() throws {
        let (data, id, photo) = try sample()
        var zip = try AccountBackup(data: data, receipts: [id: photo]).encoded()
        let path = Data("receipts/".utf8)
        while let range = zip.range(of: path) { zip.replaceSubrange(range, with: Data("../evil//".utf8)) }
        XCTAssertThrowsError(try AccountBackup.decode(zip))
    }

    #if os(macOS)
    func testZIPIsReadableBySystemUnzip() throws {
        let (data, id, photo) = try sample()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try AccountBackup(data: data, receipts: [id: photo]).encoded().write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", url.path]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    #endif
}
