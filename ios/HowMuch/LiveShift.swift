import SwiftUI
import ActivityKit
import HowMuchCore

/// Starts, updates and ends the Lock Screen card for the shift in progress.
/// iOS only lets an app start a Live Activity while it is open, so this runs whenever
/// HowMuch is opened or its data changes (including from a job notification tap).
@MainActor
enum LiveShiftCenter {
    /// Where 1.1 and earlier kept these choices on the phone; moved into the account on first open.
    static let lockScreenKey = "liveShift.lockScreen"
    static let askFinishKey = "liveShift.askFinish"
    static func legacyConfirmedKey(_ accountID: String) -> String { "liveShift.confirmed.\(accountID)" }
    /// The signed-in account's live shift choices (synced), as of the last time its records were seen.
    private static var preferences = LiveShiftPreferences()
    static var lockScreenEnabled: Bool { !automatedTest && preferences.showsOnLockScreen }
    static var askFinishEnabled: Bool { !automatedTest && preferences.asksFinishTime }
    /// UI tests use sample shifts that end around launch; a finish question would cover the screens they check.
    private static var automatedTest: Bool {
        #if DEBUG
        let arguments = CommandLine.arguments
        return (arguments.contains("--preview") || arguments.contains("--ui-test-account")) && !arguments.contains("--ui-test-live-shift")
        #else
        return false
        #endif
    }
    static var systemAllows: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Shifts whose Lock Screen card the person swiped away (kept until the app restarts).
    static var dismissedShifts: Set<UUID> = []
    static func sync(_ data: TrackerData, accountID: String, now: Date = Date()) {
        preferences = data.settings.liveShift ?? LiveShiftPreferences()
        let details = data.settings.jobNotifications.showDetails
        let activities = Activity<LiveShiftAttributes>.activities
        activities.forEach(watch)
        // Keep only the newest card per shift (the server may have renewed one the app started).
        var newest: [UUID: Activity<LiveShiftAttributes>] = [:]
        for activity in activities where activity.activityState == .active {
            let id = activity.attributes.shiftID
            if let kept = newest[id], firstSeen[kept.id, default: .distantPast] >= firstSeen[activity.id, default: .distantPast] {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            } else {
                if let kept = newest[id] { Task { await kept.end(nil, dismissalPolicy: .immediate) } }
                newest[id] = activity
            }
        }
        for activity in activities {
            guard lockScreenEnabled, activity.attributes.accountID == accountID,
                  let shift = data.shifts.first(where: { $0.id == activity.attributes.shiftID }) else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                continue
            }
            let content = ActivityContent(state: state(for: shift, accountID: accountID, details: details), staleDate: shift.endDate)
            if now >= shift.endDate {
                // Leave the finished card up for a while so its tap can confirm the finish time.
                if activity.activityState == .active {
                    Task { await activity.end(content, dismissalPolicy: .after(shift.endDate.addingTimeInterval(4 * 60 * 60))) }
                }
            } else if activity.content.state != content.state {
                Task { await activity.update(content) }
            }
        }
        guard lockScreenEnabled, systemAllows, let current = LiveShiftPlanner.current(in: data.shifts, at: now),
              !activities.contains(where: { $0.attributes.shiftID == current.id && $0.attributes.accountID == accountID && $0.activityState == .active }),
              // Swiped away by the person: don't bring this shift's card back every minute.
              !dismissedShifts.contains(current.id),
              !activities.contains(where: { $0.attributes.shiftID == current.id && $0.activityState == .dismissed })
        else { return }
        let content = ActivityContent(state: state(for: current, accountID: accountID, details: details), staleDate: current.endDate)
        if let activity = try? Activity.request(attributes: LiveShiftAttributes(shiftID: current.id, accountID: accountID), content: content, pushType: .token) {
            watch(activity)
        }
    }

    // MARK: Server push tokens
    // The server starts the card at shift time without the app being opened (iOS 17.2+), and renews it
    // before iOS's 8-hour limit. It needs this phone's push-to-start token and each running card's token.

    enum Token { case start(String), activity(shift: UUID, token: String), noStart }
    private static var reporter: ((Token) async -> Void)?
    private static var startToken: String?
    private static var cardTokens: [String: (shift: UUID, token: String)] = [:]
    private static var watching = Set<String>()
    private static var firstSeen: [String: Date] = [:]
    private static var observing = false

    /// Called once at launch, including when iOS launches the app in the background for a server-started card.
    static func observeTokens() {
        guard !observing else { return }
        observing = true
        if #available(iOS 17.2, *) {
            Task { @MainActor in
                for await data in Activity<LiveShiftAttributes>.pushToStartTokenUpdates {
                    startToken = hex(data); await reportStart()
                }
            }
        }
        Task { @MainActor in
            for await activity in Activity<LiveShiftAttributes>.activityUpdates { watch(activity) }
        }
        for activity in Activity<LiveShiftAttributes>.activities { watch(activity) }
    }

    private static func watch(_ activity: Activity<LiveShiftAttributes>) {
        guard watching.insert(activity.id).inserted else { return }
        firstSeen[activity.id] = Date()
        Task { @MainActor in
            for await state in activity.activityStateUpdates where state == .dismissed {
                dismissedShifts.insert(activity.attributes.shiftID)
            }
        }
        Task { @MainActor in
            for await data in activity.pushTokenUpdates {
                let token = hex(data)
                cardTokens[activity.id] = (activity.attributes.shiftID, token)
                await reporter?(.activity(shift: activity.attributes.shiftID, token: token))
            }
        }
    }

    /// The signed-in account's way of sending tokens to the server; nil while signed out.
    static func connect(_ send: ((Token) async -> Void)?) {
        reporter = send
        guard send != nil else { return }
        Task { @MainActor in
            await reportStart()
            for card in cardTokens.values { await reporter?(.activity(shift: card.shift, token: card.token)) }
        }
    }

    /// Re-sends (or withdraws) the push-to-start token, e.g. after the Lock Screen setting changes.
    static func reportStart() async {
        guard let reporter else { return }
        if lockScreenEnabled, let startToken { await reporter(.start(startToken)) } else { await reporter(.noStart) }
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func endAll() {
        for activity in Activity<LiveShiftAttributes>.activities { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
    }

    private static func state(for shift: Shift, accountID: String, details: Bool) -> LiveShiftAttributes.ContentState {
        // Names on the Lock Screen follow the job-notification privacy choice, as the server does.
        LiveShiftAttributes.ContentState(
            event: details ? shift.event : "Shift in progress",
            location: details ? (shift.location.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") : "",
            startTime: shift.startDate.timeIntervalSince1970, endTime: shift.endDate.timeIntervalSince1970,
            pay: NSDecimalNumber(decimal: shift.pay).doubleValue, currency: shift.currency,
            shiftURL: WidgetLink.shift(shift.id).url(accountID: accountID),
            finishURL: WidgetLink.finish(shift.id).url(accountID: accountID))
    }

    // MARK: Finish-time questions

    /// Records the confirmation in the account, so other iPhones don't ask again.
    @discardableResult
    static func confirm(_ id: UUID, in store: TrackerStore) -> Bool {
        store.updatePreferences { settings in
            var live = settings.liveShift ?? LiveShiftPreferences()
            live.confirm(id)
            settings.liveShift = live
        }
    }
    /// The next ended hourly shift whose actual finishing time hasn't been confirmed.
    /// Shifts whose finish-time question was put off with "Later" (or swiped away), and until when.
    static var postponed: [UUID: Date] = [:]
    static func postpone(_ id: UUID, hours: Double = 3) { postponed[id] = Date().addingTimeInterval(hours * 3600) }

    static func nextToConfirm(_ data: TrackerData, accountID: String, now: Date = Date()) -> Shift? {
        preferences = data.settings.liveShift ?? LiveShiftPreferences()
        guard askFinishEnabled else { return nil }
        return LiveShiftPlanner.awaitingFinish(in: data.shifts, confirmed: preferences.confirmed, at: now)
            .first { (postponed[$0.id] ?? .distantPast) <= now }
    }
}

/// Asks what time the person actually finished, and recalculates pay (including overtime).
struct FinishShiftSheet: View {
    let shift: Shift
    @EnvironmentObject private var store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    @State private var finish: Date
    @State private var error: String?

    init(shift: Shift) {
        self.shift = shift
        _finish = State(initialValue: shift.endDate)
    }
    private var latest: Shift { store.data.shifts.first { $0.id == shift.id } ?? shift }
    private var updated: Shift? {
        guard let minute = try? LiveShiftPlanner.endMinute(for: finish, of: latest) else { return nil }
        return try? latest.finishing(atMinute: minute)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Card {
                        Label("HOW DID IT GO?", systemImage: "clock.badge.checkmark").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.muted)
                        Text(latest.event).font(.system(.title2, design: .rounded, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text("Booked \(latest.startDate.formatted(date: .abbreviated, time: .shortened)) to \(latest.endDate.formatted(date: .omitted, time: .shortened)) · \(money(latest.pay, latest.currency))")
                            .font(.subheadline).foregroundStyle(Palette.muted)
                    }
                    Card {
                        Label("WHEN DID YOU FINISH?", systemImage: "flag.checkered").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.muted)
                        DatePicker("Finished at", selection: $finish,
                                   in: latest.startDate.addingTimeInterval(60)...latest.startDate.addingTimeInterval(24 * 60 * 60 - 60),
                                   displayedComponents: [.date, .hourAndMinute])
                            .frame(minHeight: 44).accessibilityIdentifier("finish.time")
                        if let updated {
                            Divider()
                            Text(money(updated.pay, updated.currency)).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                                .accessibilityIdentifier("finish.pay")
                            Text(change(from: latest, to: updated)).font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                    Button("I finished on time", systemImage: "checkmark") { finishOnTime() }
                        .glassAction().accessibilityIdentifier("finish.onTime")
                    if let error { Label(error, systemImage: "exclamationmark.circle.fill").font(.subheadline).foregroundStyle(.red) }
                }.padding(20)
            }
            .detailStyle("Confirm finish time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.semibold).accessibilityIdentifier("finish.save") }
            }
        }
    }

    private func change(from old: Shift, to new: Shift) -> String {
        let minutes = new.durationMinutes - old.durationMinutes
        if minutes == 0 { return "Same as booked." }
        let length = Duration.seconds(abs(minutes) * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        let difference = money(abs(new.pay - old.pay), new.currency)
        return minutes > 0 ? "\(length) longer than booked: \(difference) more, overtime included."
                           : "\(length) shorter than booked: \(difference) less."
    }
    private func finishOnTime() {
        LiveShiftCenter.confirm(shift.id, in: store); dismiss()
    }
    private func save() {
        do {
            let minute = try LiveShiftPlanner.endMinute(for: finish, of: latest)
            if minute != latest.endMinute {
                let replacement = try latest.finishing(atMinute: minute)
                guard store.update({ try $0.editShift(original: latest, replacement: replacement) }) else { error = store.error; return }
            }
            finishOnTime()
        } catch { self.error = error.localizedDescription }
    }
}

struct LiveShiftSettingsView: View {
    @EnvironmentObject private var store: TrackerStore
    private var live: LiveShiftPreferences { store.data.settings.liveShift ?? LiveShiftPreferences() }
    private var lockScreen: Binding<Bool> {
        Binding(get: { live.showsOnLockScreen }, set: { value in
            store.updatePreferences { var live = $0.liveShift ?? LiveShiftPreferences(); live.lockScreen = value; $0.liveShift = live }
            LiveShiftCenter.sync(store.data, accountID: store.accountID)
            Task { await LiveShiftCenter.reportStart() }
        })
    }
    private var askFinish: Binding<Bool> {
        Binding(get: { live.asksFinishTime }, set: { value in
            store.updatePreferences { var live = $0.liveShift ?? LiveShiftPreferences(); live.askFinish = value; $0.liveShift = live }
        })
    }
    var body: some View {
        Form {
            Section {
                Toggle("Show on Lock Screen", isOn: lockScreen).accessibilityIdentifier("live.lockScreen")
                Text("While a shift is on, the Lock Screen and Dynamic Island show the time left and your pay for the shift. It appears on its own when the shift starts, even if HowMuch is closed, and stays live through long shifts. Tap +30 min if you're staying late, or Finished on time once it ends. Job names follow your Job notifications privacy setting.")
                    .font(.caption).foregroundStyle(Palette.muted)
                if !LiveShiftCenter.systemAllows {
                    Text("Live Activities are turned off for HowMuch in iPhone Settings.").font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("Lock Screen") }
            Section {
                Toggle("Ask what time I finished", isOn: askFinish).accessibilityIdentifier("live.askFinish")
                Text("After an hourly shift ends, HowMuch asks once whether you finished on time. Staying late updates that shift's pay, including overtime.")
                    .font(.caption).foregroundStyle(Palette.muted)
            } header: { Text("Finish time") }
        }
        .detailStyle("Live shift")
    }
}
