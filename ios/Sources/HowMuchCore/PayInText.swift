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

    /// Worth asking a model about: it has a written amount and no one-time-code wording.
    public static func mayBePayment(_ text: String) -> Bool {
        secret.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil && !amounts(in: text).isEmpty
    }

    /// Amounts actually written in a notification, e.g. "SGD 1,200.00" or "88.50".
    public static func amounts(in text: String) -> Set<Decimal> {
        let pattern = #"(?:SGD|S\$|\$)\s?((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?)|((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap { match -> Decimal? in
            for group in 1...2 {
                if let r = Range(match.range(at: group), in: text) { return Decimal(string: text[r].replacingOccurrences(of: ",", with: "")) }
            }
            return nil
        }.filter { $0 > 0 && $0 < 1_000_000 })
    }

    /// A model's suggested amount is only trusted if it's written in the text; otherwise the one amount written, else none.
    public static func confirmedAmount(in text: String, suggested: Decimal?) -> Decimal? {
        let written = amounts(in: text)
        if let suggested, written.contains(suggested) { return suggested }
        return written.count == 1 ? written.first : nil
    }
}
