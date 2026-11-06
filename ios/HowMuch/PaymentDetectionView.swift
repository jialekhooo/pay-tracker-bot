import SwiftUI
import HowMuchCore

struct PaymentDetectionView: View {
    @EnvironmentObject private var store: TrackerStore
    @EnvironmentObject private var auth: AppleAccountStore
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: DetectionStatus?
    @State private var message = ""
    @State private var busy = false
    @State private var disconnect = false
    /// The app-password mailbox being connected (iCloud Mail or Gmail), shown as a sheet.
    @State private var mailboxSheet: AppPasswordMailbox?
    @State private var iCloudEmail = ""
    @State private var iCloudPassword = ""
    @State private var iCloudConsent = false
    @State private var pendingReceipt: DetectionReceipt?
    @State private var pendingEvent = ""
    @State private var confirmBank = false
    @State private var payIn: PayInStatus?
    @State private var copied = false
    private let path = "/v1/payment-detection"
    private var previewOnly: Bool {
        #if DEBUG
        return auth.isDemo && !CommandLine.arguments.contains("--ui-test-payments")
        #else
        return auth.isDemo
        #endif
    }
    @State private var replacingAddress = false
    @State private var pendingShort: (id: Int, event: String, shortfall: String)?
    @State private var pendingDismiss: String?
    @State private var settingUpBank = false
    var body: some View {
        AppForm {
            if previewOnly {
                Section { Text("Sign in to your own Apple account to track pay coming in. The preview doesn't read any notifications or email.").foregroundStyle(Palette.muted) }
            } else if let status {
                Section(styled: "Bank app notifications") {
                  if #unavailable(iOS 27) {
                    // The Shortcuts "When I receive a notification" trigger arrived in iOS 27.
                    Text("Reading bank app notifications needs iOS 27. Until then, forward your bank's payment emails below.").font(.subheadline).foregroundStyle(Palette.muted)
                  } else {
                    Button { settingUpBank = true } label: { Label("Set up bank notifications", systemImage: "bell.badge") }
                        .accessibilityIdentifier("payin.notifications.setup")
                    lastRun
                    Toggle("Mark matching pay as paid", isOn: Binding(get: { payIn?.notificationsAuto ?? false },
                                                                       set: { enabled in Task { await setPayIn(enabled) } }))
                        .disabled(payIn == nil || busy).accessibilityIdentifier("payin.notifications.auto")
                    Text("When your bank app says money came in, a Shortcuts automation passes it to HowMuch. Pay from a saved payer that exactly matches an event's unpaid total is marked paid; anything else waits below for you to check.").font(.caption).foregroundStyle(Palette.muted)
                  }
                }
                Section(styled: "Email forwarding") {
                    if let address = payIn?.forwarding.address {
                        HStack {
                            Text(address).font(.subheadline.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { UIPasteboard.general.string = address; copied = true }
                                .labelStyle(.iconOnly).accessibilityLabel("Copy forwarding address")
                        }.accessibilityIdentifier("payin.forwarding.address")
                        if let confirmation = payIn?.forwarding.confirmation {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Gmail asked to confirm forwarding\(confirmation.account.map { " from \($0)" } ?? "")", systemImage: "checkmark.shield")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.teal)
                                if let code = confirmation.code {
                                    HStack {
                                        Text(code).font(.title3.monospacedDigit().weight(.bold)).textSelection(.enabled).accessibilityIdentifier("payin.forwarding.code")
                                        Spacer()
                                        Button("Copy code", systemImage: "doc.on.doc") { UIPasteboard.general.string = code }.labelStyle(.iconOnly)
                                    }
                                }
                                if let link = confirmation.link.flatMap(URL.init(string:)), link.host?.hasSuffix("google.com") == true {
                                    Link(destination: link) { Label("Confirm forwarding in Gmail", systemImage: "arrow.up.right.square") }
                                }
                                Text("Enter the code in Gmail's forwarding settings, or open the link. Then add a filter to forward DBS alerts.").font(.caption).foregroundStyle(Palette.muted)
                                Button { Task { await forwardingConfirmed() } } label: { Label("I've confirmed it", systemImage: "checkmark.circle") }
                                    .disabled(busy).accessibilityIdentifier("payin.forwarding.confirmed")
                            }.padding(.vertical, 4)
                        }
                        NavigationLink { EmailForwardingGuide(address: address) } label: { Label("How to forward bank emails", systemImage: "envelope.arrow.triangle.branch") }
                        Button("Get a new address", systemImage: "arrow.triangle.2.circlepath") { replacingAddress = true }
                            .disabled(busy).accessibilityIdentifier("payin.forwarding.rotate")
                        Text("Forward DBS \u{201C}You\u{2019}ve received a transfer\u{201D} alerts to this private address, by hand or with a mail rule. Forwarded emails always wait for you to check them below.").font(.caption).foregroundStyle(Palette.muted)
                    } else {
                        Text("Coming soon: a private address you can forward bank alert emails to.").font(.subheadline).foregroundStyle(Palette.muted)
                    }
                }
                Section(styled: "Connect your email") {
                    Label(status.connected ? "\(status.providerName) connected" : "No email connected", systemImage: status.connected ? "checkmark.shield" : "envelope")
                    if let email = status.email { Text(email).font(.caption).foregroundStyle(Palette.muted) }
                    if !status.available { Text("Email connection is not available yet for this app. Manual payment tracking remains available.").font(.caption).foregroundStyle(Palette.muted) }
                    if status.connected {
                        Button("Check payments now") { Task { await action("/scan") } }.rowAction().accessibilityIdentifier("payment.scan").disabled(!status.available || busy)
                        Button("Disconnect email", role: .destructive) { disconnect = true }.rowAction().accessibilityIdentifier("payment.disconnect")
                    } else {
                        // Hidden until Google has verified HowMuch; Gmail users can forward alerts instead.
                        if status.providers?["gmail"] ?? false {
                            Button("Connect Gmail") { Task { await connect() } }.rowAction().accessibilityIdentifier("payment.connect").disabled(busy)
                        } else if status.gmailAppPasswordReady {
                            // Gmail with an app password: works for everyone without Google's app verification.
                            Button("Connect Gmail") { mailboxSheet = .gmail }.rowAction().accessibilityIdentifier("payment.connect.gmail").disabled(busy)
                        } else {
                            Text("Using Gmail? Forward your bank's emails to your HowMuch address above.").font(.caption).foregroundStyle(Palette.muted)
                        }
                        Button("Connect Outlook / Hotmail") { Task { await connect(provider: "microsoft") } }.rowAction().accessibilityIdentifier("payment.connect.microsoft").disabled(!(status.providers?["microsoft"] ?? false) || busy)
                        if !(status.providers?["microsoft"] ?? false) { Text("Outlook sign-in is awaiting Microsoft setup.").font(.caption).foregroundStyle(Palette.muted) }
                        Button("Connect iCloud / me.com") { mailboxSheet = .icloud }.rowAction().accessibilityIdentifier("payment.connect.icloud").disabled(!(status.providers?["icloud"] ?? false) || busy)
                        Text("Choose the mailbox that receives your DBS alerts. One email connection per HowMuch account.").font(.caption).foregroundStyle(Palette.muted)
                    }
                    Text("HowMuch checks DBS alerts against your unpaid jobs and exact company rules. It never sends or deletes emails. New Outlook, iCloud and Gmail app-password matches need your bank confirmation before marking paid.").font(.caption).foregroundStyle(Palette.muted)
                    if !status.error.isEmpty { Text(status.error).font(.caption).foregroundStyle(.orange) }
                }
                Section(styled: "Automatic marking") {
                    Toggle("Mark exact verified matches paid", isOn: Binding(get: { status.autoEnabled }, set: { enabled in Task { await action("", method: "PATCH", body: ["auto_enabled": enabled]) } })).disabled(!status.connected || !status.available || status.provider != nil && status.provider != "gmail" || busy)
                    Text("Automatic marking is supported for verified alerts from Gmail connected with Google sign-in. Outlook, iCloud and Gmail app-password alerts need confirmation against your bank transaction. You can undo applied payments below.").font(.caption).foregroundStyle(Palette.muted)
                }
                Section(styled: "Saved payers") {
                    NavigationLink("Manage saved payers") { PayersSettingsView() }.accessibilityIdentifier("payment.payers")
                    Text("Save companies once in Settings → Payers. Choose ‘Paid by’ when adding/editing an event or from Earnings. Every saved bank name for the selected company is used for exact matching.").font(.caption).foregroundStyle(Palette.muted)
                    ForEach(payerGroups(status.rules)) { group in
                        DisclosureGroup {
                            ForEach(group.events, id: \.self) { event in
                                Text(event).font(.subheadline).foregroundStyle(Palette.muted).padding(.vertical, 4)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text(group.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(group.events.count) \(group.events.count == 1 ? "event" : "events")").font(.caption).foregroundStyle(Palette.muted)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.accessibilityIdentifier("payment.payerGroup." + group.id)
                    }
                }
                Section(styled: "Payment review & history") {
                    if status.receipts.isEmpty { Text("No pay received yet. Payments from saved payers appear here.").foregroundStyle(Palette.muted) }
                    ForEach(status.receipts) { receipt in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(receipt.currency) \(receipt.amount ?? "—")").font(.appHeadline)
                            Text(displayPayer(receipt.payer)).font(.subheadline)
                            Text(receipt.status.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption).foregroundStyle(Palette.teal)
                            Text(receipt.reason).font(.caption).foregroundStyle(Palette.muted)
                            if receipt.status == "review" {
                                ForEach(receipt.candidates, id: \.event) { candidate in
                                    Button(candidate.label) { if receipt.trusted == false { pendingReceipt = receipt; pendingEvent = candidate.event; confirmBank = true }
                                        else if candidate.kind == "short" { pendingShort = (receipt.id, candidate.event, candidate.shortfall ?? "") }
                                        else { Task { await action("/receipts/\(receipt.id)/confirm", body: ["event": candidate.event]) } } }.font(.caption).rowAction().disabled(busy).accessibilityIdentifier("payment.receipt.\(receipt.id).confirm")
                                }
                                // Destructive and confirmed: a dismissed payment isn't matched to any job.
                                Button("Dismiss alert", role: .destructive) { pendingDismiss = "/receipts/\(receipt.id)/dismiss" }.font(.caption).rowAction().disabled(busy).accessibilityIdentifier("payment.receipt.\(receipt.id).dismiss")
                            }
                            if ["confirmed_paid", "auto_paid"].contains(receipt.status) {
                                Button("Undo marking paid", systemImage: "arrow.uturn.backward") { Task { await action("/receipts/\(receipt.id)/undo") } }.font(.caption).rowAction().disabled(busy).accessibilityIdentifier("payment.receipt.\(receipt.id).undo")
                            }
                        }.padding(.vertical, 7)
                    }
                }
            } else if busy { Section { ProgressView("Checking your account…") } }
            else { Section { Label("Pay-in tracking couldn’t be loaded. Refresh to try again.", systemImage: "wifi.exclamationmark") } }
            if !message.isEmpty { Section { Text(message).font(.caption).foregroundStyle(Palette.muted) } }
            if !previewOnly { Button("Refresh") { Task { await load() } }.rowAction().disabled(busy) }
            if busy, status != nil { Section { ProgressView("Updating…") } }
        }.detailStyle("Pay-in tracking")
            .confirmationDialog("Get a new forwarding address? The old one stops working, so update your Gmail forwarding to the new one.", isPresented: $replacingAddress, titleVisibility: .visible) {
                Button("Get a new address", role: .destructive) { Task { await rotateAddress() } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(pendingShort.map { "\($0.shortfall) less than \($0.event)'s total arrived. Mark it paid anyway?" } ?? "",
                                isPresented: Binding(get: { pendingShort != nil }, set: { if !$0 { pendingShort = nil } }), titleVisibility: .visible) {
                Button("Mark paid") { if let short = pendingShort { pendingShort = nil; Task { await action("/receipts/\(short.id)/confirm", body: ["event": short.event]) } } }
                Button("Not yet", role: .cancel) { pendingShort = nil }
            } message: { Text("Only if that's what you agreed with the payer. The shortfall is kept in your payment history.") }
            .confirmationDialog("Dismiss this payment alert? It won't be matched to any job.", isPresented: Binding(get: { pendingDismiss != nil }, set: { if !$0 { pendingDismiss = nil } }), titleVisibility: .visible) {
                Button("Dismiss alert", role: .destructive) { if let path = pendingDismiss { pendingDismiss = nil; Task { await action(path) } } }
                Button("Keep it", role: .cancel) { pendingDismiss = nil }
            }
            .sheet(isPresented: $settingUpBank) { BankSetupWizard() }
            .task { if !previewOnly { await load() } }
            .onChange(of: scenePhase) { _, value in if value == .active && !previewOnly { Task { await load() } } }
            .confirmationDialog("Disconnect email for this HowMuch account?", isPresented: $disconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { await action("/connection", method: "DELETE") } }
            }
            .sheet(item: $mailboxSheet, onDismiss: { iCloudPassword = ""; iCloudConsent = false }) { mailboxForm($0) }
            .alert("Confirm bank payment", isPresented: $confirmBank) {
                Button("Cancel", role: .cancel) { pendingReceipt = nil }
                Button("I checked my bank · Mark paid") {
                    if let receipt = pendingReceipt { let selectedEvent = pendingEvent; Task { await action("/receipts/\(receipt.id)/confirm", body: ["event": selectedEvent, "acknowledge_unverified": true]) } }
                    pendingReceipt = nil
                }
            } message: { Text("Sender authentication could not be verified. Check the original bank transaction for the amount and payer before marking \(pendingEvent) paid.") }
    }
    private struct PayerGroup: Identifiable {
        let id: String
        let name: String
        var events: [String]
    }
    private func displayPayer(_ bankName: String) -> String {
        store.data.settings.savedPayers?.first { payer in payer.bankNames.contains { SavedPayer.key($0) == SavedPayer.key(bankName) } }?.displayName ?? bankName.uppercased()
    }
    private func payerGroups(_ rules: [DetectionRule]) -> [PayerGroup] {
        let library = store.data.settings.savedPayers ?? []
        var groups: [String: PayerGroup] = [:]
        for rule in rules {
            let payer = library.first { $0.bankNames.contains { SavedPayer.key($0) == SavedPayer.key(rule.payer) } }
            let key = payer?.id.uuidString ?? SavedPayer.key(rule.payer)
            if groups[key] == nil { groups[key] = PayerGroup(id: key, name: payer?.displayName ?? rule.payer.uppercased(), events: []) }
            if groups[key]?.events.contains(where: { SavedPayer.key($0) == SavedPayer.key(rule.event) }) == false { groups[key]?.events.append(rule.event) }
        }
        return groups.values.map { group in
            var sorted = group; sorted.events.sort { $0.localizedStandardCompare($1) == .orderedAscending }; return sorted
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func mailboxForm(_ mailbox: AppPasswordMailbox) -> some View {
        let gmail = mailbox == .gmail
        let name = gmail ? "Gmail" : "iCloud Mail"
        return NavigationStack {
            AppForm {
                Section(styled: "Your \(name)") {
                    TextField(gmail ? "Gmail address" : "iCloud / me.com / mac.com email", text: $iCloudEmail).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress).accessibilityIdentifier("payment.icloud.email")
                    SecureField(gmail ? "App password (16 letters)" : "App-specific password", text: $iCloudPassword).textContentType(.none).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("payment.icloud.password")
                    if gmail {
                        Link("Create an app password at Google", destination: URL(string: "https://myaccount.google.com/apppasswords")!)
                        Text("Turn on 2-Step Verification for your Google Account, then create an app password named HowMuch and paste the 16 letters here. Never use your main Google password. If Gmail says IMAP is off, turn it on in Gmail → Settings → Forwarding and POP/IMAP.").font(.caption)
                    } else {
                        Link("Create an app-specific password at Apple", destination: URL(string: "https://account.apple.com")!)
                        Text("In Apple Account → Sign-In and Security → App-Specific Passwords, create one for HowMuch. Use that password here, never your main Apple Account password.").font(.caption)
                    }
                }
                Section {
                    Toggle("Allow HowMuch to check my DBS emails", isOn: $iCloudConsent).accessibilityIdentifier("payment.icloud.consent")
                    Text("Your app password is sent securely to HowMuch and stored encrypted to check your inbox while the app is closed. HowMuch reads mail without changing it. \(gmail ? "Google" : "Apple")'s app password can permit broader mail access; you can revoke it at \(gmail ? "Google" : "Apple") anytime. Detected payments require bank confirmation.").font(.caption).foregroundStyle(Palette.muted)
                    Button(busy ? "Connecting…" : "Connect \(name)") { Task { await connectMailbox(mailbox) } }.rowAction().disabled(busy || !iCloudConsent || iCloudEmail.isEmpty || iCloudPassword.isEmpty).accessibilityIdentifier("payment.icloud.save")
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Palette.muted) }
                }
            }.scrollDismissesKeyboard(.interactively).navigationTitle("Connect \(name)").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { mailboxSheet = nil }.disabled(busy) } }.interactiveDismissDisabled(busy)
        }
    }
    private func connectMailbox(_ mailbox: AppPasswordMailbox) async {
        guard !busy else { return }
        if await action(mailbox == .gmail ? "/gmail-imap/connect" : "/icloud/connect", body: ["email": iCloudEmail, "app_password": iCloudPassword, "consent": iCloudConsent]) {
            iCloudPassword = ""; mailboxSheet = nil
        }
    }
    private func decode(_ data: Data) throws -> DetectionStatus {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DetectionStatus.self, from: data)
    }
    private func load() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            await auth.synchronize(); status = try decode(await auth.api.request(path)); message = ""
            payIn = try? decodePayIn(await auth.api.request(path + "/pay-in"))
        } catch { message = error.localizedDescription }
    }
    private func decodePayIn(_ data: Data) throws -> PayInStatus {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PayInStatus.self, from: data)
    }
    /// When the Shortcuts automation last handed HowMuch a notification: the proof it's linked.
    @ViewBuilder private var lastRun: some View {
        if let entry = PayInLog.load().first {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automation linked · last ran \(entry.date.formatted(.relative(presentation: .named)))").font(.subheadline.weight(.semibold))
                    Text(entry.result).font(.caption).foregroundStyle(Palette.muted)
                }
            } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                .accessibilityIdentifier("payin.notifications.lastRun")
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not linked yet").font(.subheadline.weight(.semibold))
                    Text("The automation hasn't sent HowMuch a notification on this iPhone. Set it up, or wait for your next bank alert.").font(.caption).foregroundStyle(Palette.muted)
                }
            } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                .accessibilityIdentifier("payin.notifications.lastRun")
        }
    }
    private func rotateAddress() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { payIn = try decodePayIn(await auth.api.request(path + "/pay-in/forwarding/rotate", method: "POST", body: Data("{}".utf8))); message = "Your new forwarding address is ready." }
        catch { message = error.localizedDescription }
    }
    /// Hides Gmail's code once it's been entered; it also clears by itself when the first email is forwarded.
    private func forwardingConfirmed() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { payIn = try decodePayIn(await auth.api.request(path + "/pay-in/forwarding-confirmed", method: "POST", body: Data("{}".utf8))) }
        catch { message = error.localizedDescription }
    }
    private func setPayIn(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { payIn = try decodePayIn(await auth.api.request(path + "/pay-in", method: "PATCH", body: JSONSerialization.data(withJSONObject: ["notifications_auto": enabled]))) }
        catch { message = error.localizedDescription }
    }
    @discardableResult
    private func action(_ suffix: String, method: String = "POST", body: [String: Any]? = nil) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        do {
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            status = try decode(await auth.api.request(path + suffix, method: method, body: data))
            message = "Updated your account’s payment detection."
            await auth.synchronize()
            return true
        } catch { message = error.localizedDescription; return false }
    }
    private func connect(provider: String = "gmail") async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let data = try await auth.api.request(path + (provider == "gmail" ? "/connect" : "/microsoft/connect"), method: "POST", body: Data("{}".utf8))
            let response = try JSONDecoder().decode(ConnectURL.self, from: data)
            guard let url = URL(string: response.url), url.scheme == "https", url.host == AccountAPI.base.host else { throw AccountHTTPError(status: 502, message: "The email connection link could not be verified. Try again.") }
            openURL(url)
        } catch { message = error.localizedDescription }
    }
}

private struct ConnectURL: Decodable { let url: String }
/// Mailboxes connected with an app password over IMAP.
private enum AppPasswordMailbox: String, Identifiable { case icloud, gmail; var id: String { rawValue } }
private struct DetectionStatus: Decodable {
    let provider: String?
    let providers: [String: Bool]?
    var providerName: String { provider == "icloud" ? "iCloud Mail" : provider == "microsoft" ? "Outlook" : "Gmail" }  // gmail and gmail_imap are both Gmail
    /// Snake-case decoding also renames dictionary keys, so the server's "gmail_imap" arrives as "gmailImap".
    var gmailAppPasswordReady: Bool { providers?["gmailImap"] ?? providers?["gmail_imap"] ?? false }
    let available: Bool
    let connected: Bool
    let email: String?
    let autoEnabled: Bool
    let error: String
    let rules: [DetectionRule]
    let receipts: [DetectionReceipt]
    let events: [String]
}
private struct DetectionRule: Decodable, Identifiable { let id: Int; let payer: String; let event: String }
private struct DetectionCandidate: Decodable {
    let event: String; let includesCab: Bool
    /// exact, combined (several events in one transfer), some (the oldest unpaid shifts) or short (less than the total).
    var kind: String? = nil
    var shortfall: String? = nil
    var label: String {
        switch kind {
        case "combined": return "Mark \(event) paid (one combined payment)"
        case "some": return "Mark \(event) paid"
        case "short": return "Mark \(event) paid · \(shortfall ?? "") short"
        default: return "Mark \(event) paid\(includesCab ? " · includes claims" : "")"
        }
    }
}
private struct DetectionReceipt: Decodable, Identifiable {
    let trusted: Bool?
    let id: Int
    let amount: String?
    let currency: String
    let payer: String
    let status: String
    let reason: String
    let candidates: [DetectionCandidate]
}

private struct PayInStatus: Decodable {
    struct Confirmation: Decodable { let code: String?; let link: String?; let account: String? }
    struct Forwarding: Decodable { let available: Bool; let address: String?; let confirmation: Confirmation? }
    let notificationsAuto: Bool
    let forwarding: Forwarding
}

/// Step-by-step setup for the iOS 27 Shortcuts automation that runs on bank app notifications.
/// How to forward DBS transfer alerts to the account's private HowMuch address.
struct EmailForwardingGuide: View {
    let address: String
    var body: some View {
        AppForm {
            Section(styled: "Your private address") {
                Text(address).font(.callout.monospaced()).textSelection(.enabled)
                Button("Copy address", systemImage: "doc.on.doc") { UIPasteboard.general.string = address }.rowAction()
                Text("Only forward bank alerts here. Anyone with this address could send you emails to check, so forwarded payments always wait for your OK.").font(.caption).foregroundStyle(Palette.muted)
            }
            Section(styled: "Forward one email") {
                Text("Open a DBS \u{201C}You\u{2019}ve received a transfer\u{201D} email, tap Forward, and send it to your address. It appears in Pay-in tracking within a minute.").font(.subheadline)
            }
            Section(styled: "Forward automatically (Gmail)") {
                Text("On a computer, open Gmail Settings → Forwarding and POP/IMAP → Add a forwarding address, and enter your HowMuch address exactly (it starts with pay+). Gmail sends a confirmation code, which appears in Pay-in tracking within a minute (tap Refresh at the bottom).").font(.subheadline)
                Text("Then create a filter: From ibanking.alert@dbs.com, Subject \u{201C}You\u{2019}ve received a transfer\u{201D} → Forward it to your HowMuch address.").font(.subheadline)
            }
        }.detailStyle("Email forwarding")
    }
}
