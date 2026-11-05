import AppIntents
import ActivityKit
import Foundation
import HowMuchCore

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
        LiveShiftCenter.confirm(shiftID, accountID: accountID)
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
