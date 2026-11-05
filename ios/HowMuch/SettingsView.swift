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
                    HStack(spacing: 14) {
                        ProfileAvatar(size: 58)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.data.settings.displayName.isEmpty ? "Your profile" : store.data.settings.displayName).font(.system(.title3, design: .rounded, weight: .bold))
                            Text("Your personal work companion").font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                    }.foregroundStyle(Palette.ink)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Card {
                settingsRow("Pay & breaks", "\(money(store.data.rules.rate, store.data.rules.currency)) / hour", "wallet.bifold") { PaySettingsView() }
                Divider()
                settingsRow("Payers", "Saved companies · bank payer names", "building.2") { PayersSettingsView() }
                Divider()
                settingsRow("Job templates", "Reusable locations · times · pay rules", "square.stack.3d.up") { JobTemplatesView() }
                Divider()
                settingsRow("Job notifications", "Upcoming · start/end · payment due", "bell.badge") { JobNotificationSettingsView() }
                Divider()
                settingsRow("Time to leave", "Routes · arrival buffer · departure alerts", "car.side.arrowtriangle.up.arrowtriangle.down") { TravelReminderSettingsView() }
                Divider()
                settingsRow("Widgets", "Calendar · next shift · events · this month", "rectangle.on.rectangle") { WidgetsSettingsView() }
                Divider()
                settingsRow("Live shift", "Lock Screen timer · confirm finish time", "timer") { LiveShiftSettingsView() }
                Divider()
                settingsRow("Apple Calendar", "Add shifts · calendar link · export", "calendar") { CalendarSettingsView() }
                Divider()
                settingsRow("Data & backups", "CSV import · export · restore", "square.and.arrow.down") { DataToolsView() }
            }
            SectionHeading(title: "Your account")
            Card {
                settingsRow("Account & sync", store.syncMessage, "person.crop.circle.badge.checkmark") { AccountSettingsView() }
                Divider()
                settingsRow("Pay-in tracking", "Bank notifications · email forwarding", "creditcard") { PaymentDetectionView() }
            }
            Text("Your Apple account owns these records. Telegram is only an optional source for importing previous shifts.")
                .font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 3)
            HStack { Text("HOWMUCH").font(.system(size: 10, weight: .bold)).tracking(2); Spacer(); Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))").font(.caption2) }.foregroundStyle(Palette.muted).padding(.vertical, 10)
        }
    }
    private func settingsRow<Destination: View>(_ title: String, _ subtitle: String, _ icon: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 18, weight: .regular)).frame(width: 38, height: 38).foregroundStyle(Palette.teal).background(Palette.mint, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(.subheadline, design: .rounded, weight: .semibold)); Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Spacer(minLength: 0); Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.foregroundStyle(Palette.ink).padding(.vertical, 2)
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
    private enum PhotoNotice: Identifiable {
        case saved, replace, remove, failure(String)
        var id: String { switch self { case .saved: return "saved"; case .replace: return "replace"; case .remove: return "remove"; case .failure: return "failure" } }
    }
    var body: some View {
        Form {
            Section("Profile photo") {
                HStack(spacing: 20) {
                    ProfileAvatar(size: 70)
                    VStack(alignment: .leading, spacing: 12) {
                        PhotosPicker("Choose photo", selection: $photo, matching: .images).buttonStyle(.borderless).disabled(loading).accessibilityIdentifier("profile.choosePhoto")
                        if store.data.settings.avatar != nil {
                            Button("Remove photo", role: .destructive) { notice = .remove }.buttonStyle(.borderless).disabled(loading).accessibilityIdentifier("profile.removePhoto")
                        }
                    }
                }.padding(.vertical, 8)
                if loading { ProgressView("Preparing photo…") }
                Text("Your current photo stays until you confirm a replacement or removal.").font(.caption).foregroundStyle(Palette.muted)
                #if DEBUG
                if CommandLine.arguments.contains("--ui-test-profile-photo") {
                    Button("Use sample photo") {
                        let data = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).jpegData(withCompressionQuality: 0.9) { context in UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 400)) }
                        prepare(data)
                    }.buttonStyle(.borderless).accessibilityIdentifier("profile.samplePhoto")
                    Button("Use unreadable photo") { prepare(Data("not a photo".utf8)) }.buttonStyle(.borderless).accessibilityIdentifier("profile.invalidPhoto")
                }
                #endif
            }
            Section("Display name") { TextField("Your name", text: $name).textContentType(.name) }
            Button("Save profile") { if store.updatePreferences({ $0.displayName = String(name.prefix(60)) }) { notice = .saved } }.rowAction().disabled(loading).accessibilityIdentifier("profile.save")
        }.detailStyle("Account settings")
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
        Form {
            Section("Pay defaults") {
                LabeledContent("Rate / hour") { TextField("Rate", text: $rate).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                LabeledContent("Currency") { TextField("SGD", text: $currency).textInputAutocapitalization(.characters).autocorrectionDisabled().multilineTextAlignment(.trailing) }
                Toggle("Overtime", isOn: $overtime)
                if overtime { TextField("After hours", text: $threshold).keyboardType(.decimalPad); TextField("Multiplier", text: $multiplier).keyboardType(.decimalPad) }
            }
            Section("Default break") { TextField("Minutes", text: $breaks).keyboardType(.numberPad); Toggle("Paid break", isOn: $paidBreak) }
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
            } header: { Text("Event rates") } footer: { Text("Defaults apply to new shifts. Existing payouts retain their saved rules.") }
        }.detailStyle("Pay & breaks").onAppear {
            rate = "\(store.data.rules.rate)"; currency = store.data.rules.currency; threshold = "\(store.data.rules.overtimeAfter ?? 8)"
            multiplier = "\(store.data.rules.overtimeMultiplier)"; overtime = store.data.rules.overtimeAfter != nil
            breaks = "\(store.data.settings.defaultBreakMinutes)"; paidBreak = store.data.settings.defaultBreakPaid
        }.alert("Defaults saved", isPresented: $saved) { Button("OK", role: .cancel) {} }
    }
    private func save() {
        guard let rate = ShiftCSV.decimal(rate), let limit = ShiftCSV.decimal(threshold), limit > 0,
              let multiple = ShiftCSV.decimal(multiplier), multiple >= 1, let minutes = Int(breaks), (0..<1440).contains(minutes) else { store.error = "Check your rate, overtime and break values."; return }
        saved = store.update { data in
            data.rules.rate = rate; data.rules.currency = currency.uppercased()
            data.rules.overtimeAfter = overtime ? limit : nil; data.rules.overtimeMultiplier = multiple
            var settings = data.settings; settings.defaultBreakMinutes = minutes; settings.defaultBreakPaid = paidBreak; data.preferences = settings
        }
    }
}

struct DataToolsView: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var importing = false
    @State private var exporting = false
    @State private var archiveImport = false
    @State private var restore = false
    @State private var document = TextFile("")
    @State private var exportType = UTType.commaSeparatedText
    @State private var legacyImport = false
    @State private var pending: TrackerData?
    @State private var message: String?
    var body: some View {
        Form {
            Section("Import & export") {
                Button("Import Telegram CSV", systemImage: "square.and.arrow.down") { archiveImport = false; importing = true }.rowAction()
                Button("Export shifts as CSV", systemImage: "tablecells") { document = TextFile(ShiftCSV.encode(store.data.shifts)); exportType = .commaSeparatedText; exporting = true }.rowAction()
                NavigationLink("Export calendar (.ics)") { CalendarSettingsView() }
                Text("Use /export in the bot for all shifts. Exact repeated rows are skipped. Imported pay stays fixed because the CSV does not contain original rate or overtime rules.").font(.caption).foregroundStyle(Palette.muted)
            }
            if store.hasLegacyImport {
                Section("Earlier iPhone records") {
                    Button("Import earlier iPhone records") { legacyImport = true }.rowAction()
                    Text("Move the unassigned records from the earlier version of HowMuch into this Apple account. This does not connect to Telegram or alter its data.").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            Section("Full backups") {
                Button("Export full archive", systemImage: "externaldrive") {
                    do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; document = TextFile(String(decoding: try encoder.encode(store.data), as: UTF8.self)); exportType = .json; exporting = true }
                    catch { store.error = error.localizedDescription }
                }.rowAction()
                Button("Restore full archive", systemImage: "arrow.counterclockwise") { archiveImport = true; importing = true }.rowAction()
                Text("Full archives preserve all local shifts, claims, paid status, due dates, profile and preferences. HowMuch CSV also preserves paid status and due dates when those columns are present. Older Telegram exports without them import as unpaid with no due date. Account credentials stay in Keychain and are never included in an archive.").font(.caption).foregroundStyle(Palette.muted)
            }
            if store.canUndo { Section { Button("Undo last change", systemImage: "arrow.uturn.backward") { store.undo() }.rowAction() } }
        }.detailStyle("Data & backups")
            .fileImporter(isPresented: $importing, allowedContentTypes: archiveImport ? [.json] : [.commaSeparatedText, .plainText]) { result in
                do {
                    let url = try result.get()
                    if archiveImport { pending = try store.readArchive(url); restore = true }
                    else { let report = try store.importCSV(url); message = "Imported \(counted(report.added, "shift")); skipped \(counted(report.skipped, "repeat"))." }
                } catch { if (error as NSError).code != NSUserCancelledError { store.error = error.localizedDescription } }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportType == .json ? "howmuch-archive" : "howmuch-shifts") { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
            .confirmationDialog("Replace all current records? Export a full archive first to keep a copy.", isPresented: $restore, titleVisibility: .visible) {
                Button("Restore \(counted(pending?.shifts.count ?? 0, "shift"))", role: .destructive) { if let pending, store.update({ $0 = pending }) { message = "Archive restored." }; pending = nil }
                Button("Cancel", role: .cancel) { pending = nil }
            }
            .confirmationDialog("Import the earlier version’s work records into this Apple account?", isPresented: $legacyImport, titleVisibility: .visible) {
                Button("Import into my account") { do { try store.importEarlierPhoneRecords(); message = "Earlier iPhone records imported." } catch { store.error = error.localizedDescription } }
            }
            .alert("Your data", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
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
                        VStack(alignment: .leading, spacing: 5) { Text(payer.displayName).font(.headline); Text(payer.bankNames.joined(separator: " · ")).font(.caption).foregroundStyle(Palette.muted) }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
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
            Form {
                Section("Company") { TextField("Company display name", text: $name).accessibilityIdentifier("payers.name") }
                Section("Bank-transfer payer names") {
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
                        HStack { VStack(alignment: .leading, spacing: 5) { Text(payer.displayName).font(.headline); Text(payer.bankNames.joined(separator: " · ")).font(.caption).foregroundStyle(Palette.muted) }; Spacer(); if selected == payer.id { Image(systemName: "checkmark").foregroundStyle(Palette.teal) } }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
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
