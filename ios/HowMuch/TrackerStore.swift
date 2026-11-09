import Foundation
import SwiftUI
import CryptoKit
import HowMuchCore

@MainActor
final class TrackerStore: ObservableObject {
    @Published private(set) var data = TrackerData()
    @Published var error: String?
    @Published private(set) var canUndo = false
    @Published private(set) var reminderMessage = ""
    let isPreview: Bool = {
        #if DEBUG
        return CommandLine.arguments.contains("--preview")
        #else
        return false
        #endif
    }()
    @Published var widgetMessage = "Open HowMuch to refresh widget data."
    private var publishesWidgets = false
    let accountID: String
    private let suppressNotifications: Bool
    @Published var syncMessage = "Saved on this phone"
    @Published var usesRemotePush = false
    /// The account was made before HowMuch's official launch. The server decides; remembered here for offline use.
    @Published private(set) var pioneer = false
    /// One of the people building HowMuch: a Developer badge and every Penny skin. The server decides.
    @Published private(set) var developer = false
    /// Penny items unlocked with gift codes. The server decides; remembered here for offline use.
    @Published private(set) var petUnlocks: Set<String> = []
    private(set) var lastSyncedData: TrackerData?
    private(set) var syncRevision = 0
    var hasPendingChanges: Bool { lastSyncedData.map { $0 != data } ?? (data != TrackerData()) }
    var onChange: (() -> Void)?
    private var previous: TrackerData?
    private var undoBaseline: TrackerData?
    private var reminderTask: Task<Void, Never>?
    private var writable = true
    /// False when the saved file couldn't be read (for example while the iPhone is locked); never sync over it.
    var isWritable: Bool { writable }
    private let url: URL

    func setPioneer(_ value: Bool?) {
        guard let value, value != pioneer else { return }
        pioneer = value
        UserDefaults.standard.set(value, forKey: "pioneer.\(accountID)")
    }
    func setDeveloper(_ value: Bool?) {
        guard let value, value != developer else { return }
        developer = value
        UserDefaults.standard.set(value, forKey: "developer.\(accountID)")
    }
    func setPetUnlocks(_ value: [String]?) {
        guard let value, Set(value) != petUnlocks else { return }
        petUnlocks = Set(value)
        UserDefaults.standard.set(value, forKey: "petUnlocks.\(accountID)")
    }
    func petProgress(now: Date = Date()) -> PetProgress { PetProgress(shifts: data.shifts, now: now, pioneer: pioneer, developer: developer, unlocked: petUnlocks, currency: data.rules.currency, bonusCoins: helloCoins) }
    /// Coins from saying hi to friends and being said hi to.
    @Published private(set) var helloCoins = 0
    func setHelloCoins(_ value: Int?) {
        guard let value, value != helloCoins else { return }
        helloCoins = value
        UserDefaults.standard.set(value, forKey: "helloCoins.\(accountID)")
    }

    init(accountID: String, suppressNotifications: Bool = false) {
        self.accountID = UUID(uuidString: accountID)?.uuidString.lowercased() ?? "invalid"
        self.suppressNotifications = suppressNotifications
        let folder = URL.applicationSupportDirectory.appending(path: "HowMuch/accounts/\(self.accountID)", directoryHint: .isDirectory)
        url = folder.appending(path: "tracker.json")
        guard self.accountID != "invalid" else { writable = false; error = "The account identity is invalid."; return }
        pioneer = UserDefaults.standard.bool(forKey: "pioneer.\(self.accountID)")
        developer = UserDefaults.standard.bool(forKey: "developer.\(self.accountID)")
        petUnlocks = Set(UserDefaults.standard.stringArray(forKey: "petUnlocks.\(self.accountID)") ?? [])
        helloCoins = UserDefaults.standard.integer(forKey: "helloCoins.\(self.accountID)")
        if isPreview {
            #if DEBUG
            pioneer = !CommandLine.arguments.contains("--ui-test-not-pioneer")
            developer = CommandLine.arguments.contains("--ui-test-developer")
            #endif
            do { data = try Self.previewData() } catch { self.error = error.localizedDescription }
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let saved = try JSONDecoder().decode(TrackerData.self, from: Data(contentsOf: url))
                try saved.validate()
                data = saved
            }
            let metadataURL = folder.appending(path: "sync.json")
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                let metadata = try JSONDecoder().decode(SyncMetadata.self, from: Data(contentsOf: metadataURL))
                try metadata.data.validate()
                lastSyncedData = metadata.data; syncRevision = metadata.revision
            }
        } catch {
            writable = false
            self.error = "Your saved data could not be opened. It has been kept intact. \(error.localizedDescription)"
        }
    }

    @discardableResult
    func update(_ change: (inout TrackerData) throws -> Void) -> Bool {
        guard writable else { error = "Storage is unavailable. Restart the app after resolving the storage problem."; return false }
        do {
            var next = data
            try change(&next)
            next = next.reimbursementsOnly
            try next.validate()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if !isPreview { try encoder.encode(next).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen]) }
            previous = data
            undoBaseline = next
            canUndo = true
            data = next
            refreshWidgets()
            refreshReminders()
            if !suppressNotifications { LiveShiftCenter.sync(next, accountID: accountID) }
            onChange?()
            error = nil  // a successful save clears an older failure, so it can't pop up later
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func updatePreferences(_ change: (inout AppPreferences) -> Void) -> Bool {
        update { data in var settings = data.settings; change(&settings); data.preferences = settings }
    }

    func undo() {
        guard let previous, let undoBaseline else { return }
        do {
            let restored = try AccountMerge.merge(base: undoBaseline, local: previous, remote: data)
            if update({ $0 = restored }) { self.previous = nil; self.undoBaseline = nil; canUndo = false }
        } catch { self.error = "This change can’t be undone because the same records changed elsewhere." }
    }

    func activateWidgets() { publishesWidgets = true; refreshWidgets() }
    func deactivateWidgets() { publishesWidgets = false; SharedWidgetStorage.clear(); LiveShiftCenter.endAll() }
    func refreshWidgets() {
        guard publishesWidgets else { return }
        do {
            try SharedWidgetStorage.publish(WidgetSnapshot(data: data, accountID: accountID))
            publishPennyWidget()
            widgetMessage = "Widgets updated from this account."
        } catch { widgetMessage = error.localizedDescription }
    }

    func refreshReminders() {
        guard !suppressNotifications else { return }
        let previousTask = reminderTask
        previousTask?.cancel()
        let snapshot = data
        reminderTask = Task {
            await previousTask?.value
            if Task.isCancelled { return }
            do {
                let count = try await ShiftNotifications.schedule(snapshot, accountID: accountID, remote: usesRemotePush)
                if !Task.isCancelled { reminderMessage = usesRemotePush ? "Account push notifications are active." : "\(count) iPhone job reminders scheduled." }
            } catch is CancellationError {} catch { if !Task.isCancelled { reminderMessage = "Reminders could not be scheduled: \(error.localizedDescription)" } }
        }
    }

    func stopReminders() async {
        let pending = reminderTask
        reminderTask = nil
        pending?.cancel()
        await pending?.value
    }

    @discardableResult
    func save(_ shift: Shift) -> Bool {
        update { data in
            if let index = data.shifts.firstIndex(where: { $0.id == shift.id }) { data.shifts[index] = shift }
            else { data.shifts.append(shift) }
        }
    }

    func delete(_ shift: Shift) {
        update { data in
            data.shifts.removeAll { $0.id == shift.id }
            data.claims.removeAll { $0.shiftID == shift.id }
            data.expenses?.removeAll { $0.shiftID == shift.id }
        }
    }

    /// Settings that 1.1 and earlier kept only on this iPhone (Penny, live shift choices, widget previews)
    /// move into the account the first time it's opened here, after its records have synced, so every
    /// device signed in to the account shares them. Values already in the account win.
    func adoptDeviceSettings(_ defaults: UserDefaults = .standard) {
        guard writable, !isPreview else { return }
        var settings = data.settings
        var adopted = false
        let closetKey = PetLegacyStorage.closetKey(accountID)
        if settings.pet == nil, defaults.object(forKey: closetKey) != nil || defaults.object(forKey: PetLegacyStorage.nameKey) != nil {
            settings.pet = PetPreferences(name: defaults.string(forKey: PetLegacyStorage.nameKey), closet: PetLegacyStorage.closet(defaults.string(forKey: closetKey)))
            adopted = true
        }
        let confirmedKey = LiveShiftCenter.legacyConfirmedKey(accountID)
        if settings.liveShift == nil, [LiveShiftCenter.lockScreenKey, LiveShiftCenter.askFinishKey, confirmedKey].contains(where: { defaults.object(forKey: $0) != nil }) {
            var live = LiveShiftPreferences()
            live.lockScreen = defaults.object(forKey: LiveShiftCenter.lockScreenKey) as? Bool
            live.askFinish = defaults.object(forKey: LiveShiftCenter.askFinishKey) as? Bool
            let confirmed = (defaults.stringArray(forKey: confirmedKey) ?? []).compactMap(UUID.init(uuidString:))
            live.confirmedFinishes = confirmed.isEmpty ? nil : Array(confirmed.suffix(300))
            settings.liveShift = live
            adopted = true
        }
        let widgetPrefix = "howmuch.widgetPreviews." + accountID
        if settings.widgetPreview == nil, defaults.object(forKey: widgetPrefix + ".showPay") != nil || defaults.object(forKey: widgetPrefix + ".showLocation") != nil {
            var previews = WidgetPreviewPreferences()
            previews.showPay = defaults.object(forKey: widgetPrefix + ".showPay") as? Bool
            previews.showLocation = defaults.object(forKey: widgetPrefix + ".showLocation") as? Bool
            settings.widgetPreview = previews
            adopted = true
        }
        guard !adopted || update({ $0.preferences = settings }) else { return }
        for key in [closetKey, PetLegacyStorage.nameKey, confirmedKey, LiveShiftCenter.lockScreenKey, LiveShiftCenter.askFinishKey,
                    widgetPrefix + ".showPay", widgetPrefix + ".showLocation"] { defaults.removeObject(forKey: key) }
    }

    func importCSV(_ url: URL) throws -> (added: Int, skipped: Int) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 10_000_000 else { throw TrackerError.invalid("Choose a CSV smaller than 10 MB.") }
        let incoming = try ShiftCSV.decode(String(contentsOf: url, encoding: .utf8))
        var added = 0
        let success = update { data in
            added = data.importShifts(incoming)
        }
        guard success else { throw TrackerError.invalid(error ?? "The import could not be saved.") }
        return (added, incoming.count - added)
    }

    func readArchive(_ url: URL) throws -> TrackerData {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10_000_000 else { throw TrackerError.invalid("Choose an archive smaller than 10 MB.") }
        let archive = try JSONDecoder().decode(TrackerData.self, from: Data(contentsOf: url))
        try archive.validate()
        return archive
    }

    func applySynced(_ envelope: CloudEnvelope, current: TrackerData) throws {
        try current.validate(); try envelope.data.validate()
        if !isPreview {
            try JSONEncoder().encode(current).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            try JSONEncoder().encode(SyncMetadata(revision: envelope.revision, data: envelope.data))
                .write(to: url.deletingLastPathComponent().appending(path: "sync.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        data = current; refreshWidgets(); lastSyncedData = envelope.data; syncRevision = envelope.revision
        syncMessage = hasPendingChanges ? "Saved on this phone · sync pending" : "Your account is up to date"
        refreshReminders()
    }

    func preserveConflict(_ remote: TrackerData) throws {
        guard !isPreview else { return }
        let folder = url.deletingLastPathComponent().appending(path: "conflicts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Named by content, so re-detecting the same conflict doesn't write the same copies again.
        let phone = try JSONEncoder().encode(data), cloud = try JSONEncoder().encode(remote)
        let suffix = SHA256.hash(data: phone + cloud).prefix(8).map { String(format: "%02x", $0) }.joined()
        let phoneURL = folder.appending(path: "phone-\(suffix).json")
        guard !FileManager.default.fileExists(atPath: phoneURL.path) else { return }
        try phone.write(to: phoneURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try cloud.write(to: folder.appending(path: "cloud-\(suffix).json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        // Keep only the latest three pairs.
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(6) { try? FileManager.default.removeItem(at: file) }
    }

    func removeAccountCache() throws {
        reminderTask?.cancel()
        guard !isPreview else { return }
        let folder = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    private var legacyURL: URL { URL.applicationSupportDirectory.appending(path: "HowMuch/tracker.json") }
    private var legacyOwnerURL: URL { URL.applicationSupportDirectory.appending(path: "HowMuch/legacy-import.json") }
    var hasLegacyImport: Bool {
        guard !isPreview, FileManager.default.fileExists(atPath: legacyURL.path) else { return false }
        guard let owner = try? JSONDecoder().decode(LegacyImport.self, from: Data(contentsOf: legacyOwnerURL)) else { return true }
        return owner.accountID == accountID && !owner.complete
    }
    func importEarlierPhoneRecords() throws {
        guard hasLegacyImport else { throw TrackerError.invalid("There are no unassigned earlier iPhone records to import.") }
        let legacy = try JSONDecoder().decode(TrackerData.self, from: Data(contentsOf: legacyURL))
        try legacy.validate()
        // Claim before copying, so another account cannot see the convenience import on this phone.
        try JSONEncoder().encode(LegacyImport(accountID: accountID, complete: false)).write(to: legacyOwnerURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        guard update({ data in
            for shift in legacy.shifts where !data.shifts.contains(where: { $0.id == shift.id }) { data.shifts.append(shift) }
            for claim in legacy.claims where !data.claims.contains(where: { $0.id == claim.id }) { data.claims.append(claim) }
        }) else { throw TrackerError.invalid(error ?? "Couldn’t save the imported records.") }
        try JSONEncoder().encode(LegacyImport(accountID: accountID, complete: true)).write(to: legacyOwnerURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private static func previewData() throws -> TrackerData {
        var data = TrackerData()
        data.rules.rate = 20
        var settings = AppPreferences(); settings.displayName = "Jia Le"; settings.payers["hermès private sale"] = "REFIX PTE. LTD."
        settings.eventRates["hermès private sale"] = 18
        data.preferences = settings
        let calendar = TrackerCalendar.calendar
        for (offset, event, location, rate) in [(-25, "Wedding reception", "Marina Bay Sands", 25), (-16, "Roadshow", "Suntec City", 20), (-9, "Hermès Private Sale", "Marina Bay Sands", 18), (-8, "Hermès Private Sale", "Marina Bay Sands", 18), (-2, "Brand launch", "Orchard Road", 22), (0, "Brand launch", "Orchard Road", 22), (1, "Hermès Private Sale", "Marina Bay Sands", 18), (3, "Weekend roadshow", "Suntec City", 20), (4, "Weekend roadshow", "Suntec City", 20), (8, "Wedding reception", "Fullerton Hotel", 25)] {
            let date = calendar.date(byAdding: .day, value: offset, to: Date())!
            data.shifts.append(try Shift(event: event, location: location, day: Shift.dayString(date), startMinute: 9 * 60, endMinute: 18 * 60, breakMinutes: 60, rate: Decimal(rate), rules: data.rules, paid: offset < -10,
                                         paymentDue: Shift.dayString(calendar.date(byAdding: .day, value: 14, to: date)!)))
        }
        #if DEBUG
        if CommandLine.arguments.contains("--ui-test-transit") || CommandLine.arguments.contains("--ui-test-live-transit") {
            var options = TravelReminderOptions(); options.enabled = true; options.transit = true
            options.origin = "Singapore Botanic Gardens, 1 Cluny Road, Singapore 259569"
            data.preferences?.travel = options
            if CommandLine.arguments.contains("--ui-test-live-transit") {
                let date = Date().addingTimeInterval(7200)
                let start = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
                data.shifts = [try Shift(event: "Public transit QA", location: "Marina Bay Sands, 10 Bayfront Avenue, Singapore 018956", day: Shift.dayString(date), startMinute: start, endMinute: (start + 240) % 1440, rate: 20)]
            }
        }
        if CommandLine.arguments.contains("--ui-test-quiet-days") {
            // Nothing today or tomorrow, so Overview points to the next booked day.
            let soon = [0, 1].map { Shift.dayString(calendar.date(byAdding: .day, value: $0, to: Date())!) }
            data.shifts.removeAll { soon.contains($0.day) }
        }
        if CommandLine.arguments.contains("--ui-test-travel-error") {
            var options = TravelReminderOptions(); options.enabled = true; options.origin = "Singapore Botanic Gardens, Singapore"
            data.preferences?.travel = options
        }
        if CommandLine.arguments.contains("--ui-test-overnight-calendar") {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
            data.shifts.append(try Shift(event: "Overnight calendar QA", day: Shift.dayString(yesterday), startMinute: 22*60, endMinute: 6*60, rate: 20))
        }
        #endif
        if let shift = data.shifts.first(where: { $0.event == "Hermès Private Sale" }) {
            data.claims.append(CabClaim(shiftID: shift.id, day: shift.day, amount: Decimal(string: "24.60")!, note: "Taxi home after pack-down"))
        }
        return data
    }
}

private struct SyncMetadata: Codable { let revision: Int; let data: TrackerData }
private struct LegacyImport: Codable { let accountID: String; let complete: Bool }

func money(_ value: Decimal, _ currency: String) -> String { formattedMoney(value, currency) }

/// "13h 28m" (or "8h") rather than a decimal like "13.47h".
func hoursText(_ hours: Decimal) -> String {
    let minutes = Int((NSDecimalNumber(decimal: hours).doubleValue * 60).rounded())
    return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
}
