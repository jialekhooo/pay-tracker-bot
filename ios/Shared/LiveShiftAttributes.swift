import Foundation
import ActivityKit

/// The Lock Screen / Dynamic Island card for a shift in progress. Shared by the app and the widget extension.
struct LiveShiftAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var event: String
        var location: String
        /// Unix timestamps, so the server's push-to-start payload and the app encode them the same way.
        var startTime: Double
        var endTime: Double
        /// Pay for the booked hours, in the shift's currency.
        var pay: Double
        var currency: String
        /// The app link that opens this shift (or its finish-time question once it has ended).
        var shiftURL: URL
        var finishURL: URL
    }
    var shiftID: UUID
    var accountID: String
}

extension LiveShiftAttributes.ContentState {
    var start: Date { Date(timeIntervalSince1970: startTime) }
    var end: Date { Date(timeIntervalSince1970: endTime) }
    /// Matches the app's "SGD 72" style rather than a locale's bare "$".
    var payText: String { currency + " " + pay.formatted(.number.precision(.fractionLength(pay.rounded() == pay ? 0 : 2))) }
}
