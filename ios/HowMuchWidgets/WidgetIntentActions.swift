import Foundation

/// The widget extension only shows intent buttons. iOS runs live-card and Control Center intents in the app,
/// so these are never called here.
enum IntentActions {
    static func finishOnTime(shiftID: UUID, accountID: String) async {}
    static func extend(shiftID: UUID, accountID: String, minutes: Int) async throws {}
    @MainActor static func addJob() {}
}
