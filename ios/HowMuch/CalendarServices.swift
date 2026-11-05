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
                Label("Your shifts in any calendar", systemImage: "calendar.badge.clock").font(.appHeadline)
                Text("Create a private live link once, and your shifts show up in Apple Calendar, Google Calendar or TimeTree, updating as you add or change jobs.").font(.subheadline).foregroundStyle(Palette.muted)
            }
            Section("Live calendar") {
                if let link, let url = URL(string: link) {
                    Button { openURL(Self.webcal(url)) } label: { Label("Subscribe in Apple Calendar", systemImage: "calendar") }
                        .accessibilityIdentifier("calendar.subscribeApple")
                    Button { openURL(Self.google(url)) } label: { Label("Add to Google Calendar", systemImage: "globe") }
                        .accessibilityIdentifier("calendar.subscribeGoogle")
                    ShareLink(item: url) { Label("Copy or share link", systemImage: "link") }
                    Text("Calendars check for changes about every hour; Google Calendar can take up to a day.").font(.caption).foregroundStyle(Palette.muted)
                } else {
                    Button { rotateLink = true } label: { Label("Create my live calendar link", systemImage: "plus.circle.fill") }
                        .rowAction().disabled(auth.isDemo).accessibilityIdentifier("calendar.createLink")
                    if auth.isDemo { Text("Sign in to your own Apple account to create a live calendar link.").font(.caption).foregroundStyle(Palette.muted) }
                }
                if !linkMessage.isEmpty { Text(linkMessage).font(.caption).foregroundStyle(Palette.muted) }
            }
            if link != nil {
                Section("Using TimeTree?") {
                    step(1, "Subscribe in Apple Calendar", "Tap Subscribe in Apple Calendar above, then Subscribe. A calendar called HowMuch shifts appears on your iPhone.")
                    step(2, "Show it in TimeTree", "TimeTree can show the calendars on your iPhone. In TimeTree's calendar settings, turn on your iPhone's calendars and pick HowMuch shifts.")
                    Text("TimeTree closed its API to other apps in 2023, so this is the way to see your shifts there.").font(.caption).foregroundStyle(Palette.muted)
                }
                Section {
                    Button("Replace link", role: .destructive) { rotateLink = true }.disabled(auth.isDemo)
                } footer: {
                    Text("Anyone with the link can see your shifts and pay. Replacing it stops the old link working; subscribe again with the new one.")
                }
            }
            Section("One-off export") {
                Picker("Include", selection: $scope) { Text("Upcoming").tag("Upcoming"); Text("This month").tag("This month"); Text("All shifts").tag("All shifts") }
                Button("Export calendar (.ics)", systemImage: "square.and.arrow.up") {
                    let shifts = store.data.shifts.filter { shift in
                        scope == "All shifts" || (scope == "Upcoming" ? shift.endDate > Date() : shift.day.hasPrefix(String(Shift.dayString(Date()).prefix(7))))
                    }
                    document = TextFile(CalendarExport.encode(shifts)); export = true
                }.rowAction().accessibilityIdentifier("calendar.exportICS")
                Text("A file you open once; it won't update. To add a single shift, tap it and choose Add to Calendar.").font(.caption).foregroundStyle(Palette.muted)
            }
        }.detailStyle("Calendar sync")
            .fileExporter(isPresented: $export, document: document, contentType: .calendarEvent, defaultFilename: "howmuch-shifts.ics") { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
            .onAppear {
                if let id = auth.account?.id { link = AccountVault.read("calendar." + id, as: String.self) }
                #if DEBUG
                if CommandLine.arguments.contains("--ui-test-calendar-link") { link = "https://howmuch-ios.fly.dev/calendar/preview.ics" }
                #endif
            }
            .task {
                // The link belongs to the account, so a second iPhone shows the same one.
                guard !auth.isDemo, let id = auth.account?.id,
                      let data = try? await auth.api.request("/v1/calendar/link", method: "GET", body: nil),
                      let current = try? JSONDecoder().decode(CalendarLinkLookup.self, from: data) else { return }
                link = current.url
                if let url = current.url { try? AccountVault.save(url, key: "calendar." + id) }
            }
            .confirmationDialog(link == nil ? "Create a private live calendar link?" : "Replace your link? Calendars using the old one stop updating.", isPresented: $rotateLink, titleVisibility: .visible) {
                Button(link == nil ? "Create link" : "Replace link") { Task {
                    do {
                        await auth.synchronize()
                        let data = try await auth.api.request("/v1/calendar/link", method: "POST", body: Data("{}".utf8))
                        let response = try JSONDecoder().decode(CalendarLinkResult.self, from: data)
                        guard let id = auth.account?.id else { return }
                        try AccountVault.save(response.url, key: "calendar." + id)
                        link = response.url; linkMessage = "Your live calendar link is ready."
                    } catch { linkMessage = error.localizedDescription }
                } }
            }
    }
    static func webcal(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "webcal"
        return components?.url ?? url
    }
    /// Google Calendar's "add by URL" page, pre-filled with the feed.
    static func google(_ url: URL) -> URL {
        var components = URLComponents(string: "https://calendar.google.com/calendar/render")!
        components.queryItems = [URLQueryItem(name: "cid", value: webcal(url).absoluteString)]
        return components.url!
    }
    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.subheadline.weight(.bold)).foregroundStyle(.white).frame(width: 26, height: 26).background(Palette.teal, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(Palette.muted)
            }
        }.padding(.vertical, 4)
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

private struct CalendarLinkLookup: Decodable { let url: String? }
