import AppIntents
import Foundation

// Intents shared by the app and the widget extension. The widget extension shows their buttons
// (live shift card, Control Center), but their work always runs in the app through `IntentActions`,
// which each target defines: the app does the work, the extension's copy is never called.

/// "Finished on time" on the live shift card: confirms the booked finish time and closes the card.
struct FinishShiftOnTimeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Finished on time"
    static var description = IntentDescription("Confirms you finished a shift at its booked time.")
    static var isDiscoverable = false
    /// The account's files are encrypted while the iPhone is locked, so ask for Face ID first.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Shift") var shiftID: String
    @Parameter(title: "Account") var accountID: String
    init() {}
    init(shiftID: UUID, accountID: String) { self.shiftID = shiftID.uuidString; self.accountID = accountID }
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: shiftID) { await IntentActions.finishOnTime(shiftID: id, accountID: accountID) }
        return .result()
    }
}

/// "Staying late" on the live shift card once the booked end arrives: the card starts counting overtime.
/// Nothing is saved to the shift yet, so it works from the Lock Screen without unlocking.
struct StayingLateIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Staying late"
    static var description = IntentDescription("Starts counting overtime on a shift's live card.")
    static var isDiscoverable = false
    @Parameter(title: "Shift") var shiftID: String
    @Parameter(title: "Account") var accountID: String
    init() {}
    init(shiftID: UUID, accountID: String) { self.shiftID = shiftID.uuidString; self.accountID = accountID }
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: shiftID) { await IntentActions.stayLate(shiftID: id) }
        return .result()
    }
}

/// "Finished now" while counting overtime: the shift ends at this minute, with pay and overtime recalculated.
struct FinishShiftNowIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Finished now"
    static var description = IntentDescription("Records that a shift finished now, with pay and overtime recalculated.")
    static var isDiscoverable = false
    // Shift records are only readable once the iPhone is unlocked.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Shift") var shiftID: String
    @Parameter(title: "Account") var accountID: String
    init() {}
    init(shiftID: UUID, accountID: String) { self.shiftID = shiftID.uuidString; self.accountID = accountID }
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: shiftID) { try await IntentActions.finishNow(shiftID: id, accountID: accountID, at: Date()) }
        return .result()
    }
}

/// Opens Add shift, filled in from a copied job message when there is one. Used by Siri and Control Center.
struct AddJobIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a job"
    static var description = IntentDescription("Opens Add shift in HowMuch. A copied job message fills in the dates, times and pay for you to check.")
    static var openAppWhenRun = true
    init() {}
    @MainActor
    func perform() async throws -> some IntentResult {
        IntentActions.addJob()
        return .result()
    }
}
