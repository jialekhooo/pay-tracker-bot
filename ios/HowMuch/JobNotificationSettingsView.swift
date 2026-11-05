import SwiftUI
import UserNotifications
import HowMuchCore

struct JobNotificationSettingsView: View {
    @EnvironmentObject private var store: TrackerStore
    @EnvironmentObject private var auth: AppleAccountStore
    @ObservedObject private var push = PushCenter.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var options = JobNotificationOptions()
    @State private var loadedOptions = false
    @State private var dayBefore = Date()
    @State private var paymentTime = Date()
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var saved = false
    @State private var testMessage = ""
    @State private var testing = false
    var body: some View {
        Form {
            Section("Job alerts") {
                Toggle("Job notifications", isOn: $options.enabled)
                Toggle("Upcoming shifts · day before", isOn: $options.upcoming)
                Toggle("Job start reminders", isOn: $options.starts)
                Toggle("End-of-shift reminders", isOn: $options.ends)
                Toggle("Payment due reminders", isOn: $options.paymentDue)
            }
            Section("Before a job starts") {
                ForEach(startChoices, id: \.self) { minutes in
                    Toggle(startLabel(minutes), isOn: Binding(get: { options.startReminderMinutes.contains(minutes) }, set: { selected in
                        var values = options.startReminderMinutes
                        if selected { values.append(minutes) } else { values.removeAll { $0 == minutes } }
                        options.startReminderMinutes = values
                    })).disabled(!options.starts).accessibilityIdentifier("notifications.start.\(minutes)")
                }
                Text(options.startReminderMinutes.isEmpty ? "Choose at least one time, or turn Job start reminders off." : "Choose as many as you like. Each selected time sends one reminder per job. Passed times are skipped.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            Section("Other timing & privacy") {
                DatePicker("Day-before alert", selection: $dayBefore, displayedComponents: .hourAndMinute)
                DatePicker("Payment due alert", selection: $paymentTime, displayedComponents: .hourAndMinute)
                LabeledContent("Timezone", value: TimeZone.current.identifier)
                Toggle("Show job names and locations", isOn: $options.showDetails).accessibilityIdentifier("notifications.details")
                Text("Turn this off to keep job names and locations off your lock screen. Times and reminder types remain visible.").font(.caption).foregroundStyle(Palette.muted)
            }
            Section("Lock-screen preview") {
                HStack(alignment: .top, spacing: 12) {
                    Image("BrandLogo").resizable().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview.title).font(.subheadline.bold())
                        Text(preview.body).font(.subheadline)
                    }.accessibilityIdentifier("notifications.preview")
                }.padding(.vertical, 6)
                Text("Touch and hold a reminder to open its job or review a payment. Notifications are grouped by job.").font(.caption).foregroundStyle(Palette.muted)
            }
            Section("Delivery") {
                Label(deliveryTitle, systemImage: notificationsAllowed ? "checkmark.circle.fill" : "bell.slash")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(notificationsAllowed ? Palette.teal : Palette.ink)
                    .accessibilityIdentifier("notifications.deliveryStatus")
                Text(deliveryDetail).font(.caption).foregroundStyle(Palette.muted)
                if let error = push.registrationError {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                } else if auth.pushMessage.hasPrefix("Couldn’t") {
                    Label(auth.pushMessage, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                }
                if authorization == .notDetermined {
                    Button("Enable notifications", systemImage: "bell.badge") { Task { await auth.enableNotifications(); await readPermission() } }.rowAction().accessibilityIdentifier("notifications.enable")
                } else if notificationsAllowed && (push.registrationError != nil || auth.pushMessage.hasPrefix("Couldn’t")) {
                    Button("Retry notification connection", systemImage: "arrow.clockwise") { Task { await auth.registerPushIfAllowed(); await readPermission() } }.rowAction()
                }
                if notificationsAllowed {
                    Button("Send test notification", systemImage: "paperplane") { Task { await sendTest() } }.rowAction().disabled(testing).accessibilityIdentifier("notifications.test")
                }
                if !testMessage.isEmpty { Text(testMessage).font(.caption).foregroundStyle(Palette.muted) }
                Button("Open iPhone notification settings", systemImage: "gearshape") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }.rowAction()
            }

            Button("Save notification preferences") {
                options.dayBeforeMinute = minute(dayBefore); options.dueMinute = minute(paymentTime)
                if store.updatePreferences({ $0.notifications = options }) {
                    saved = true
                    Task { await auth.synchronize(); await auth.registerPushIfAllowed() }
                }
            }.glassAction().disabled(options.starts && options.startReminderMinutes.isEmpty).accessibilityIdentifier("notifications.save")
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        }.detailStyle("Job notifications")
            .task {
                options = store.data.settings.jobNotifications
                dayBefore = time(options.dayBeforeMinute); paymentTime = time(options.dueMinute)
                loadedOptions = true
                await readPermission()
            }
            .onChange(of: scenePhase) { _, value in if value == .active { Task { await readPermission() } } }
            .alert("Preferences saved", isPresented: $saved) { Button("OK", role: .cancel) {} }
            // Leaving with changes saves them, so pressing Back never loses your choices.
            .onDisappear {
                var next = options
                next.dayBeforeMinute = minute(dayBefore); next.dueMinute = minute(paymentTime)
                guard loadedOptions, next != store.data.settings.jobNotifications, !(next.starts && next.startReminderMinutes.isEmpty) else { return }
                if store.updatePreferences({ $0.notifications = next }) { Task { await auth.synchronize(); await auth.registerPushIfAllowed() } }
            }
    }
    private var startChoices: [Int] { Array(Set([120, 60, 30, 15, 5, 0] + options.startReminderMinutes)).sorted(by: >) }
    private func startLabel(_ minutes: Int) -> String {
        if minutes == 0 { return "At start time" }
        if minutes % 60 == 0 { return "\(minutes / 60) \(minutes == 60 ? "hour" : "hours") before" }
        return "\(minutes) minutes before"
    }
    private var preview: (title: String, body: String) {
        let shift = store.data.shifts.filter { $0.startDate > Date() }.sorted { $0.startDate < $1.startDate }.first
        let time = shift.map { Shift.clock($0.startMinute) } ?? "09:00"
        let name = shift?.event ?? "Example shift"
        let location = shift?.location ?? "Example venue"
        return ("Shift starts at " + time, options.showDetails ? name + (location.isEmpty ? "" : " · " + location) : "Open HowMuch for your location and job details.")
    }
    private func sendTest() async {
        testing = true; defer { testing = false }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            testMessage = "Allow notifications in iPhone Settings, then try again."; return
        }
        let content = UNMutableNotificationContent()
        content.title = "HowMuch reminders are ready"
        content.body = "This is a test notification from this iPhone. Your job reminders use your saved settings."
        content.sound = .default; content.threadIdentifier = "howmuch.test"
        content.userInfo = ["account_id": store.accountID, "kind": "test"]
        do {
            try await center.add(UNNotificationRequest(identifier: "howmuch.test.\(store.accountID)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
            testMessage = "Test scheduled in 5 seconds. Lock your iPhone to check its appearance. This tests iPhone notifications, not server push."
        } catch { testMessage = "Couldn’t schedule the test. Check iPhone notification settings and try again." }
    }
    private func minute(_ value: Date) -> Int { Calendar.current.component(.hour, from: value) * 60 + Calendar.current.component(.minute, from: value) }
    private func time(_ value: Int) -> Date { Calendar.current.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: Date())! }
    private var notificationsAllowed: Bool { authorization == .authorized || authorization == .provisional || authorization == .ephemeral }
    private var deliveryTitle: String {
        if notificationsAllowed { return "Notifications are on" }
        return authorization == .denied ? "Notifications are off" : "Allow notifications on this iPhone"
    }
    private var deliveryDetail: String {
        if authorization == .denied { return "Turn on notifications in iPhone Settings to receive job reminders." }
        if !notificationsAllowed { return "Enable alerts to receive your saved job reminders." }
        return store.usesRemotePush ? "Job reminders can arrive while HowMuch is closed." : "Open HowMuch regularly to keep this iPhone’s reminders up to date."
    }
    private func readPermission() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

}

struct TravelEstimate: Decodable {
    let durationSeconds: Int
    let distanceMeters: Int
    let leaveAt: Double
    let arriveAt: Double
    let shiftStart: Double
    let originName: String
    let destinationName: String
    let checkedAt: Double
}
private struct TravelServiceStatus: Decodable { let ready: Bool }

struct TravelReminderSettingsView: View {
    @EnvironmentObject private var store: TrackerStore
    @EnvironmentObject private var auth: AppleAccountStore
    @ObservedObject private var transitPlanner = NativeTransitPlanner.shared
    @State private var options = TravelReminderOptions()
    @FocusState private var originFocused: Bool
    @State private var choosingOrigin = false
    @State private var consent = false
    @State private var busy = false
    @State private var message = ""
    @State private var ready = false
    @State private var loaded = false
    @State private var estimate: TravelEstimate?
    private var next: Shift? { store.data.shifts.filter { $0.startDate > Date() && $0.startDate < Date().addingTimeInterval(86400) && !$0.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted { $0.startDate < $1.startDate }.first }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    Label("A LITTLE LESS RUSH", systemImage: "car.side").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.teal)
                    Text("Arrive with time to spare.").font(.appTitle)
                    Text("Route estimates help plan your departure. Receive a heads-up, a time-to-leave reminder, and an update if your journey gets longer.").font(.subheadline).foregroundStyle(Palette.muted)
                    Toggle("Time to leave reminders", isOn: $options.enabled).accessibilityIdentifier("travel.enabled")
                }
                Card {
                    Text("Your usual starting point").font(.appHeadline)
                    TextField("Departure address, city and country", text: $options.origin, axis: .vertical).autocorrectionDisabled().focused($originFocused).accessibilityIdentifier("travel.origin")
                    Button("Find a departure address", systemImage: "magnifyingglass") { originFocused = false; choosingOrigin = true }.rowAction()
                    Text("This saved address is used for every job. HowMuch does not track where you are. Include a city and country to avoid a wrong match.").font(.caption).foregroundStyle(Palette.muted)
                }
                Card {
                    Picker("Travel by", selection: Binding(get: { options.effectiveMode }, set: { value in options.transit = value == "transit" ? true : nil; options.mode = value == "transit" ? "automobile" : value })) {
                        Text("Driving").tag("automobile"); Text("Walking").tag("walking"); Text("Cycling").tag("cycling"); Text("Public transport · bus/MRT").tag("transit")
                    }.accessibilityIdentifier("travel.mode")
                    Stepper("Arrive \(options.arrivalBuffer) min early", value: $options.arrivalBuffer, in: 0...120, step: 5)
                    Stepper(options.prepareMinutes == 0 ? "No preparation reminder" : "Heads-up \(options.prepareMinutes) min before leaving", value: $options.prepareMinutes, in: 0...60, step: 5)
                    if options.transit != true { Toggle("Check for journey changes", isOn: $options.trafficUpdates) }
                    Text("Public transport uses Apple Maps estimates refreshed when HowMuch opens. Planned reminders can fire while the app is closed; live bus/MRT delay updates require opening the app again.").font(.caption).foregroundStyle(Palette.muted)
                }
                Card {
                    Label(options.transit == true ? "iPhone public-transport reminders" : loaded ? (ready ? "Routing service ready" : "Routing service unavailable") : "Checking routing service…", systemImage: "map").font(.subheadline.weight(.semibold))
                    Text(options.transit == true ? "Allow notifications, then open HowMuch regularly to refresh up to four upcoming journeys within 24 hours. Passed reminder times are skipped. Route availability depends on Apple Maps coverage." : "Checks run about every 5 minutes during the 6 hours before a job. Allow push notifications on this iPhone. Delivery and traffic estimates can change; always check your route before travelling.").font(.caption).foregroundStyle(Palette.muted)
                    Button("Enable iPhone notifications", systemImage: "bell.badge") { Task { await auth.enableNotifications() } }.rowAction()
                    #if DEBUG
                    if CommandLine.arguments.contains("--ui-test-transit-notification") {
                        Button("Test scheduled transit reminder") {
                            Task {
                                var snapshot = store.data
                                snapshot.shifts = next.map { [$0] } ?? []
                                do { let count = try await ShiftNotifications.schedule(snapshot, accountID: store.accountID, remote: true); message = "\(count) planned transit reminder." }
                                catch { message = error.localizedDescription }
                            }
                        }.rowAction().accessibilityIdentifier("travel.testPlan")
                    }
                    #endif
                    if !auth.pushMessage.isEmpty { Text(auth.pushMessage).font(.caption).foregroundStyle(Palette.muted) }
                }
                if options.transit == true { Text(transitPlanner.message).font(.caption).foregroundStyle(Palette.muted).accessibilityIdentifier("travel.transitStatus") }
                Button(busy ? "Saving…" : "Save travel preferences") {
                    originFocused = false
                    if options.enabled { consent = true } else { Task { await save() } }
                }.glassAction().disabled(busy || (options.enabled && options.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)).accessibilityIdentifier("travel.save")
                if let shift = next {
                    Card {
                        Label("NEXT JOURNEY", systemImage: "map").font(.caption.weight(.semibold)).foregroundStyle(Palette.teal)
                        Text(shift.event).font(.appHeadline)
                        Text(shift.location).font(.subheadline).foregroundStyle(Palette.muted)
                        if let estimate { TravelEstimateSummary(estimate: estimate) }
                        Button("Check saved route", systemImage: "arrow.clockwise") { originFocused = false; Task { await check(shift) } }.rowAction().disabled(busy || (!ready && options.transit != true) || !store.data.settings.travelEnabled).accessibilityIdentifier("travel.check")
                        Text("Save first. Checking sends your saved departure and this destination to HowMuch and Apple Maps. Confirm the resolved places below before relying on a reminder.").font(.caption).foregroundStyle(Palette.muted)
                    }
                } else { Text("Add a job with a location starting within 24 hours to preview its route.").font(.subheadline).foregroundStyle(Palette.muted) }
                if !message.isEmpty { Text(message).font(.subheadline).foregroundStyle(Palette.muted).accessibilityIdentifier("travel.message") }
            }.padding(20)
        }.scrollDismissesKeyboard(.interactively).detailStyle("Time to leave")
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { originFocused = false } } }
            .task { options = store.data.settings.travel ?? TravelReminderOptions(); await status() }
            .sheet(isPresented: $choosingOrigin) { JobLocationPicker(initial: options.origin, purpose: "YOUR DEPARTURE ADDRESS") { options.origin = $0; estimate = nil } }
            .alert("Enable route checks?", isPresented: $consent) {
                Button("Enable & save") { Task { await save() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your departure address, job destinations, travel mode and arrival times will be sent to the HowMuch service and Apple Maps for route checks, including while the app is closed. No live location tracking is used. You can disable this at any time.") }
            .onChange(of: options) { _, _ in estimate = nil }
    }
    private func status() async {
        defer { loaded = true }
        var preview = false
        #if DEBUG
        preview = TravelReminderUITestFixture.active
        #endif
        guard !auth.isDemo || preview else { message = "Travel checks require your signed-in HowMuch account."; return }
        do { ready = try JSONDecoder().decode(TravelServiceStatus.self, from: await auth.api.request("/v1/travel/status")).ready }
        catch { message = "Couldn’t check the routing service. Your preferences are kept; try reopening this page." }
    }
    private func save() async {
        busy = true; defer { busy = false }
        options.origin = options.origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.updatePreferences({ $0.travel = options }) else { return }
        await auth.synchronize(); await auth.registerPushIfAllowed()
        message = options.enabled && options.transit == true ? "Public transport saved. Estimates refresh while HowMuch is open; planned iPhone reminders can fire while it is closed. Check the next route below." : options.enabled ? "Saved on this iPhone. Travel reminders need account sync, routing service availability and push permission. Check the next route below." : "Travel reminders turned off. Sync your account to cancel pending server reminders."
        await status()
    }
    private func check(_ shift: Shift) async {
        busy = true; estimate = nil; defer { busy = false }
        do {
            let saved = store.data.settings.travel ?? TravelReminderOptions()
            if saved.transit == true {
                estimate = try await NativeTransitPlanner.shared.estimate(shift: shift, options: saved, accountID: store.accountID)
                store.refreshReminders()
            } else {
                let body = try JSONEncoder().encode(["shiftID": shift.id.uuidString])
                estimate = try JSONDecoder().decode(TravelEstimate.self, from: await auth.api.request("/v1/travel/check", method: "POST", body: body))
            }
            message = "Estimate refreshed. Confirm the departure and destination match your intended journey."
        } catch { message = error.localizedDescription }
    }
}

private struct TravelEstimateSummary: View {
    let estimate: TravelEstimate
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(estimate.leaveAt <= Date().timeIntervalSince1970 ? "Leave now" : "Leave at \(Date(timeIntervalSince1970: estimate.leaveAt).formatted(date: .omitted, time: .shortened))").font(.title3.bold()).foregroundStyle(Palette.teal)
            if estimate.leaveAt <= Date().timeIntervalSince1970 { Text("Your planned departure time has passed. Check your route in Maps now.").font(.caption).foregroundStyle(Palette.muted) }
            Text("About \(Int(ceil(Double(estimate.durationSeconds) / 60))) min · arrive by \(Date(timeIntervalSince1970: estimate.arriveAt).formatted(date: .omitted, time: .shortened))").font(.subheadline)
            if !estimate.originName.isEmpty { Text("From: " + estimate.originName).font(.caption) }
            if !estimate.destinationName.isEmpty { Text("To: " + estimate.destinationName).font(.caption) }
            Text("Checked \(Date(timeIntervalSince1970: estimate.checkedAt).formatted(date: .omitted, time: .shortened)). Estimates can change.").font(.caption).foregroundStyle(Palette.muted)
        }.accessibilityElement(children: .combine)
    }
}

struct TravelDepartureView: View {
    @EnvironmentObject private var store: TrackerStore
    @Environment(\.openURL) private var openURL
    let shift: Shift
    @State private var mapsError = false
    @State private var manualDirections = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    Label("YOUR NEXT JOURNEY", systemImage: "map").font(.caption.weight(.semibold)).foregroundStyle(Palette.teal)
                    Text(shift.event).font(.appTitle)
                    Text(shift.location).font(.appHeadline)
                    Text("Shift starts \(shift.startDate.formatted(date: .abbreviated, time: .shortened))").font(.subheadline).foregroundStyle(Palette.muted)
                    if let origin = store.data.settings.travel?.origin { Text("From: " + origin).font(.subheadline) }
                }
                Button("Open route in Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond") {
                    let options = store.data.settings.travel ?? TravelReminderOptions()
                    var modern = false
                    if #available(iOS 18.4, *) { modern = true }
                    if let url = options.directionsURL(destination: shift.location, modern: modern) {
                        openURL(url) { success in mapsError = !success }
                    } else { manualDirections = true }
                }.glassAction()
                if mapsError { Text("Couldn’t open Maps. Try opening Apple Maps and entering the destination.").foregroundStyle(.red) }
                NavigationLink("Review travel reminders") { TravelReminderSettingsView() }.glassAction()
                NavigationLink("View job details") { ShiftDetailView(shiftID: shift.id) }.glassAction()
            }.padding(20)
        }.detailStyle("Time to leave")
            .sheet(isPresented: $manualDirections) {
                JobDirectionsView(location: shift.location)
                    .safeAreaInset(edge: .bottom) { Text("On this iOS version, confirm your departure address and cycling mode in Apple Maps. Directions initially use your current location.").font(.caption).padding().background(.regularMaterial) }
            }
    }
}

#if DEBUG
enum TravelReminderUITestFixture {
    static var active: Bool { CommandLine.arguments.contains("--ui-test-travel") }
    static func response(for request: URLRequest) throws -> Data? {
        guard active, let path = request.url?.path, path.hasPrefix("/v1/travel/") else { return nil }
        if path == "/v1/travel/status" { return Data("{\"ready\":true,\"estimates\":[]}".utf8) }
        if path == "/v1/travel/check" {
            if CommandLine.arguments.contains("--ui-test-travel-error") { throw AccountHTTPError(status: 503, message: "Route estimates are temporarily unavailable. Check Apple Maps before travelling.") }
            let now = Date().timeIntervalSince1970
            return try JSONSerialization.data(withJSONObject: ["durationSeconds": 1800, "distanceMeters": 12000,
                "leaveAt": now + 3600, "arriveAt": now + 5400, "shiftStart": now + 6300,
                "originName": "Singapore Botanic Gardens", "destinationName": "Marina Bay Sands", "checkedAt": now])
        }
        throw AccountHTTPError(status: 503, message: "Unsupported synthetic travel request")
    }
}
#endif
