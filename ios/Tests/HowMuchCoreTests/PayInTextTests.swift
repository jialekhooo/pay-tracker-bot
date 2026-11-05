import XCTest
@testable import HowMuchCore

final class PayInTextTests: XCTestCase {
    func testMoneyInAlertsAreSentWhateverTheirCase() {
        XCTAssertTrue(PayInText.looksLikeMoneyIn("DBS digibank\nYou have received SGD 1,200.00 from REFIX PTE. LTD."))
        XCTAssertTrue(PayInText.looksLikeMoneyIn("Transfer Received: S$176.00 credited to your account"))
        XCTAssertTrue(PayInText.looksLikeMoneyIn("PAYNOW FROM JANE TAN $50"))
    }

    func testCodesSpendingAndPromotionsStayOnThePhone() {
        XCTAssertFalse(PayInText.looksLikeMoneyIn("Your OTP is 123456. Do not share it. Received a request to log in."))
        XCTAssertFalse(PayInText.looksLikeMoneyIn("You spent SGD 12.50 at GRAB on your card"))
        XCTAssertFalse(PayInText.looksLikeMoneyIn("We received your application. We'll be in touch."))
        XCTAssertFalse(PayInText.looksLikeMoneyIn("Enjoy 5% cashback this weekend!"))
    }
}
