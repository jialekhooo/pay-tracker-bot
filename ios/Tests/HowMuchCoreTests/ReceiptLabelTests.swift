import XCTest
@testable import HowMuchCore

final class ReceiptLabelTests: XCTestCase {
    func testRideAppTotalsUseWhatWasPaidNotTheFare() {
        let grab = "Grab\nWed, 5 Nov 2026 18:42\nFare S$ 18.40\nPlatform fee 0.90\nYou paid S$19.30\nPaid by Mastercard 1234"
        XCTAssertEqual(ReceiptSuggestions(text: grab).amount, Decimal(string: "19.30"))
    }

    func testNETSAndPlainAmountLabelsAreTotals() {
        let food = "TOAST BOX\n05/11/26 12:31\nKaya Toast Set  5.80\nSUBTOTAL 8.40\nGST 9% 0.76\nNETS 9.16"
        XCTAssertEqual(ReceiptSuggestions(text: food).amount, Decimal(string: "9.16"))
        let shop = "POPULAR BOOKSTORE\n4 Nov 2026\nA4 paper x2  11.80\nMarkers  6.50\nAmount 18.30"
        XCTAssertEqual(ReceiptSuggestions(text: shop).amount, Decimal(string: "18.30"))
    }
}
