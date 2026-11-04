import SwiftUI
import EventKit
import EventKitUI
import UniformTypeIdentifiers
import UserNotifications
import HowMuchCore

struct CalendarEventEditor: UIViewControllerRepresentable {
    let shift: Shift
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        let store = EKEventStore()
        controller.eventStore = store
        let event = EKEvent(eventStore: store)
        event.title = shift.event; event.startDate = shift.startDate; event.endDate = shift.endDate
        event.location = shift.location
        event.notes = "HowMuch · \(shift.currency) \(shift.pay) · \(PayEngine.rounded(shift.hours)) paid hours"
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { dismiss() }
    }
}

struct TextFile: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .json, .calendarEvent] }
    var text: String
    init(_ text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else { throw TrackerError.invalid("Unreadable file.") }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

struct CalendarSettingsView: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var export = false
    @State private var scope = "Upcoming"
    @EnvironmentObject private var auth: AppleAccountStore
    @Environment(\.openURL) private var openURL
    @State private var link: String?
    @State private var rotateLink = false
    @State private var linkMessage = ""
    @State private var document = TextFile("")
    var body: some View {
        Form {
            Section {
                Label("Your work calendar", systemImage: "calendar.badge.clock").font(.headline)
                Text("The Calendar tab shows every local shift. Tap any shift to add it directly to Apple Calendar, or export a calendar file below.").font(.subheadline).foregroundStyle(Palette.muted)
            }
            Section("Export local shifts") {
                Picker("Include", selection: $scope) { Text("Upcoming").tag("Upcoming"); Text("This month").tag("This month"); Text("All shifts").tag("All shifts") }
                Button("Export calendar (.ics)", systemImage: "square.and.arrow.up") {
                    let shifts = store.data.shifts.filter { shift in
                        scope == "All shifts" || (scope == "Upcoming" ? shift.endDate > Date() : shift.day.hasPrefix(String(Shift.dayString(Date()).prefix(7))))
                    }
                    document = TextFile(CalendarExport.encode(shifts)); export = true
                }.rowAction().accessibilityIdentifier("calendar.exportICS")
                Text("Open the .ics file from Files to import it into your calendar. This is a snapshot; later local edits require a new export.").font(.caption).foregroundStyle(Palette.muted)
            }
            Section("Your account’s calendar subscription") {
                if let link, let url = URL(string: link) {
                    Text(link).font(.caption).textSelection(.enabled)
                    ShareLink("Copy or share calendar link", item: url)
                    Button("Add subscription in Calendar") {
                        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        components?.scheme = "webcal"
                        if let calendarURL = components?.url { openURL(calendarURL) }
                    }.rowAction()
                }
                Button(link == nil ? "Create private calendar link" : "Replace private calendar link") { rotateLink = true }.rowAction().disabled(auth.isDemo)
                Text("This feed contains your signed-in account’s synced shifts and updates as its records change. Anyone with the link can read the schedule; replacing it invalidates the previous link.").font(.caption).foregroundStyle(Palette.muted)
                if !linkMessage.isEmpty { Text(linkMessage).font(.caption).foregroundStyle(Palette.muted) }
            }
        }.detailStyle("Calendar & sync")
            .fileExporter(isPresented: $export, document: document, contentType: .calendarEvent, defaultFilename: "howmuch-shifts.ics") { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
            .onAppear { if let id = auth.account?.id { link = AccountVault.read("calendar." + id, as: String.self) } }
            .confirmationDialog("Create a new private link? Any previous subscription link will stop working.", isPresented: $rotateLink, titleVisibility: .visible) {
                Button("Create private link") { Task {
                    do {
                        await auth.synchronize()
                        let data = try await auth.api.request("/v1/calendar/link", method: "POST", body: Data("{}".utf8))
                        let response = try JSONDecoder().decode(CalendarLinkResult.self, from: data)
                        guard let id = auth.account?.id else { return }
                        try AccountVault.save(response.url, key: "calendar." + id)
                        link = response.url; linkMessage = "Private account calendar link created."
                    } catch { linkMessage = error.localizedDescription }
                } }
            }
    }
}

enum ShiftNotifications {
    static func schedule(_ data: TrackerData, accountID: String, remote: Bool) async throws -> Int {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        try Task.checkCancellation()
        let pending = await center.pendingNotificationRequests()
        try Task.checkCancellation()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("howmuch.") }.map(\.identifier))
        guard status == .authorized || status == .provisional else { return 0 }
        var plan = remote ? [] : Array(JobReminderPlan.make(data: data, accountID: accountID).prefix(data.settings.travel?.transit == true ? 52 : 60))
        if let options = data.settings.travel, options.enabled && options.transit == true {
            let future = data.shifts.filter { $0.startDate > Date() && $0.startDate < Date().addingTimeInterval(86400) && !$0.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted { $0.startDate < $1.startDate }
            for shift in future.prefix(4) {
                try Task.checkCancellation()
                do {
                    let estimate = try await NativeTransitPlanner.shared.estimate(shift: shift, options: options, accountID: accountID)
                    plan += TransitReminderPlan.make(shift: shift, options: options, accountID: accountID, leaveAt: Date(timeIntervalSince1970: estimate.leaveAt), showDetails: data.settings.jobNotifications.showDetails)
                } catch is CancellationError { throw CancellationError() }
                catch { await MainActor.run { NativeTransitPlanner.shared.message = "Public-transport estimates couldn't refresh. Check the saved route in Time to leave, or open Apple Maps." } }
            }
        }
        var scheduled = 0
        for reminder in plan {
            try Task.checkCancellation()
            guard reminder.fireDate > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = reminder.title; content.body = reminder.body; content.sound = .default
            content.threadIdentifier = "howmuch.\(accountID).\(reminder.shiftID.uuidString.lowercased())"
            content.categoryIdentifier = "HOWMUCH_" + reminder.kind.uppercased()
            content.interruptionLevel = .active
            content.userInfo = ["account_id": accountID, "shift_id": reminder.shiftID.uuidString, "kind": reminder.kind]
            var components = TrackerCalendar.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
            components.timeZone = .current
            try await center.add(UNNotificationRequest(identifier: reminder.id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
            scheduled += 1
        }
        return scheduled
    }
}

private struct CalendarLinkResult: Decodable { let url: String }
