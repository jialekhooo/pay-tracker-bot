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

/// "+30 min" on the live shift card: moves the shift's finish 30 minutes later and recalculates its pay.
struct ExtendShiftIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Add 30 minutes"
    static var description = IntentDescription("Moves a shift's finish time 30 minutes later, with pay and overtime recalculated.")
    static var isDiscoverable = false
    // Shift records are only readable once the iPhone is unlocked.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Shift") var shiftID: String
    @Parameter(title: "Account") var accountID: String
    init() {}
    init(shiftID: UUID, accountID: String) { self.shiftID = shiftID.uuidString; self.accountID = accountID }
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: shiftID) { try await IntentActions.extend(shiftID: id, accountID: accountID, minutes: 30) }
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
