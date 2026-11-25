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

    func testOnlyAmountsWrittenInTheAlertAreTrusted() {
        let alert = "PayNow: SGD 88.50 has come in to your account from TAN AH KOW"
        XCTAssertEqual(PayInText.confirmedAmount(in: alert, suggested: 23.46), 88.5) // a made-up number is replaced
        XCTAssertEqual(PayInText.confirmedAmount(in: alert, suggested: 88.5), 88.5)
        XCTAssertEqual(PayInText.confirmedAmount(in: "Received $1,200.00 into a/c 1234, balance $5,000.00", suggested: nil), nil) // two amounts, no guess
        XCTAssertEqual(PayInText.confirmedAmount(in: "Received $1,200.00 into a/c 1234, balance $5,000.00", suggested: 1200), 1200)
        XCTAssertNil(PayInText.confirmedAmount(in: "Money came in", suggested: 50))
    }

    /// A transfer the person made is money out, even though it says "from" and has an amount (a real DBS alert).
    func testTransfersOutAreNeverPay() {
        let out = "DBS digibank\nFr DBS: Successful PayNow: S$11.40 from A/C ending 8370 to KHXX JIX YIXX (MOBILE ending 5128), 25 Nov 14:25 SGT. If unauthorised, call DBS hotline."
        XCTAssertTrue(PayInText.looksLikeMoneyOut(out))
        XCTAssertFalse(PayInText.looksLikeMoneyIn(out))
        XCTAssertFalse(PayInText.mayBePayment(out))  // not even asked of Apple Intelligence
        for text in ["SGD 50.00 was debited from your account", "You have sent SGD 20.00 to JANE TAN",
                     "Transfer to 123-456789-0 of S$300.00 is successful", "You paid $12.00 to GRAB"] {
            XCTAssertTrue(PayInText.looksLikeMoneyOut(text), text)
            XCTAssertFalse(PayInText.mayBePayment(text), text)
        }
    }

    func testMoneyInStaysMoneyIn() {
        for text in ["DBS digibank\nYou have received SGD 1,200.00 from REFIX PTE. LTD.",
                     "You have received SGD 50.00 from JOHN TAN (MOBILE ending 1234) to your A/C ending 8370",
                     "Transfer Received: S$176.00 credited to your account", "PAYNOW FROM JANE TAN $50"] {
            XCTAssertFalse(PayInText.looksLikeMoneyOut(text), text)
            XCTAssertTrue(PayInText.looksLikeMoneyIn(text), text)
        }
        // Wording the rules don't know still goes to Apple Intelligence, and isn't mistaken for money out.
        let unusual = "Funds transfer to your a/c 1234: SGD 80.00 from ACME PTE LTD"
        XCTAssertFalse(PayInText.looksLikeMoneyOut(unusual))
        XCTAssertTrue(PayInText.mayBePayment(unusual))
    }
}
