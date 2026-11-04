import SwiftUI
import ActivityKit
import HowMuchCore

/// Starts, updates and ends the Lock Screen card for the shift in progress.
/// iOS only lets an app start a Live Activity while it is open, so this runs whenever
/// HowMuch is opened or its data changes (including from a job notification tap).
@MainActor
enum LiveShiftCenter {
    static let lockScreenKey = "liveShift.lockScreen"
    static let askFinishKey = "liveShift.askFinish"
    static var lockScreenEnabled: Bool { !automatedTest && (UserDefaults.standard.object(forKey: lockScreenKey) as? Bool ?? true) }
    static var askFinishEnabled: Bool { !automatedTest && (UserDefaults.standard.object(forKey: askFinishKey) as? Bool ?? true) }
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

    static func sync(_ data: TrackerData, accountID: String, now: Date = Date()) {
        let activities = Activity<LiveShiftAttributes>.activities
        for activity in activities {
            guard lockScreenEnabled, activity.attributes.accountID == accountID,
                  let shift = data.shifts.first(where: { $0.id == activity.attributes.shiftID }) else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                continue
            }
            let content = ActivityContent(state: state(for: shift, accountID: accountID), staleDate: shift.endDate)
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
              !activities.contains(where: { $0.attributes.shiftID == current.id && $0.attributes.accountID == accountID && $0.activityState == .active })
        else { return }
        let content = ActivityContent(state: state(for: current, accountID: accountID), staleDate: current.endDate)
        _ = try? Activity.request(attributes: LiveShiftAttributes(shiftID: current.id, accountID: accountID), content: content, pushType: nil)
    }

    static func endAll() {
        for activity in Activity<LiveShiftAttributes>.activities { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
    }

    private static func state(for shift: Shift, accountID: String) -> LiveShiftAttributes.ContentState {
        LiveShiftAttributes.ContentState(
            event: shift.event, location: shift.location.split(separator: ",").first.map(String.init) ?? "",
            start: shift.startDate, end: shift.endDate,
            pay: NSDecimalNumber(decimal: shift.pay).doubleValue, currency: shift.currency,
            shiftURL: WidgetLink.shift(shift.id).url(accountID: accountID),
            finishURL: WidgetLink.finish(shift.id).url(accountID: accountID))
    }

    // MARK: Finish-time questions

    private static func confirmedKey(_ accountID: String) -> String { "liveShift.confirmed.\(accountID)" }
    static func confirmed(accountID: String) -> Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: confirmedKey(accountID)) ?? []).compactMap(UUID.init(uuidString:)))
    }
    static func confirm(_ id: UUID, accountID: String) {
        var saved = UserDefaults.standard.stringArray(forKey: confirmedKey(accountID)) ?? []
        saved.removeAll { $0 == id.uuidString }; saved.append(id.uuidString)
        UserDefaults.standard.set(Array(saved.suffix(300)), forKey: confirmedKey(accountID))
    }
    /// The next ended hourly shift whose actual finishing time hasn't been confirmed.
    static func nextToConfirm(_ data: TrackerData, accountID: String, now: Date = Date()) -> Shift? {
        guard askFinishEnabled else { return nil }
        return LiveShiftPlanner.awaitingFinish(in: data.shifts, confirmed: confirmed(accountID: accountID), at: now).first
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
        LiveShiftCenter.confirm(shift.id, accountID: store.accountID); dismiss()
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
    @AppStorage(LiveShiftCenter.lockScreenKey) private var lockScreen = true
    @AppStorage(LiveShiftCenter.askFinishKey) private var askFinish = true
    var body: some View {
        Form {
            Section {
                Toggle("Show on Lock Screen", isOn: $lockScreen).accessibilityIdentifier("live.lockScreen")
                Text("While a shift is on, the Lock Screen and Dynamic Island show the time left and your pay for the shift. It appears when you open HowMuch from 30 minutes before a shift, for example from its start reminder.")
                    .font(.caption).foregroundStyle(Palette.muted)
                if !LiveShiftCenter.systemAllows {
                    Text("Live Activities are turned off for HowMuch in iPhone Settings.").font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("Lock Screen") }
            Section {
                Toggle("Ask what time I finished", isOn: $askFinish).accessibilityIdentifier("live.askFinish")
                Text("After an hourly shift ends, HowMuch asks once whether you finished on time. Staying late updates that shift's pay, including overtime.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
        }
        .navigationTitle("Live shift")
        .onChange(of: lockScreen) { _, _ in LiveShiftCenter.sync(store.data, accountID: store.accountID) }
    }
}
