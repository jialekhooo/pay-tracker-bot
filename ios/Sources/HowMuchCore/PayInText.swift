import Foundation

/// Decides on the iPhone whether a bank notification is money coming in, before anything is sent.
/// Codes, card spending and promotions stay on the phone. Mirrors the server's `parse_notification`.
public enum PayInText {
    private static let moneyIn = try! NSRegularExpression(pattern: #"\b(received|incoming|credited|paynow from|transfer from|deposit)\b"#, options: [.caseInsensitive])
    private static let amount = try! NSRegularExpression(pattern: #"(?:SGD|S\$|\$)\s?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?"#, options: [.caseInsensitive])
    private static let secret = try! NSRegularExpression(pattern: #"\b(OTP|one[- ]time|passcode|verification code|do not share)\b"#, options: [.caseInsensitive])

    public static func looksLikeMoneyIn(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return moneyIn.firstMatch(in: text, range: range) != nil
            && amount.firstMatch(in: text, range: range) != nil
            && secret.firstMatch(in: text, range: range) == nil
    }
}
