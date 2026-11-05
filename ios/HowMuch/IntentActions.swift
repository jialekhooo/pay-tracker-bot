import AppIntents
import ActivityKit
import Foundation
import HowMuchCore
import UserNotifications

/// The app's side of the live-card buttons, Siri and Control Center. iOS may launch HowMuch in the
/// background just to run one of these, so each opens the signed-in account itself when needed.
@MainActor
enum IntentActions {
    /// The signed-in account's records, opening the account first if the app was launched for this intent.
    static func tracker() async -> TrackerStore? {
        let account = AppleAccountStore.shared
        Task { await account.restore() }
        for _ in 0..<150 where account.restoring { try? await Task.sleep(for: .milliseconds(100)) }
        return account.tracker
    }

    static func finishOnTime(shiftID: UUID, accountID: String) async {
        if let store = await tracker(), store.accountID == accountID.lowercased() {
            LiveShiftCenter.confirm(shiftID, in: store)
            await AppleAccountStore.shared.synchronize()
        }
        for activity in Activity<LiveShiftAttributes>.activities where activity.attributes.shiftID == shiftID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    static func extend(shiftID: UUID, accountID: String, minutes: Int) async throws {
        guard let store = await tracker(), store.accountID == accountID.lowercased() else {
            throw TrackerError.invalid("Open HowMuch and sign in to change this shift.")
        }
        guard let shift = store.data.shifts.first(where: { $0.id == shiftID }) else {
            throw TrackerError.invalid("This shift was removed.")
        }
        let longer = try shift.extended(byMinutes: minutes)
        // A finished card can't come back to life, so close it; the update below starts a fresh one if the shift is on again.
        for activity in Activity<LiveShiftAttributes>.activities where activity.attributes.shiftID == shiftID && activity.activityState != .active {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard store.update({ try $0.editShift(original: shift, replacement: longer) }) else {
            throw TrackerError.invalid(store.error ?? "The shift couldn't be saved.")
        }
        LiveShiftCenter.sync(store.data, accountID: store.accountID)
        // Save to the account now: the app may be suspended again as soon as this returns.
        await AppleAccountStore.shared.synchronize()
    }

    static func addJob() {
        PushCenter.shared.addJobRequest = UUID()
    }
}

// MARK: Siri and Shortcuts

struct WeekEarningsIntent: AppIntent {
    static var title: LocalizedStringResource = "Earnings this week"
    static var description = IntentDescription("Tells you your pay this week: what you've worked so far and what's still booked.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> { try await IntentActions.earnings(.week) }
}

struct MonthEarningsIntent: AppIntent {
    static var title: LocalizedStringResource = "Earnings this month"
    static var description = IntentDescription("Tells you your pay this month: what you've worked so far and what's still booked.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> { try await IntentActions.earnings(.month) }
}

extension IntentActions {
    static func earnings(_ period: SpokenSummary.Period) async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let store = await tracker() else { throw TrackerError.invalid("Open HowMuch and sign in first.") }
        let answer = SpokenSummary.earnings(store.data.shifts, period: period)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

struct OwedIntent: AppIntent {
    static var title: LocalizedStringResource = "How much am I owed"
    static var description = IntentDescription("Tells you the pay from finished shifts that isn't marked paid yet, and how much is overdue.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let store = await IntentActions.tracker() else { throw TrackerError.invalid("Open HowMuch and sign in first.") }
        let answer = SpokenSummary.owed(store.data.shifts)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Called by a Shortcuts automation when the bank app posts a notification (iOS 27's notification trigger).
/// The server ignores anything that isn't money received, and only marks shifts paid for a saved payer whose
/// unpaid event total matches exactly; otherwise the payment waits in Pay-in tracking.
struct RecordPayReceivedIntent: AppIntent {
    static var title: LocalizedStringResource = "Record pay received"
    static var description = IntentDescription("Matches money received, from a bank notification or its text, against your unpaid jobs. Payments from saved payers are marked paid or kept for you to check in Pay-in tracking.")
    @Parameter(title: "Notification text", description: "The bank notification's text, e.g. the Notification's Body from the automation.") var text: String
    @Parameter(title: "Amount", description: "Optional. Fill in when a model step has read the amount.") var amount: Double?
    @Parameter(title: "From", description: "Optional. Who sent the money, when a model step has read it.") var payer: String?
    static var parameterSummary: some ParameterSummary { Summary("Record pay received from \(\.$text)") { \.$amount; \.$payer } }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await IntentActions.recordPayReceived(text: text, amount: amount, payer: payer)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

extension IntentActions {
    static func recordPayReceived(text: String, amount: Double?, payer: String?) async throws -> String {
        let account = AppleAccountStore.shared
        guard await tracker() != nil, account.account != nil, !account.isDemo else {
            throw TrackerError.invalid("Open HowMuch and sign in first.")
        }
        var body: [String: Any] = ["text": String(text.prefix(2000)), "payer": String((payer ?? "").prefix(200))]
        if let amount, amount > 0 { body["amount"] = String(format: "%.2f", amount) }
        let data = try await account.api.request("/v1/payment-detection/notification", method: "POST", body: JSONSerialization.data(withJSONObject: body))
        let result = try JSONDecoder().decode(PayInResult.self, from: data)
        guard result.status != "ignored" else { return result.message }
        // Bring the paid flags into the phone's records straight away.
        if result.status == "auto_paid" { await account.synchronize() }
        let content = UNMutableNotificationContent()
        content.title = result.status == "auto_paid" ? "Pay received" : "Pay received · check it"
        content.body = result.message
        content.userInfo = ["kind": "pay_in"]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "howmuch.pay-in.\(UUID().uuidString)", content: content, trigger: nil))
        return result.message
    }
}

private struct PayInResult: Decodable { let status: String; let message: String }

struct HowMuchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WeekEarningsIntent(), phrases: [
            "How much did I earn this week in \(.applicationName)",
            "How much did I make this week in \(.applicationName)",
            "\(.applicationName) earnings this week",
        ], shortTitle: "Earnings this week", systemImageName: "chart.bar.xaxis")
        AppShortcut(intent: MonthEarningsIntent(), phrases: [
            "How much did I earn this month in \(.applicationName)",
            "How much did I make this month in \(.applicationName)",
            "\(.applicationName) earnings this month",
        ], shortTitle: "Earnings this month", systemImageName: "calendar")
        AppShortcut(intent: OwedIntent(), phrases: [
            "How much am I owed in \(.applicationName)",
            "How much is owed to me in \(.applicationName)",
            "\(.applicationName) unpaid pay",
        ], shortTitle: "Owed to me", systemImageName: "hourglass")
        AppShortcut(intent: AddJobIntent(), phrases: [
            "Add a job in \(.applicationName)",
            "Add a shift in \(.applicationName)",
        ], shortTitle: "Add a job", systemImageName: "plus.circle")
    }
}
