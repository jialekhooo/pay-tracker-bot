import SwiftUI
import PhotosUI
import ImageIO
import UserNotifications
import UniformTypeIdentifiers
import HowMuchCore

struct SettingsView: View {
    @EnvironmentObject private var store: TrackerStore
    @EnvironmentObject private var auth: AppleAccountStore
    var body: some View {
        ScreenShell(title: "Settings", subtitle: "Make HowMuch work for you.") {
            NavigationLink { ProfileSettingsView() } label: {
                Card {
                    HStack(spacing: 12) {
                        ProfileAvatar(size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.data.settings.displayName.isEmpty ? "Your profile" : store.data.settings.displayName).font(.appHeadline)
                            Text(ProfileStats(shifts: store.data.shifts, currency: store.data.rules.currency).summary(store.data.rules.currency)).font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.chevron).foregroundStyle(Palette.muted)
                    }.foregroundStyle(Palette.ink)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            group("Work") {
                settingsRow("Pay & breaks", "wallet.bifold", value: money(store.data.rules.rate, store.data.rules.currency) + "/h") { PaySettingsView() }
                Divider().padding(.leading, 44)
                settingsRow("Payers", "building.2") { PayersSettingsView() }
                Divider().padding(.leading, 44)
                settingsRow("Job templates", "square.stack.3d.up") { JobTemplatesView() }
            }
            group("Reminders") {
                settingsRow("Job notifications", "bell.badge") { JobNotificationSettingsView() }
                Divider().padding(.leading, 44)
                settingsRow("Time to leave", "car.side") { TravelReminderSettingsView() }
                Divider().padding(.leading, 44)
                settingsRow("Live shift", "timer") { LiveShiftSettingsView() }
            }
            group("Getting paid") {
                settingsRow("Pay-in tracking", "creditcard") { PaymentDetectionView() }
                Divider().padding(.leading, 44)
                settingsRow("Telegram", "paperplane") { TelegramSettingsView() }
            }
            group("Widgets & calendar") {
                settingsRow("Widgets", "rectangle.on.rectangle") { WidgetsSettingsView() }
                Divider().padding(.leading, 44)
                settingsRow("Calendar sync", "calendar") { CalendarSettingsView() }
            }
            group("Appearance") { AppearancePicker() }
            group("Privacy") { AppLockToggleRow() }
            group("Account") {
                settingsRow("Account & sync", "person.crop.circle.badge.checkmark", value: store.hasPendingChanges ? "Syncing" : nil) { AccountSettingsView() }
                Divider().padding(.leading, 44)
                settingsRow("Data & backups", "square.and.arrow.down") { DataToolsView() }
            }
            Text("HowMuch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                .font(.caption2).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
    }
    /// A small titled group of rows.
    private func group<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(Palette.muted).padding(.leading, 4)
            VStack(spacing: 0) { rows() }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line.opacity(0.7), lineWidth: 0.6).allowsHitTesting(false))
        }
    }
    private func settingsRow<Destination: View>(_ title: String, _ icon: String, value: String? = nil, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.rowIcon).frame(width: 32, height: 32).foregroundStyle(Palette.teal).background(Palette.mint, in: RoundedRectangle(cornerRadius: 9))
                Text(title).font(.system(.subheadline, design: .rounded, weight: .semibold))
                Spacer(minLength: 8)
                if let value { Text(value).font(.subheadline).foregroundStyle(Palette.muted).lineLimit(1) }
                Image(systemName: "chevron.right").font(.chevron).foregroundStyle(Palette.muted.opacity(0.7))
            }.foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct ProfileSettingsView: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var name = ""
    @State private var photo: PhotosPickerItem?
    @State private var pendingPhoto: Data?
    @State private var loading = false
    @State private var notice: PhotoNotice?
    @FocusState private var naming: Bool
    private enum PhotoNotice: Identifiable {
        case saved, replace, remove, failure(String)
        var id: String { switch self { case .saved: return "saved"; case .replace: return "replace"; case .remove: return "remove"; case .failure: return "failure" } }
    }
    var body: some View {
        let stats = ProfileStats(shifts: store.data.shifts, currency: store.data.rules.currency)
        let pet = store.petProgress()
        let petName = store.petPreferences.displayName
        ScrollView {
            VStack(spacing: 18) {
                // Photo and name
                VStack(spacing: 14) {
                    ProfileAvatar(size: 108)
                        .overlay(Circle().stroke(Palette.surface, lineWidth: 4))
                        .shadow(color: Palette.teal.opacity(0.18), radius: 14, y: 6)
                        .overlay(alignment: .bottomTrailing) {
                            PhotosPicker(selection: $photo, matching: .images) {
                                Image(systemName: "camera.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 36, height: 36).background(Palette.accent, in: Circle()).overlay(Circle().stroke(Palette.surface, lineWidth: 3))
                            }.buttonStyle(.plain).disabled(loading).accessibilityLabel("Choose photo").accessibilityIdentifier("profile.choosePhoto")
                        }
                    if loading { ProgressView("Preparing photo…").font(.caption) }
                    HStack(spacing: 6) {
                        // The field hugs the name itself, so the pencil sits right beside it.
                        Text(name.isEmpty ? "Your name" : name).font(.appTitle).lineLimit(1)
                            .padding(.horizontal, 2).hidden()
                            .overlay {
                                TextField("Your name", text: $name).textContentType(.name).focused($naming).submitLabel(.done)
                                    .font(.appTitle).multilineTextAlignment(.center)
                                    .onSubmit(save).accessibilityIdentifier("profile.name")
                            }
                        if !naming { Image(systemName: "pencil").font(.callout.weight(.semibold)).foregroundStyle(Palette.muted).onTapGesture { naming = true } }
                    }.foregroundStyle(Palette.ink).frame(maxWidth: .infinity)
                    HStack(spacing: 8) {
                    if store.developer {
                        Label("Developer", systemImage: "hammer.circle.fill").font(.caption.weight(.bold)).foregroundStyle(Color(red: 0.3, green: 1, blue: 0.55))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color(red: 0.08, green: 0.11, blue: 0.11), in: Capsule())
                            .accessibilityLabel("Developer: builds HowMuch").accessibilityIdentifier("profile.developer")
                    }
                    if store.pioneer {
                        Label("Pioneer", systemImage: "star.circle.fill").font(.caption.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(LinearGradient(colors: [Color(red: 0.16, green: 0.62, blue: 0.5), Palette.accent], startPoint: .leading, endPoint: .trailing), in: Capsule())
                            .accessibilityLabel("Pioneer: joined HowMuch before launch").accessibilityIdentifier("profile.pioneer")
                    }
                    }
                    Text(stats.since.map { "Tracking pay since \($0)" } ?? "Add your first shift to start your story").font(.subheadline).foregroundStyle(Palette.muted)
                    if store.data.settings.avatar != nil {
                        Button("Remove photo", role: .destructive) { notice = .remove }.font(.caption.weight(.semibold)).buttonStyle(.borderless).disabled(loading).accessibilityIdentifier("profile.removePhoto")
                    }
                    #if DEBUG
                    if CommandLine.arguments.contains("--ui-test-profile-photo") {
                        HStack {
                            Button("Use sample photo") {
                                let data = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).jpegData(withCompressionQuality: 0.9) { context in UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 400)) }
                                prepare(data)
                            }.accessibilityIdentifier("profile.samplePhoto")
                            Button("Use unreadable photo") { prepare(Data("not a photo".utf8)) }.accessibilityIdentifier("profile.invalidPhoto")
                        }.font(.caption).buttonStyle(.borderless)
                    }
                    #endif
                }.frame(maxWidth: .infinity).padding(.top, 8)

                // At a glance
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    statTile("banknote", money(stats.earned, store.data.rules.currency), "Earned so far")
                    statTile("clock", hoursLabel(stats.hours), "Hours worked")
                    statTile("briefcase", "\(stats.shifts)", stats.shifts == 1 ? "Shift worked" : "Shifts worked")
                    statTile("flame", "\(pet.bestStreakWeeks) wk", "Best streak")
                }

                if stats.topJob != nil || stats.topPlace != nil {
                    VStack(spacing: 0) {
                        if let job = stats.topJob { favourite("star", "Most worked job", job) }
                        if stats.topJob != nil && stats.topPlace != nil { Divider().padding(.leading, 44) }
                        if let place = stats.topPlace { favourite("mappin.and.ellipse", "Favourite spot", place) }
                    }.padding(.horizontal, 14).padding(.vertical, 4)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
                }

                // Penny
                NavigationLink { PetDetailView() } label: {
                    HStack(spacing: 12) {
                        PetStage(pet: pet, outfit: petOutfit(store.petCloset, pet), name: petName, size: 52, corner: 14).allowsHitTesting(false)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(petName) · Level \(pet.level)").font(.system(.subheadline, design: .rounded, weight: .semibold))
                            Text("\(pet.achievements.filter(\.earned).count) of \(pet.achievements.count) badges earned").font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.chevron).foregroundStyle(Palette.muted)
                    }.foregroundStyle(Palette.ink).padding(14).frame(maxWidth: .infinity)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18)).contentShape(Rectangle())
                }.buttonStyle(.plain)

                Button("Save profile", action: save).primaryButton().disabled(loading).accessibilityIdentifier("profile.save")
            }.padding(.horizontal, 20).padding(.bottom, 32)
        }.detailStyle("Profile")
            .onAppear { name = store.data.settings.displayName }
            .task(id: photo) {
                guard let item = photo else { return }
                loading = true
                defer { if photo == item { loading = false } }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw TrackerError.invalid("This photo could not be loaded. Your current photo is kept.") }
                    try Task.checkCancellation()
                    prepare(data)
                } catch is CancellationError {} catch { if !Task.isCancelled { notice = .failure("This photo could not be loaded. Your current photo is kept. Try another photo.") } }
            }
            .alert(item: $notice) { item in
                switch item {
                case .saved: return Alert(title: Text("Profile saved"), dismissButton: .default(Text("OK")))
                case .replace: return Alert(title: Text("Use selected profile photo?"), message: Text("Your current photo will be replaced only if you confirm."), primaryButton: .default(Text("Use photo")) {
                    if let data = pendingPhoto, !store.updatePreferences({ $0.avatar = data }) { notice = .failure(store.error ?? "Your photo could not be saved.") }
                    pendingPhoto = nil; photo = nil
                }, secondaryButton: .cancel { pendingPhoto = nil; photo = nil })
                case .remove: return Alert(title: Text("Remove profile photo?"), message: Text("Your initials will appear instead. Choosing a new photo never removes the current photo automatically."), primaryButton: .destructive(Text("Remove photo")) {
                    if !store.updatePreferences({ $0.avatar = nil }) { notice = .failure(store.error ?? "Your photo could not be updated.") }
                }, secondaryButton: .cancel())
                case .failure(let message): return Alert(title: Text("Photo kept"), message: Text(message), dismissButton: .default(Text("OK")) { photo = nil; pendingPhoto = nil })
                }
            }
    }
    private func save() {
        naming = false
        if store.updatePreferences({ $0.displayName = String(name.trimmingCharacters(in: .whitespaces).prefix(60)) }) { notice = .saved }
    }
    private func hoursLabel(_ hours: Decimal) -> String {
        let value = NSDecimalNumber(decimal: hours).doubleValue
        return value.rounded() == value ? "\(Int(value))h" : String(format: "%.1fh", value)
    }
    private func statTile(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).scaledFont(14, relativeTo: .subheadline, weight: .semibold).foregroundStyle(Palette.teal)
            Text(value).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(Palette.muted)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
    }
    private func favourite(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.rowIcon).frame(width: 32, height: 32).foregroundStyle(Palette.teal).background(Palette.mint, in: RoundedRectangle(cornerRadius: 9))
            Text(title).font(.subheadline).foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Text(value).font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
        }.frame(minHeight: 48)
    }
    private func prepare(_ data: Data) {
        guard data.count <= 30_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            notice = .failure("Choose a readable image smaller than 30 MB. Your current photo is kept."); return
        }
        let image = UIImage(cgImage: thumbnail)
        let output = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240)).image { _ in
            let scale = max(240 / image.size.width, 240 / image.size.height)
            image.draw(in: CGRect(x: (240 - image.size.width * scale) / 2, y: (240 - image.size.height * scale) / 2, width: image.size.width * scale, height: image.size.height * scale))
        }
        guard let jpeg = output.jpegData(compressionQuality: 0.85), UIImage(data: jpeg) != nil else { notice = .failure("The selected image could not be prepared. Your current photo is kept."); return }
        pendingPhoto = jpeg; notice = .replace
    }
}

struct PaySettingsView: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var rate = "15"
    @State private var currency = "SGD"
    @State private var threshold = "8"
    @State private var multiplier = "1.5"
    @State private var breaks = "0"
    @State private var overtime = false
    @State private var paidBreak = false
    @State private var saved = false
    @State private var event = ""
    @State private var eventRate = ""
    var body: some View {
        AppForm {
            Section(styled: "Pay defaults") {
                LabeledContent("Rate / hour") { TextField("Rate", text: $rate).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                LabeledContent("Currency") { TextField("SGD", text: $currency).textInputAutocapitalization(.characters).autocorrectionDisabled().multilineTextAlignment(.trailing) }
                Toggle("Overtime", isOn: $overtime)
                if overtime { TextField("After hours", text: $threshold).keyboardType(.decimalPad); TextField("Multiplier", text: $multiplier).keyboardType(.decimalPad) }
            }
            Section(styled: "Default break") { TextField("Minutes", text: $breaks).keyboardType(.numberPad); Toggle("Paid break", isOn: $paidBreak) }
            Button("Save defaults") { save() }.rowAction()
            Section {
                ForEach(store.data.settings.eventRates.keys.sorted(), id: \.self) { key in
                    HStack { Text(key); Spacer(); Text(money(store.data.settings.eventRates[key]!, store.data.rules.currency)); Button("Remove", systemImage: "minus.circle", role: .destructive) { store.updatePreferences { $0.eventRates.removeValue(forKey: key) } }.labelStyle(.iconOnly).iconAction() }
                }
                TextField("Event name", text: $event)
                TextField("Event hourly rate", text: $eventRate).keyboardType(.decimalPad)
                Button("Save event rate") {
                    guard !event.trimmingCharacters(in: .whitespaces).isEmpty, let amount = ShiftCSV.decimal(eventRate) else { store.error = "Enter an event name and a valid rate."; return }
                    if store.updatePreferences({ $0.eventRates[event.trimmingCharacters(in: .whitespaces).lowercased()] = amount }) { event = ""; eventRate = "" }
                }.rowAction()
            } header: { FormHeader("Event rates") } footer: { Text("Defaults apply to new shifts. Existing payouts retain their saved rules.").formFootnote() }
        }.detailStyle("Pay & breaks").onAppear {
            rate = "\(store.data.rules.rate)"; currency = store.data.rules.currency; threshold = "\(store.data.rules.overtimeAfter ?? 8)"
            multiplier = "\(store.data.rules.overtimeMultiplier)"; overtime = store.data.rules.overtimeAfter != nil
            breaks = "\(store.data.settings.defaultBreakMinutes)"; paidBreak = store.data.settings.defaultBreakPaid
        }.alert("Defaults saved", isPresented: $saved) { Button("OK", role: .cancel) {} }
            // Leaving with changes saves them (quietly), so pressing Back never loses your edits.
            .onDisappear { if changed { save(quietly: true) } }
    }
    private var changed: Bool {
        guard let value = ShiftCSV.decimal(rate) else { return false }
        return value != store.data.rules.rate || currency.uppercased() != store.data.rules.currency
            || overtime != (store.data.rules.overtimeAfter != nil) || (overtime && ShiftCSV.decimal(threshold) != store.data.rules.overtimeAfter)
            || ShiftCSV.decimal(multiplier) != store.data.rules.overtimeMultiplier
            || Int(breaks) != store.data.settings.defaultBreakMinutes || paidBreak != store.data.settings.defaultBreakPaid
    }
    private func save(quietly: Bool = false) {
        guard let rate = ShiftCSV.decimal(rate), let limit = ShiftCSV.decimal(threshold), limit > 0,
              let multiple = ShiftCSV.decimal(multiplier), multiple >= 1, let minutes = Int(breaks), (0..<1440).contains(minutes) else { store.error = "Check your rate, overtime and break values."; return }
        let ok = store.update { data in
            data.rules.rate = rate; data.rules.currency = currency.uppercased()
            data.rules.overtimeAfter = overtime ? limit : nil; data.rules.overtimeMultiplier = multiple
            var settings = data.settings; settings.defaultBreakMinutes = minutes; settings.defaultBreakPaid = paidBreak; data.preferences = settings
        }
        if !quietly { saved = ok }
    }
}

struct DataToolsView: View {
    @EnvironmentObject private var store: TrackerStore
    @EnvironmentObject private var auth: AppleAccountStore
    @State private var importing = false
    @State private var exporting = false
    @State private var archiveImport = false
    @State private var restore = false
    @State private var document = BackupFile()
    @State private var exportType = UTType.commaSeparatedText
    @State private var legacyImport = false
    @State private var pending: TrackerData?
    @State private var pendingReceipts: [UUID: Data] = [:]
    @State private var working = false
    @State private var progress = ""
    @State private var operation: Task<Void, Never>?
    @State private var exportNote: String?
    @State private var message: String?
    var body: some View {
        AppForm {
            Section(styled: "Import & export") {
                Button("Import Telegram CSV", systemImage: "square.and.arrow.down") { archiveImport = false; importing = true }.rowAction()
                Link(destination: TelegramBot.url) { Label("Open \(TelegramBot.handle) to export with /export", systemImage: "paperplane") }
                    .rowAction().accessibilityIdentifier("data.telegramBot")
                Button("Export shifts as CSV", systemImage: "tablecells") { document = BackupFile(Data(ShiftCSV.encode(store.data.shifts).utf8)); exportType = .commaSeparatedText; exporting = true }.rowAction()
                NavigationLink("Export calendar (.ics)") { CalendarSettingsView() }
                Text("Use /export in the bot for all shifts. Exact repeated rows are skipped. Imported pay stays fixed because the CSV does not contain original rate or overtime rules.").font(.caption).foregroundStyle(Palette.muted)
            }
            if store.hasLegacyImport {
                Section(styled: "Earlier iPhone records") {
                    Button("Import earlier iPhone records") { legacyImport = true }.rowAction()
                    Text("Move the unassigned records from the earlier version of HowMuch into this Apple account. This does not connect to Telegram or alter its data.").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            Section(styled: "Full backups") {
                Button("Export full archive", systemImage: "externaldrive") { run { try await exportBackup() } }.rowAction()
                Button("Restore full archive", systemImage: "arrow.counterclockwise") { archiveImport = true; importing = true }.rowAction()
                Text("ZIP backups include shifts, claims, receipt photos, profile and preferences. Keep the ZIP private: it contains your work and receipt details. Earlier JSON archives can still be restored, but contain no receipt photos. Account credentials are never included.").font(.caption).foregroundStyle(Palette.muted)
            }
            if store.canUndo { Section { Button("Undo last change", systemImage: "arrow.uturn.backward") { store.undo() }.rowAction() } }
        }.disabled(working).detailStyle("Data & backups")
            .overlay {
                if working {
                    VStack(spacing: 16) {
                        ProgressView(progress)
                        Button("Cancel") { operation?.cancel() }
                    }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .onDisappear { operation?.cancel() }
            .fileImporter(isPresented: $importing, allowedContentTypes: archiveImport ? [.zip, .json] : [.commaSeparatedText, .plainText]) { result in
                do {
                    let url = try result.get()
                    if archiveImport {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= AccountBackup.maximumBytes else { throw TrackerError.invalid("Choose a backup smaller than 110 MB.") }
                        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                        guard bytes.count <= AccountBackup.maximumBytes else { throw TrackerError.invalid("Choose a backup smaller than 110 MB.") }
                        run {
                            progress = "Checking backup…"
                            if bytes.starts(with: [0x50, 0x4b]) {
                                let backup = try await Task.detached { try AccountBackup.decode(bytes) }.value
                                try checkAccount()
                                pending = backup.data; pendingReceipts = backup.receipts
                            } else {
                                guard bytes.count <= 10_000_000 else { throw TrackerError.invalid("Choose a JSON archive smaller than 10 MB.") }
                                let records = try JSONDecoder().decode(TrackerData.self, from: bytes)
                                try records.validate(); pending = records; pendingReceipts = [:]
                            }
                            try checkAccount(); restore = true
                        }
                    }
                    else { let report = try store.importCSV(url); message = "Imported \(counted(report.added, "shift")); skipped \(counted(report.skipped, "repeat"))." }
                } catch { if (error as NSError).code != NSUserCancelledError { store.error = error.localizedDescription } }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportType == .zip ? "howmuch-backup" : "howmuch-shifts") { result in
                if case .failure(let error) = result { store.error = error.localizedDescription } else if let exportNote { message = exportNote }
                exportNote = nil
            }
            .confirmationDialog("Replace all current records? Export a full archive first to keep a copy.", isPresented: $restore, titleVisibility: .visible) {
                Button("Restore \(counted(pending?.shifts.count ?? 0, "shift"))", role: .destructive) { run { try await restoreBackup() } }
                Button("Cancel", role: .cancel) { pending = nil; pendingReceipts = [:] }
            }
            .confirmationDialog("Import the earlier version’s work records into this Apple account?", isPresented: $legacyImport, titleVisibility: .visible) {
                Button("Import into my account") { do { try store.importEarlierPhoneRecords(); message = "Earlier iPhone records imported." } catch { store.error = error.localizedDescription } }
            }
            .alert("Your data", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
    }

    private func checkAccount() throws {
        try Task.checkCancellation()
        guard auth.account?.id.lowercased() == store.accountID.lowercased(), auth.tracker === store else {
            throw TrackerError.invalid("The signed-in account changed. Open backups again for your current account.")
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        operation = Task { @MainActor in
            defer { working = false; progress = ""; operation = nil }
            do { try await action() }
            catch is CancellationError { }
            catch { store.error = error.localizedDescription }
        }
    }

    private func exportBackup() async throws {
        try checkAccount()
        let records = store.data
        let ids = Set(records.claims.compactMap(\.receiptID) + (records.expenses ?? []).compactMap(\.receiptID))
        guard ids.count <= 2000 else { throw TrackerError.invalid("A ZIP backup supports up to 2,000 receipt photos.") }
        var photos: [UUID: Data] = [:], missing: Set<UUID> = []
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            progress = "Saving receipt \(photos.count + missing.count + 1) of \(ids.count)…"
            // A photo the account no longer has must not block the whole backup.
            do { photos[id] = try await auth.api.request("/v1/receipts/" + id.uuidString) }
            catch let error as AccountHTTPError where error.status == 404 { missing.insert(id) }
            try checkAccount()
        }
        progress = "Preparing backup…"
        let complete = AccountBackup.removingReceipts(missing, from: records), saved = photos
        let bytes = try await Task.detached { try AccountBackup(data: complete, receipts: saved).encoded() }.value
        try checkAccount()
        exportNote = missing.isEmpty ? nil : "Backup saved without \(counted(missing.count, "receipt photo")) your account no longer has."
        document = BackupFile(bytes); exportType = .zip; exporting = true
    }

    private func restoreBackup() async throws {
        try checkAccount()
        guard var records = pending else { return }
        let owner = store.accountID
        var uploaded: [UUID] = []
        do {
            let baseline = store.data
            var replacement: [UUID: UUID] = [:]
            for (id, bytes) in pendingReceipts.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                progress = "Restoring receipt \(replacement.count + 1) of \(pendingReceipts.count)…"
                // Reuse an identical attachment on this account; otherwise upload with a
                // fresh ID so restoring into a different account never references its old owner.
                var existing: Data?
                do { existing = try await auth.api.request("/v1/receipts/" + id.uuidString) }
                catch let error as AccountHTTPError where error.status == 404 { }
                try checkAccount()
                if existing == bytes { replacement[id] = id; continue }
                let newID = UUID(); uploaded.append(newID)
                _ = try await auth.api.request("/v1/receipts/" + newID.uuidString + "/restore", method: "PUT", body: bytes, contentType: "image/jpeg")
                try checkAccount(); replacement[id] = newID
            }
            if !pendingReceipts.isEmpty {
                records = try AccountBackup(data: records, receipts: pendingReceipts).restoringReceipts(replacement)
            }
            try checkAccount()
            guard store.data == baseline else { throw TrackerError.invalid("Your records changed during restore. Review them and try the restore again.") }
            guard store.update({ $0 = records }) else { throw TrackerError.invalid(store.error ?? "Could not save the restored records.") }
            message = pendingReceipts.isEmpty ? "Archive restored. Earlier JSON archives do not include receipt photos." : "Backup and receipt photos restored."
            pending = nil; pendingReceipts = [:]
        } catch {
            // Failed/cancelled restores leave current records alone and remove only
            // newly uploaded copies, never attachments reused from existing claims.
            await Task { @MainActor in
                for id in uploaded {
                    guard auth.account?.id.lowercased() == owner.lowercased() else { break }
                    do { _ = try await auth.api.request("/v1/receipts/" + id.uuidString, method: "DELETE") }
                    catch { break } // Unreferenced uploads also have server-side garbage collection.
                }
            }.value
            throw error
        }
    }

}

struct PayersSettingsView: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var editing: SavedPayer?
    @State private var adding = false
    @State private var deleting: SavedPayer?
    @State private var search = ""
    private var payers: [SavedPayer] { (store.data.settings.savedPayers ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bankNames.contains { $0.localizedCaseInsensitiveContains(search) } }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    var body: some View {
        List {
            Section { Text("Save each company once, then choose who pays for an event. Bank names must match the payer shown in your DBS alert; you can save multiple names for one company.").font(.caption).foregroundStyle(Palette.muted) }
            Section {
                Button("Add payer", systemImage: "plus") { adding = true }.rowAction().accessibilityIdentifier("payers.add")
                ForEach(payers) { payer in
                    Button { editing = payer } label: {
                        VStack(alignment: .leading, spacing: 5) { Text(payer.displayName).font(.appHeadline); Text(payer.bankNames.joined(separator: " · ")).font(.caption).foregroundStyle(Palette.muted) }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("payers.item.\(payer.id)")
                        .swipeActions { Button("Remove", role: .destructive) { deleting = payer } }
                }
                if payers.isEmpty { Text(search.isEmpty ? "No saved payers yet." : "No matching payers.").foregroundStyle(Palette.muted) }
            }
            if store.canUndo { Button("Undo last change", systemImage: "arrow.uturn.backward") { store.undo() } }
        }.detailStyle("Payers").searchable(text: $search, prompt: "Find a company or bank name")
            .sheet(isPresented: $adding) { SavedPayerEditor() }
            .sheet(item: $editing) { payer in SavedPayerEditor(existing: payer) }
            .alert("Remove saved payer?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Remove", role: .destructive) { if let payer = deleting { store.updatePreferences { $0.removePayer(payer.id) } }; deleting = nil }
            } message: { Text("This clears the payer from linked events and templates. Your shifts and payment history stay saved. You can undo this change.") }
    }
}

struct SavedPayerEditor: View {
    @EnvironmentObject private var store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    var existing: SavedPayer?
    var onSave: ((UUID) -> Void)?
    @State private var name = ""
    @State private var bankNames = ""
    @State private var error = ""
    var body: some View {
        NavigationStack {
            AppForm {
                Section(styled: "Company") { TextField("Company display name", text: $name).accessibilityIdentifier("payers.name") }
                Section(styled: "Bank-transfer payer names") {
                    TextField("Exact payer name · one per line", text: $bankNames, axis: .vertical).lineLimit(3...8).textInputAutocapitalization(.characters).autocorrectionDisabled().accessibilityIdentifier("payers.bankNames")
                    Text("Enter each exact name shown after ‘From’ in your DBS alert, one per line. These names are used for matching; the company display name is for you.").font(.caption).foregroundStyle(Palette.muted)
                }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.red) } }
            }.scrollDismissesKeyboard(.interactively).navigationTitle(existing == nil ? "Add payer" : "Edit payer")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        let aliases = bankNames.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        let payer = SavedPayer(id: existing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), bankNames: aliases)
                        if store.updatePreferences({ $0.savePayer(payer) }) { onSave?(payer.id); dismiss() } else { error = store.error ?? "This payer could not be saved." }
                    }.accessibilityIdentifier("payers.save") }
                }
                .onAppear { if let existing { name = existing.name; bankNames = existing.bankNames.joined(separator: "\n") } }
        }
    }
}

struct PayerPickerView: View {
    @EnvironmentObject private var store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    var selected: UUID?
    var onSelect: (UUID?) -> Void
    @State private var search = ""
    @State private var adding = false
    private var payers: [SavedPayer] { (store.data.settings.savedPayers ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bankNames.contains { $0.localizedCaseInsensitiveContains(search) } }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    var body: some View {
        NavigationStack {
            List {
                Button("Choose payer later") { onSelect(nil); dismiss() }.rowAction()
                ForEach(payers) { payer in
                    Button { onSelect(payer.id); dismiss() } label: {
                        HStack { VStack(alignment: .leading, spacing: 5) { Text(payer.displayName).font(.appHeadline); Text(payer.bankNames.joined(separator: " · ")).font(.caption).foregroundStyle(Palette.muted) }; Spacer(); if selected == payer.id { Image(systemName: "checkmark").foregroundStyle(Palette.teal) } }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("payer.select.\(payer.name)")
                }
                Button("Add new payer", systemImage: "plus") { adding = true }.rowAction().accessibilityIdentifier("payer.addNew")
            }.navigationTitle("Paid by").searchable(text: $search, prompt: "Search saved payers")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .sheet(isPresented: $adding) { SavedPayerEditor { id in onSelect(id); dismiss() } }
        }
    }
}

struct EventPayerRow: View {
    @EnvironmentObject private var store: TrackerStore
    var event: String
    @State private var selecting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paid by").font(.caption).foregroundStyle(Palette.muted)
            Button { selecting = true } label: {
                HStack { Text(store.data.settings.payer(for: event)?.displayName ?? "Choose payer"); Spacer(); Image(systemName: "chevron.down").font(.caption) }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Palette.teal).accessibilityIdentifier("event.payer")
            Text("Shared by every shift in this event. Manage company bank names in Settings → Payers.").font(.caption2).foregroundStyle(Palette.muted)
        }.sheet(isPresented: $selecting) { PayerPickerView(selected: store.data.settings.payer(for: event)?.id) { id in store.updatePreferences { $0.assignPayer(id, to: event) } } }
    }
}

/// A few friendly numbers about the work so far, for the profile.
struct ProfileStats {
    var shifts = 0
    var hours: Decimal = 0
    var earned: Decimal = 0
    var since: String?
    var topJob: String?
    var topPlace: String?
    init(shifts all: [Shift], currency: String, now: Date = Date()) {
        // Same rules as the Overview card: only time already worked, in one currency.
        let split = EarningsBreakdown(shifts: all.filter { $0.currency == currency }, now: now)
        let worked = all.filter { $0.endDate <= now }
        shifts = split.shiftsWorked
        hours = split.hoursWorked
        earned = split.earned
        if let first = worked.map(\.startDate).min() { since = first.formatted(.dateTime.month(.wide).year()) }
        func mostCommon(_ values: [String]) -> String? {
            let counts = Dictionary(values.map { ($0.trimmingCharacters(in: .whitespaces), 1) }.filter { !$0.0.isEmpty }, uniquingKeysWith: +)
            return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        }
        topJob = mostCommon(worked.map(\.event))
        topPlace = mostCommon(worked.map(\.location))
    }
    func summary(_ currency: String) -> String {
        shifts == 0 ? "Your profile" : "\(shifts) \(shifts == 1 ? "shift" : "shifts") · \(money(earned, currency)) earned"
    }
}

/// The HowMuch Telegram bot.
enum TelegramBot {
    static let handle = "@paytracker1_bot"
    static let url = URL(string: "https://t.me/paytracker1_bot")!
}

private struct TelegramStatus: Decodable { let linked: Bool; let username: String }
private struct TelegramLinkCode: Decodable { let url: String }

/// Link the HowMuch bot in Telegram with this account, and a guide to what the bot can do.
struct TelegramSettingsView: View {
    @EnvironmentObject private var auth: AppleAccountStore
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: TelegramStatus?
    @State private var busy = false
    @State private var message = ""
    @State private var confirmingUnlink = false

    var body: some View {
        AppForm {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane.fill").font(.title3).frame(width: 40, height: 40).foregroundStyle(.white)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TelegramBot.handle).font(.headline)
                        Text(statusText).font(.subheadline).foregroundStyle(status?.linked == true ? Palette.teal : Palette.muted)
                            .accessibilityIdentifier("telegram.status")
                    }
                }.padding(.vertical, 4)
                if status?.linked == true {
                    Link(destination: TelegramBot.url) { Label("Open \(TelegramBot.handle)", systemImage: "arrow.up.right.square") }
                        .accessibilityIdentifier("telegram.open")
                    Button("Unlink Telegram", systemImage: "link.badge.plus", role: .destructive) { confirmingUnlink = true }
                        .accessibilityIdentifier("telegram.unlink")
                } else {
                    Button(busy ? "Opening Telegram…" : "Link Telegram", systemImage: "link") { Task { await link() } }
                        .primaryButton().disabled(busy || status == nil)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).accessibilityIdentifier("telegram.link")
                    Text("Opens \(TelegramBot.handle) in Telegram. Tap Start there to finish linking.").font(.caption).foregroundStyle(Palette.muted)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("telegram.message") }
            } header: { FormHeader("Telegram") }

            Section(styled: "What you can do in Telegram") {
                guideRow("text.bubble", "Send a shift as a message", "Wedding gig 12/8 6pm-11pm @ MBS\nIt lands in HowMuch with your rates, breaks, overtime and due date.")
                guideRow("list.bullet", "Send several at once", "One shift per line. Add 25/h or $200 flat to set the pay for that shift.")
                guideRow("banknote", "/owed", "What you're still waiting to be paid.")
                guideRow("calendar", "/upcoming", "What you're booked for in the next two weeks.")
                guideRow("link", "/unlink", "Stop sending shifts to the app. You can also unlink here.")
            }
            Section(styled: "How to link") {
                guideRow("1.circle", "Tap Link Telegram", "Telegram opens a chat with \(TelegramBot.handle).")
                guideRow("2.circle", "Tap Start in Telegram", "The bot confirms it's linked to your HowMuch account.")
                guideRow("3.circle", "Send your shifts", "They show up here, on every device you're signed in to.")
                Text("The link only lets the bot add shifts and read what's owed and upcoming. It can't see your bank emails or change anything else. Each link code works once and expires after 15 minutes.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            Section(styled: "Used the bot before linking?") {
                Text("Shifts you logged in the bot before linking stay in the bot. To bring them over, send /export to the bot, save the CSV, then use Settings → Data & backups → Import Telegram CSV.")
                    .font(.subheadline).foregroundStyle(Palette.ink)
            }
        }
        .detailStyle("Telegram")
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
        .confirmationDialog("Unlink Telegram?", isPresented: $confirmingUnlink, titleVisibility: .visible) {
            Button("Unlink", role: .destructive) { Task { await unlink() } }
        } message: { Text("Shifts already added stay in HowMuch. New messages to the bot won't reach the app.") }
    }

    private var statusText: String {
        guard let status else { return "Checking…" }
        if !status.linked { return "Not linked" }
        return status.username.isEmpty ? "Linked" : "Linked to @\(status.username)"
    }

    private func guideRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 26).foregroundStyle(Palette.teal)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(detail).font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 2).accessibilityElement(children: .combine)
    }

    private func load() async {
        do { status = try JSONDecoder().decode(TelegramStatus.self, from: await auth.api.request("/v1/telegram")); message = "" }
        catch { message = error.localizedDescription }
    }

    private func link() async {
        busy = true; defer { busy = false }; message = ""
        do {
            let made = try JSONDecoder().decode(TelegramLinkCode.self, from: await auth.api.request("/v1/telegram/link", method: "POST"))
            guard let url = URL(string: made.url) else { return }
            openURL(url)
        } catch { message = error.localizedDescription }
    }

    private func unlink() async {
        do { status = try JSONDecoder().decode(TelegramStatus.self, from: await auth.api.request("/v1/telegram", method: "DELETE")) }
        catch { message = error.localizedDescription }
    }
}

/// Settings → Appearance: follow the iPhone, or always light or dark.
struct AppearancePicker: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.segmented).accessibilityIdentifier("settings.appearance")
            Text(caption).font(.caption).foregroundStyle(Palette.muted).accessibilityIdentifier("settings.appearanceCaption")
        }.padding(.vertical, 10)
    }
    /// Describes the option that's chosen.
    private var caption: String {
        switch AppAppearance(rawValue: appearance) ?? .system {
        case .system: "Switches between light and dark with your iPhone."
        case .light: "Always light, even when your iPhone is in Dark Mode."
        case .dark: "Always dark, even when your iPhone is in Light Mode."
        }
    }
}
