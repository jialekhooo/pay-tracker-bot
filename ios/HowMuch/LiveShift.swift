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
    /// The Lock Screen shift card is part of HowMuch Pro.
    static var lockScreenEnabled: Bool { !automatedTest && preferences.showsOnLockScreen && ProStore.shared.hasPro }
    static var askFinishEnabled: Bool { !automatedTest && preferences.asksFinishTime }
    /// UI tests use sample shifts that end around launch; a finish question would cover the screens they check.
    private static var automatedTest: Bool {
        #if DEBUG
        let arguments = CommandLine.arguments
        return (arguments.contains("--preview") || arguments.contains("--ui-test-account")) && !arguments.contains("--ui-test-live-shift") && !arguments.contains("--ui-test-upcoming-shift") && !arguments.contains("--ui-test-ending-shift")
        #else
        return false
        #endif
    }
    static var systemAllows: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Shifts whose Lock Screen card the person swiped away (kept until the app restarts).
    static var dismissedShifts: Set<UUID> = []
    /// Cards the app ended itself: an immediate end also reports `.dismissed`, which must not count as a swipe.
    private static var endedByApp: Set<String> = []
    /// Showing and updatable. A card past its stale date (the shift's start while counting down to it, its end
    /// after that) is "stale" rather than "active", but it is still the same live card.
    static func isLive(_ activity: Activity<LiveShiftAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }
    static func close(_ activity: Activity<LiveShiftAttributes>) async {
        endedByApp.insert(activity.id)
        await activity.end(nil, dismissalPolicy: .immediate)
    }
    static func sync(_ data: TrackerData, accountID: String, now: Date = Date()) {
        preferences = data.settings.liveShift ?? LiveShiftPreferences()
        let details = data.settings.jobNotifications.showDetails
        let activities = Activity<LiveShiftAttributes>.activities
        activities.forEach(watch)
        // Keep only the newest card per shift (the server may have renewed one the app started).
        var newest: [UUID: Activity<LiveShiftAttributes>] = [:]
        for activity in activities where isLive(activity) {
            let id = activity.attributes.shiftID
            if let kept = newest[id], firstSeen[kept.id, default: .distantPast] >= firstSeen[activity.id, default: .distantPast] {
                Task { await close(activity) }
            } else {
                if let kept = newest[id] { Task { await close(kept) } }
                newest[id] = activity
            }
        }
        for activity in activities {
            guard lockScreenEnabled, activity.attributes.accountID == accountID,
                  let shift = data.shifts.first(where: { $0.id == activity.attributes.shiftID }) else {
                Task { await close(activity) }
                continue
            }
            let content = ActivityContent(state: state(for: shift, accountID: accountID, details: details), staleDate: staleDate(for: shift, now: now))
            if now >= shift.endDate {
                // Past the booked end the card asks "Finished?", or counts overtime after "Staying late". It stays
                // up (in the Dynamic Island too) until answered, or for a few hours (half a day while counting).
                let confirmed = preferences.confirmed.contains(shift.id)
                let limit: TimeInterval = isStayingLate(shift.id) ? 12 * 60 * 60 : 4 * 60 * 60
                if confirmed || now >= shift.endDate.addingTimeInterval(limit) {
                    if confirmed { clearOvertime(shift.id) }
                    Task { await close(activity) }
                } else if isLive(activity) && activity.content.state != content.state {
                    Task { await activity.update(content) }
                }
            } else if activity.content.state != content.state || activity.content.staleDate != content.staleDate {
                // A change to the shift, or its start passing: the card moves from "starts at" to time left.
                Task { await activity.update(content) }
            }
        }
        guard lockScreenEnabled, systemAllows, let current = LiveShiftPlanner.current(in: data.shifts, at: now),
              !activities.contains(where: { $0.attributes.shiftID == current.id && $0.attributes.accountID == accountID && isLive($0) }),
              // Swiped away by the person: don't bring this shift's card back every minute.
              !dismissedShifts.contains(current.id),
              !activities.contains(where: { $0.attributes.shiftID == current.id && $0.activityState == .dismissed && !endedByApp.contains($0.id) })
        else { return }
        let content = ActivityContent(state: state(for: current, accountID: accountID, details: details), staleDate: staleDate(for: current, now: now))
        if let activity = try? Activity.request(attributes: LiveShiftAttributes(shiftID: current.id, accountID: accountID), content: content, pushType: .token) {
            watch(activity)
        }
    }

    /// iOS redraws a card at its stale date: at the start while it counts down to the shift, then at the end
    /// (the card shows "Shift over" once it is stale and past the end).
    private static func staleDate(for shift: Shift, now: Date) -> Date { now < shift.startDate ? shift.startDate : shift.endDate }

    // MARK: Server push tokens
    // The server starts the card at shift time without the app being opened (iOS 17.2+), and renews it
    // before iOS's 8-hour limit. It needs this phone's push-to-start token and each running card's token.

    /// `card` is the Live Activity's own id, so the server can tell a new token for the same card from a new card.
    enum Token { case start(String), activity(shift: UUID, token: String, card: String), noStart }
    private static var reporter: ((Token) async -> Void)?
    private static var startToken: String?
    private static var cardTokens: [String: (shift: UUID, token: String)] = [:]  // keyed by the card's id
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
                if !endedByApp.contains(activity.id) { dismissedShifts.insert(activity.attributes.shiftID) }
            }
        }
        Task { @MainActor in
            for await data in activity.pushTokenUpdates {
                let token = hex(data)
                cardTokens[activity.id] = (activity.attributes.shiftID, token)
                await reporter?(.activity(shift: activity.attributes.shiftID, token: token, card: activity.id))
            }
        }
    }

    /// The signed-in account's way of sending tokens to the server; nil while signed out.
    static func connect(_ send: ((Token) async -> Void)?) {
        reporter = send
        guard send != nil else { return }
        Task { @MainActor in
            await reportStart()
            for (id, card) in cardTokens { await reporter?(.activity(shift: card.shift, token: card.token, card: id)) }
        }
    }

    /// Re-sends the push-to-start token, or withdraws it when the Lock Screen setting is off.
    /// Until iOS hands the token over (it can take a moment, and may not happen at all when iOS wakes the app
    /// in the background), say nothing: withdrawing then would leave the server unable to start the next card.
    static func reportStart() async {
        guard let reporter else { return }
        if !lockScreenEnabled { await reporter(.noStart) } else if let startToken { await reporter(.start(startToken)) }
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func endAll() {
        for activity in Activity<LiveShiftAttributes>.activities { Task { await close(activity) } }
    }

    private static func state(for shift: Shift, accountID: String, details: Bool) -> LiveShiftAttributes.ContentState {
        // Names on the Lock Screen follow the job-notification privacy choice, as the server does.
        LiveShiftAttributes.ContentState(
            event: details ? shift.event : "Your shift",
            location: details ? (shift.location.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") : "",
            startTime: shift.startDate.timeIntervalSince1970, endTime: shift.endDate.timeIntervalSince1970,
            pay: NSDecimalNumber(decimal: shift.total).doubleValue, currency: shift.currency,
            shiftURL: WidgetLink.shift(shift.id).url(accountID: accountID),
            finishURL: WidgetLink.finish(shift.id).url(accountID: accountID),
            overtime: isStayingLate(shift.id) ? true : nil)
    }

    // MARK: Staying late

    /// Shifts where the person tapped "Staying late", and when. Kept on this iPhone: it only shapes its card.
    private static let overtimeKey = "liveShift.stayingLate"
    static func isStayingLate(_ id: UUID) -> Bool {
        (UserDefaults.standard.dictionary(forKey: overtimeKey) as? [String: Double])?[id.uuidString] != nil
    }
    static func startOvertime(_ id: UUID) {
        var started = UserDefaults.standard.dictionary(forKey: overtimeKey) as? [String: Double] ?? [:]
        started[id.uuidString] = started[id.uuidString] ?? Date().timeIntervalSince1970
        // Forget anything older than two days, so the list never grows.
        started = started.filter { Date().timeIntervalSince1970 - $0.value < 2 * 86400 }
        UserDefaults.standard.set(started, forKey: overtimeKey)
    }
    static func clearOvertime(_ id: UUID) {
        var started = UserDefaults.standard.dictionary(forKey: overtimeKey) as? [String: Double] ?? [:]
        started[id.uuidString] = nil
        UserDefaults.standard.set(started, forKey: overtimeKey)
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
        // After "Staying late" on the card, the likely finish is now rather than the booked end.
        let stayed = LiveShiftCenter.isStayingLate(shift.id) && Date() > shift.endDate
        _finish = State(initialValue: stayed ? Date() : shift.endDate)
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
                        Text("Booked \(latest.startDate.formatted(date: .abbreviated, time: .shortened)) to \(latest.endDate.formatted(date: .omitted, time: .shortened)) · \(money(latest.total, latest.currency))")
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
                            Text(money(updated.total, updated.currency)).amountFont().foregroundStyle(Palette.ink)
                                .accessibilityIdentifier("finish.pay")
                            Text(change(from: latest, to: updated)).font(.footnote).foregroundStyle(Palette.muted)
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
        let difference = money(abs(new.total - old.total), new.currency)
        return minutes > 0 ? "\(length) longer than booked: \(difference) more, overtime included."
                           : "\(length) shorter than booked: \(difference) less."
    }
    private func finishOnTime() {
        LiveShiftCenter.confirm(shift.id, in: store); LiveShiftCenter.clearOvertime(shift.id); dismiss()
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
        AppForm {
            Section {
                Toggle("Show on Lock Screen", isOn: lockScreen).accessibilityIdentifier("live.lockScreen")
                Text("While a shift is on, the Lock Screen and Dynamic Island show the time left and your pay for the shift. It appears 30 minutes before the shift with a countdown to the start, even if HowMuch is closed, and stays live through long shifts. When the booked time ends it asks if you've finished: tap Staying late to count your overtime, then Finished now when you leave. Job names follow your Job notifications privacy setting.")
                    .font(.footnote).foregroundStyle(Palette.muted)
                if !LiveShiftCenter.systemAllows {
                    Text("Live Activities are turned off for HowMuch in iPhone Settings.").font(.footnote).foregroundStyle(.orange)
                }
            } header: { FormHeader("Lock Screen") }
            Section {
                Toggle("Ask what time I finished", isOn: askFinish).accessibilityIdentifier("live.askFinish")
                Text("After an hourly shift ends, HowMuch asks once whether you finished on time. Staying late updates that shift's pay, including overtime.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            } header: { FormHeader("Finish time") }
        }
        .detailStyle("Live shift")
    }
}
