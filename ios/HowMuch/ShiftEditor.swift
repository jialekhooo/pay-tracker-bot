import SwiftUI
import HowMuchCore
import PhotosUI
import Vision
import ImageIO
import UniformTypeIdentifiers

struct ShiftEditor: View {
    @EnvironmentObject private var store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    var existing: Shift? = nil
    var initialDay: Date? = nil
    var duplicating = false
    var template: JobTemplate? = nil
    var templateOnly = false
    /// A job message shared from another app; filled in on open for review.
    var initialMessage: String? = nil
    @State private var event = ""
    @State private var payerID: UUID?
    @State private var choosingPayer = false
    @State private var loadedTemplateEvent: String?
    @State private var location = ""
    @State private var day = Date()
    @State private var start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
    @State private var end = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
    @State private var breakMinutes = "0"
    @State private var paidBreak = false
    @State private var fixed = false
    @State private var amount = "15"
    @State private var currency = "SGD"
    @State private var overtime = false
    @State private var threshold = "8"
    @State private var multiplier = "1.5"
    @State private var hasDue = false
    @State private var due = Date()
    @State private var error: String?
    @State private var findingLocation = false
    @State private var loaded = false
    @State private var extraDates: [ExtraShiftDate] = []
    @State private var repeatDays = 0
    @State private var repeatCount = 4
    @State private var keepTemplate = false
    @State private var templateName = ""
    @State private var pasted: PastedJob?
    @State private var baseline = ""
    @State private var confirmingDiscard = false
    @State private var aiReading = false
    @State private var aiTask: Task<Void, Never>?
    /// Everything the form would save, to tell whether anything changed.
    private var fingerprint: String {
        [event, location, "\(day)", "\(start)", "\(end)", breakMinutes, "\(paidBreak)", "\(fixed)", amount, currency, "\(overtime)",
         threshold, multiplier, "\(hasDue)", "\(due)", "\(extraDates.count)", "\(repeatDays)", "\(payerID?.uuidString ?? "")"].joined(separator: "|")
    }
    private var isDirty: Bool { loaded && fingerprint != baseline }
    /// Rules first, straight away; then Apple Intelligence (up to 10 s), applied only if you haven't edited since.
    private func readMessage(_ text: String) {
        let rules = JobMessageParser.parse(text)
        applyPasted(rules)
        aiTask?.cancel()
        guard AppleIntelligence.isAvailable else { return }
        let snapshot = fingerprint
        aiReading = true
        aiTask = Task { @MainActor in
            defer { aiReading = false }
            let read = await withTaskGroup(of: PastedJob?.self) { group -> PastedJob? in
                group.addTask { await AppleIntelligence.readJob(text) }
                group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard !Task.isCancelled, let read, read != rules, fingerprint == snapshot else { return }
            applyPasted(read)
        }
    }
    private func minute(_ date: Date) -> Int { Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date) }
    private var preview: Shift? { try? makeShift() }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if existing == nil && template == nil && !templateOnly {
                        PasteJobCard(result: pasted) { readMessage($0) }
                        if aiReading {
                            Label { Text("Reading with Apple Intelligence…") } icon: { ProgressView().controlSize(.small) }
                                .font(.caption).foregroundStyle(Palette.muted).accessibilityIdentifier("paste.aiReading")
                        }
                    }
                    workCard
                    planningCard
                    scheduleCard
                    payCard
                    breakCard
                    paymentCard
                    if let preview { payoutCard(preview) }
                    if existing?.sourceID != nil {
                        Label("Your imported payout stays fixed. Choose Hourly and enter a rate to calculate pay from your hours.", systemImage: "square.and.arrow.down")
                            .font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 4)
                    }
                }.padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .detailStyle(existing == nil || duplicating ? "Add shift" : "Edit shift")
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.red).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Palette.canvas)
                        .accessibilityIdentifier("shift.error")
                }
            }
            .onChange(of: error) { _, message in if let message { AccessibilityNotification.Announcement(message).post() } }
            .safeAreaInset(edge: .top, spacing: 0) {
                EmptyView()
            }
            .interactiveDismissDisabled(isDirty)
            .onDisappear { aiTask?.cancel() }
            .confirmationDialog("Discard this shift?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if isDirty { confirmingDiscard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            let batch = try makeBatch()
                            if store.update({ data in
                                if let existing, !duplicating, let replacement = batch.first {
                                    try data.editShift(original: existing, replacement: replacement)
                                } else if !templateOnly { data.shifts.append(contentsOf: batch) }
                                if !templateOnly, let first = batch.first {
                                    var settings = data.settings; settings.assignPayer(payerID, to: first.event); data.preferences = settings
                                }
                                if keepTemplate || templateOnly, let first = batch.first {
                                    let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? first.event : templateName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    var settings = data.settings
                                    var templates = settings.jobTemplates ?? []
                                    let old = templates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? (templateOnly ? templates.first { $0.id == template?.id } : nil)
                                    templates.removeAll { $0.id == old?.id }
                                    let template = JobTemplate(id: old?.id ?? UUID(), name: name, shift: first, payerID: payerID)
                                    try template.validate(); templates.append(template)
                                    settings.jobTemplates = templates; data.preferences = settings
                                }
                            }) { dismiss() } else { error = store.error; store.error = nil }  // shown here only, not again as a global alert
                        }
                        catch { self.error = error.localizedDescription }
                    }.fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $choosingPayer) { PayerPickerView(selected: payerID) { payerID = $0 } }
            .onChange(of: event) { _, name in if existing == nil && !templateOnly { if let assigned = store.data.settings.payer(for: name)?.id { payerID = assigned } else if name != loadedTemplateEvent { payerID = nil } } }
            .sheet(isPresented: $findingLocation) { JobLocationPicker(initial: location) { location = $0 } }
            .onAppear {
                guard !loaded else { return }
                load(); loaded = true
                baseline = fingerprint
                if let initialMessage { readMessage(initialMessage) }
            }
            .onChange(of: [event, location, amount, breakMinutes, currency, threshold, multiplier]) { _, _ in error = nil }
        }
    }
    private var workCard: some View {
        Card {
            editorHeading("WORK DETAILS", symbol: "briefcase")
            if let existing, !duplicating {
                let count = store.data.shifts.filter { $0.event.caseInsensitiveCompare(existing.event) == .orderedSame }.count
                Text("Name and location changes apply to all \(count) shifts in this event. Schedule and pay changes apply only to this shift.").font(.caption).foregroundStyle(Palette.muted)
            }
            TextField("Event name", text: $event)
                .font(.system(.title2, design: .rounded, weight: .semibold)).frame(minHeight: 48)
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(Palette.teal).frame(width: 20)
                TextField("Location (optional)", text: $location)
            }.font(.subheadline).frame(minHeight: 44)
            Button("Find a place in Apple Maps", systemImage: "map") { findingLocation = true }.glassAction().accessibilityIdentifier("shift.findLocation")
            Button { choosingPayer = true } label: {
                HStack { Text("Paid by").foregroundStyle(Palette.muted); Spacer(); Text(store.data.settings.savedPayers?.first { $0.id == payerID }?.displayName ?? "Choose payer"); Image(systemName: "chevron.down").font(.caption) }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Palette.teal).accessibilityIdentifier("shift.payer")
            Text("Choosing a payer applies to every shift in this event.").font(.caption).foregroundStyle(Palette.muted)
            if existing == nil && !store.data.shifts.isEmpty {
                Menu {
                    ForEach(Array(Set(store.data.shifts.map(\.event))).sorted(), id: \.self) { name in
                        Button(name) { event = name; if let rate = store.data.settings.eventRates[name.lowercased()] { amount = "\(rate)" } }
                    }
                } label: {
                    Label("Choose a previous event", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.foregroundStyle(Palette.teal)
            }
        }
    }
    private var planningCard: some View {
        Card {
            editorHeading("TEMPLATES & REPEAT", symbol: "square.stack.3d.up")
            if (existing == nil || duplicating) && !templateOnly {
                if !(store.data.settings.jobTemplates ?? []).isEmpty {
                    Menu("Load a saved template") {
                        ForEach(store.data.settings.jobTemplates ?? []) { template in
                            Button(template.name) { applyTemplate(template) }
                        }
                    }.rowAction().accessibilityIdentifier("shift.templates")
                }
                Picker("Repeat", selection: $repeatDays) {
                    Text("No repeat").tag(0); Text("Daily").tag(1); Text("Weekly").tag(7); Text("Fortnightly").tag(14)
                }.accessibilityIdentifier("shift.repeat")
                if repeatDays > 0 {
                    Stepper("\(repeatCount) shifts, including the first", value: $repeatCount, in: 2...52).accessibilityIdentifier("shift.repeatCount")
                    Text("All dates are created now with the same times and pay rules. You can edit or delete each shift afterwards.").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            if !templateOnly { Toggle("Save these settings as a template", isOn: $keepTemplate).accessibilityIdentifier("shift.saveTemplate") }
            if keepTemplate || templateOnly {
                TextField("Template name (defaults to event name)", text: $templateName).accessibilityIdentifier("shift.templateName")
                Text("Includes location, times, rate and breaks. Saving a name that already exists updates that template.").font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }
    private func applyPasted(_ job: PastedJob) {
        pasted = job
        guard let first = job.dates.first else {
            error = "No date and time found in that message. Check it has dates like “12 Nov” and times like “9am-6pm”."
            return
        }
        func at(_ key: String, _ minute: Int) -> Date {
            Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: TrackerCalendar.localDate(key) ?? Date())!
        }
        if !job.name.isEmpty { event = job.name }
        if let place = job.location { location = place }
        day = at(first.day, 12 * 60); start = at(first.day, first.startMinute); end = at(first.day, first.endMinute)
        extraDates = job.dates.dropFirst().map { ExtraShiftDate(day: at($0.day, 12 * 60), start: at($0.day, $0.startMinute), end: at($0.day, $0.endMinute)) }
        repeatDays = 0; hasDue = false
        if let rate = job.rate { fixed = false; amount = "\(rate)" }
        else if let pay = job.fixedPay { fixed = true; amount = "\(pay)" }
        else if let saved = store.data.settings.eventRates[event.lowercased()] { fixed = false; amount = "\(saved)" }
        if let code = job.currency { currency = code }
        if let minutes = job.breakMinutes { breakMinutes = "\(minutes)" }
        error = nil
    }
    private func applyTemplate(_ template: JobTemplate) {
        let work = template.shift
        loadedTemplateEvent = work.event
        event = work.event; location = work.location
        payerID = templateOnly ? template.payerID : (store.data.settings.payer(for: work.event)?.id ?? template.payerID)
        start = Calendar.current.date(bySettingHour: work.startMinute / 60, minute: work.startMinute % 60, second: 0, of: day)!
        end = Calendar.current.date(bySettingHour: work.endMinute / 60, minute: work.endMinute % 60, second: 0, of: day)!
        breakMinutes = "\(work.breakMinutes)"; paidBreak = work.paidBreak
        fixed = work.fixedPay != nil; amount = "\(work.fixedPay ?? work.rate)"; currency = work.currency
        overtime = work.overtimeAfter != nil; threshold = "\(work.overtimeAfter ?? 8)"; multiplier = "\(work.overtimeMultiplier)"
        hasDue = false; templateName = template.name; error = nil
    }
    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                editorHeading("SCHEDULE", symbol: "calendar")
                DatePicker("Date", selection: $day, displayedComponents: .date).frame(minHeight: 44)
                Divider()
                DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute).frame(minHeight: 44)
                DatePicker("End", selection: $end, displayedComponents: .hourAndMinute).frame(minHeight: 44)
                if minute(end) <= minute(start) {
                    Label("Ends the following day", systemImage: "moon").font(.caption).foregroundStyle(Palette.teal)
                }
            }
            if existing == nil || duplicating {
                ForEach($extraDates) { $entry in
                    Card {
                        HStack {
                            editorHeading("ANOTHER DATE", symbol: "calendar.badge.plus")
                            Spacer()
                            Button("Remove", role: .destructive) { extraDates.removeAll { $0.id == entry.id } }.font(.caption).frame(minHeight: 44)
                        }
                        DatePicker("Date", selection: $entry.day, displayedComponents: .date).frame(minHeight: 44)
                        Divider()
                        DatePicker("Start", selection: $entry.start, displayedComponents: .hourAndMinute).frame(minHeight: 44)
                        DatePicker("End", selection: $entry.end, displayedComponents: .hourAndMinute).frame(minHeight: 44)
                        if minute(entry.end) <= minute(entry.start) { Label("Ends the following day", systemImage: "moon").font(.caption).foregroundStyle(Palette.teal) }
                    }
                }
                Button("Add another date for this event", systemImage: "plus") {
                    let next = TrackerCalendar.calendar.date(byAdding: .day, value: 1, to: extraDates.last?.day ?? day)!
                    extraDates.append(ExtraShiftDate(day: next, start: start, end: end))
                }.glassAction().accessibilityIdentifier("shift.addDate")
            }
        }
    }
    private var payCard: some View {
        Card {
            editorHeading("YOUR PAY", symbol: "banknote")
            Picker("Pay mode", selection: $fixed) { Text("Hourly").tag(false); Text("Lump sum").tag(true) }.pickerStyle(.segmented)
            Text(fixed ? "Total payout" : "Hourly rate").font(.caption).foregroundStyle(Palette.muted)
            TextField(fixed ? "Total payout" : "Hourly rate", text: $amount)
                .keyboardType(.decimalPad).font(.system(size: 36, weight: .semibold, design: .rounded))
                .accessibilityIdentifier("shift.amount")
            HStack {
                Text("Currency").font(.subheadline).foregroundStyle(Palette.muted)
                Spacer()
                TextField("Currency", text: $currency).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing).frame(width: 90, height: 44).font(.subheadline.weight(.semibold))
            }
            if !fixed, let rate = store.data.settings.eventRates[event.trimmingCharacters(in: .whitespaces).lowercased()] {
                Button("Use saved event rate: \(money(rate, currency))/h") { amount = "\(rate)" }.glassAction()
            }
            if !fixed {
                Divider()
                Toggle("Overtime", isOn: $overtime).frame(minHeight: 44)
                if overtime {
                    editorNumber("After hours", text: $threshold)
                    editorNumber("Multiplier", text: $multiplier)
                }
            }
        }
    }
    private var breakCard: some View {
        Card {
            editorHeading("BREAKS", symbol: "cup.and.saucer")
            HStack {
                Text("Break minutes").font(.subheadline)
                Spacer()
                TextField("Minutes", text: $breakMinutes).keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing).frame(width: 100, height: 44).font(.subheadline.weight(.semibold))
            }
            Divider()
            Toggle("Paid break", isOn: $paidBreak).frame(minHeight: 44)
            Text(paidBreak ? "Break time is included in your paid hours." : "Break time is deducted from your paid hours.")
                .font(.caption).foregroundStyle(Palette.muted)
        }
    }
    private var paymentCard: some View {
        Card {
            editorHeading("PAYMENT", symbol: "calendar.badge.clock")
            Toggle("Payment due date", isOn: $hasDue).frame(minHeight: 44)
            if hasDue { DatePicker("Due", selection: $due, displayedComponents: .date).frame(minHeight: 44).accessibilityIdentifier("shift.due") }
            else { Text("We'll suggest a Friday due date at least two weeks after the last event date.").font(.caption).foregroundStyle(Palette.muted) }
        }
    }
    private func payoutCard(_ preview: Shift) -> some View {
        Card {
            editorHeading(extraDates.isEmpty ? "ESTIMATED WORK PAYOUT" : "FIRST DATE · ESTIMATED PAYOUT", symbol: "wallet.bifold")
            Text(money(preview.pay, preview.currency)).font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                .minimumScaleFactor(0.65).lineLimit(1)
            Text("\(PayEngine.rounded(preview.hours)) paid hours · Claims added separately").font(.caption).foregroundStyle(Palette.muted)
            if !extraDates.isEmpty || repeatDays > 0 { Text("Saving adds \(extraDates.count + (repeatDays > 0 ? repeatCount : 1)) shifts. Each date uses its own scheduled hours.").font(.caption).foregroundStyle(Palette.muted) }
            if store.data.shifts.contains(where: { preview.overlaps($0) }) {
                Label("This overlaps another shift.", systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
            }
        }
    }
    private func editorHeading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.muted)
    }
    private func editorNumber(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            TextField(title, text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .frame(width: 100, height: 44).font(.subheadline.weight(.semibold))
        }
    }
    private func makeShift() throws -> Shift {
        guard let amountValue = ShiftCSV.decimal(amount), let breaks = Int(breakMinutes),
              let thresholdValue = ShiftCSV.decimal(threshold), let multiplierValue = ShiftCSV.decimal(multiplier) else {
            throw TrackerError.invalid("Enter valid amounts using a full stop, and a whole number of break minutes.")
        }
        var rules = store.data.rules
        rules.currency = currency.uppercased()
        rules.overtimeAfter = overtime && !fixed ? thresholdValue : nil
        rules.overtimeMultiplier = multiplierValue
        return try Shift(id: duplicating ? UUID() : existing?.id ?? UUID(), sourceID: duplicating ? nil : existing?.sourceID,
                         event: event, location: location, day: Shift.dayString(day),
                         startMinute: minute(start), endMinute: minute(end), breakMinutes: breaks,
                         paidBreak: paidBreak, rate: fixed ? 0 : amountValue, fixedPay: fixed ? amountValue : nil,
                         rules: rules, paid: duplicating ? false : existing?.paid ?? false, paymentDue: hasDue ? Shift.dayString(due) : existing == nil || duplicating ? Shift.dayString(TrackerCalendar.defaultDueDate(for: day, existing: store.data.shifts, event: event)) : nil)
    }
    private func makeBatch() throws -> [Shift] {
        let primary = try makeShift()
        var batch = (existing == nil || duplicating) && repeatDays > 0 ? try ShiftSeries.make(from: primary, every: repeatDays, count: repeatCount) : [primary]
        // A pasted lump sum split across the dates: the last date takes the leftover cents so the total is exact.
        var lastPay = primary.fixedPay
        if let total = pasted?.lumpSum, let share = primary.fixedPay, share == pasted?.fixedPay, !extraDates.isEmpty, extraDates.count + 1 == pasted?.dates.count, repeatDays == 0 {
            lastPay = total - share * Decimal(extraDates.count)
        }
        for (index, entry) in extraDates.enumerated() {
            var rules = PayRules(); rules.currency = primary.currency
            rules.overtimeAfter = primary.overtimeAfter; rules.overtimeMultiplier = primary.overtimeMultiplier
            let pay = index == extraDates.count - 1 ? lastPay : primary.fixedPay
            batch.append(try Shift(event: primary.event, location: primary.location, day: Shift.dayString(entry.day), startMinute: minute(entry.start), endMinute: minute(entry.end), breakMinutes: primary.breakMinutes, paidBreak: primary.paidBreak, rate: primary.rate, fixedPay: pay, rules: rules, paymentDue: hasDue ? Shift.dayString(due) : nil))
        }
        for shift in batch where batch.contains(where: { shift.overlaps($0) }) { throw TrackerError.invalid("Two dates in this entry overlap. Check the schedule before saving.") }
        if !hasDue && (existing == nil || duplicating) {
            let last = batch.map(\.startDate).max() ?? day
            let due = Shift.dayString(TrackerCalendar.defaultDueDate(for: last, existing: store.data.shifts, event: event))
            for index in batch.indices { batch[index].paymentDue = due }
        }
        return batch
    }
    private func load() {
        if let template { applyTemplate(template); return }
        if let shift = existing {
            event = shift.event; location = shift.location; day = shift.startDate
            payerID = store.data.settings.payer(for: shift.event)?.id
            start = shift.startDate; end = shift.endDate
            breakMinutes = "\(shift.breakMinutes)"; paidBreak = shift.paidBreak
            fixed = shift.fixedPay != nil; amount = "\(shift.fixedPay ?? shift.rate)"; currency = shift.currency
            overtime = shift.overtimeAfter != nil; threshold = "\(shift.overtimeAfter ?? 8)"; multiplier = "\(shift.overtimeMultiplier)"
            hasDue = shift.paymentDue != nil
            if let date = shift.paymentDue, let parsed = TrackerCalendar.localDate(date) { due = parsed }
        } else {
            amount = "\(store.data.rules.rate)"; currency = store.data.rules.currency
            overtime = store.data.rules.overtimeAfter != nil
            threshold = "\(store.data.rules.overtimeAfter ?? 8)"; multiplier = "\(store.data.rules.overtimeMultiplier)"
            breakMinutes = "\(store.data.settings.defaultBreakMinutes)"; paidBreak = store.data.settings.defaultBreakPaid
            if let initialDay { day = initialDay }
        }
    }
}

private struct ExtraShiftDate: Identifiable {
    let id = UUID()
    var day: Date
    var start: Date
    var end: Date
}

struct ClaimEditor: View {
    @EnvironmentObject private var store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    let shift: Shift
    var existing: CabClaim? = nil
    @EnvironmentObject private var auth: AppleAccountStore
    @State private var receiptID: UUID?
    @State private var receiptData: Data?
    @State private var receiptProcessing = false
    @State private var saving = false
    @State private var category: ClaimCategory = .cab
    @State private var loaded = false
    @State private var amount = ""
    @State private var note = ""
    @State private var day = Date()
    @State private var error: String?
    @State private var claimBaseline = ""
    @State private var confirmingDiscard = false
    private var claimFingerprint: String { [category.rawValue, amount, note, "\(day)", "\(receiptID?.uuidString ?? "")", "\(receiptData?.count ?? 0)"].joined(separator: "|") }
    private var claimDirty: Bool { loaded && claimFingerprint != claimBaseline }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Card {
                        Label("REIMBURSEMENT", systemImage: category.symbol).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.muted)
                        Text("Claim type").font(.caption).foregroundStyle(Palette.muted)
                        HStack(spacing: 6) {
                            ForEach(ClaimCategory.allCases) { kind in
                                Button { category = kind } label: {
                                    Text(kind.title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Capsule())
                                        .foregroundStyle(category == kind ? Color.white : Palette.teal)
                                        .glassChrome(in: Capsule(), tint: category == kind ? Palette.teal : nil)
                                }.buttonStyle(.plain).accessibilityIdentifier("claim.category.\(kind.rawValue)")
                                    .accessibilityAddTraits(category == kind ? .isSelected : [])
                            }
                        }
                        Text(shift.currency).font(.caption.bold()).foregroundStyle(Palette.teal)
                        TextField("Amount (\(shift.currency))", text: $amount)
                            .keyboardType(.decimalPad).font(.system(size: 38, weight: .semibold, design: .rounded)).foregroundStyle(Palette.ink)
                            .accessibilityIdentifier("claim.amount")
                        Text("Added to your expected bank credit, separately from work earnings").font(.caption).foregroundStyle(Palette.muted)
                    }
                    Card {
                        Text(shift.event).font(.system(.headline, design: .rounded)).foregroundStyle(Palette.ink)
                        Text(displayDay(shift.day)).font(.caption).foregroundStyle(Palette.muted)
                        Divider()
                        DatePicker("Date", selection: $day, displayedComponents: .date).font(.subheadline)
                        Divider()
                        TextField("Note (optional)", text: $note).frame(minHeight: 44).font(.subheadline).accessibilityIdentifier("claim.note")
                            .onChange(of: note) { _, value in if value.count > CabClaim.maxNote { note = String(value.prefix(CabClaim.maxNote)) } }
                    }
                    ReceiptAttachmentEditor(receiptID: $receiptID, photoData: $receiptData, processing: $receiptProcessing,
                                            amount: $amount, category: $category, note: $note, useDay: { day = $0 })
                    Label("Your claim stays attached to this shift and syncs with your HowMuch account.", systemImage: "checkmark.shield").font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 4)
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).detailStyle(existing == nil ? "Claim" : "Edit claim")
            .safeAreaInset(edge: .top, spacing: 0) {
                // At the top, so a save error is never hidden below a long form.
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.red).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Palette.canvas)
                        .accessibilityIdentifier("claim.error")
                }
            }
            .onChange(of: error) { _, message in if let message { AccessibilityNotification.Announcement(message).post() } }
            .interactiveDismissDisabled(claimDirty)
            .confirmationDialog("Discard this claim?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if claimDirty { confirmingDiscard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") { Task { await save() } }.disabled(saving || receiptProcessing).accessibilityIdentifier("claim.save") }
            }
            .onAppear {
                if !loaded {
                    if let existing { category = existing.category; amount = "\(existing.amount)"; note = existing.note; day = TrackerCalendar.localDate(existing.day) ?? Date() }
                    else { day = TrackerCalendar.localDate(shift.day) ?? Date() }
                    receiptID = existing?.receiptID
                    loaded = true
                    claimBaseline = claimFingerprint
                }
            }
        }
    }
    private func save() async {
        guard let value = ShiftCSV.decimal(amount), PayEngine.rounded(value) > 0 else { error = "Enter an amount of at least 0.01."; return }
        saving = true; defer { saving = false }
        let owner = store.accountID
        do {
            if let receiptData {
                let identifier = UUID()
                _ = try await auth.api.request("/v1/receipts/" + identifier.uuidString, method: "PUT", body: receiptData, contentType: "image/jpeg")
                receiptID = identifier; self.receiptData = nil
            }
            guard auth.account?.id.lowercased() == owner else { throw TrackerError.invalid("Your account changed. Reopen this claim before saving.") }
        } catch { self.error = error.localizedDescription; return }
        if store.update({ data in
            var records = data.claims
            if let existing {
                guard let index = records.firstIndex(where: { $0.id == existing.id && $0.shiftID == shift.id }) else { throw TrackerError.invalid("This record was removed. Close this screen and check your latest records.") }
                records[index].category = category; records[index].amount = PayEngine.rounded(value)
                records[index].day = Shift.dayString(day); records[index].note = note; records[index].receiptID = receiptID
            } else {
                var claim = CabClaim(shiftID: shift.id, day: Shift.dayString(day), amount: PayEngine.rounded(value), note: note, category: category)
                claim.receiptID = receiptID; records.append(claim)
            }
            data.claims = records
        }) { dismiss() } else { error = store.error; store.error = nil }  // shown here only, not again as a global alert
    }
}

struct ReceiptAttachmentEditor: View {
    @EnvironmentObject private var auth: AppleAccountStore
    @Binding var receiptID: UUID?
    @Binding var photoData: Data?
    @Binding var processing: Bool
    @Binding var amount: String
    @Binding var category: ClaimCategory
    @Binding var note: String
    let useDay: (Date) -> Void
    @State private var suggestedCategory: ClaimCategory?
    @State private var selected: PhotosPickerItem?
    @State private var preview: Data?
    @State private var message = ""
    @State private var suggestion = ReceiptSuggestions()
    @State private var viewingReceipt = false
    var body: some View {
        Card {
            Label("RECEIPT PHOTO", systemImage: "doc.viewfinder").font(.caption.weight(.semibold)).foregroundStyle(Palette.teal)
            if let data = photoData ?? preview, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("receipt.preview")
            }
            if let data = photoData ?? preview {
                Button("View or save receipt", systemImage: "arrow.down.doc") { viewingReceipt = true }.glassAction().accessibilityIdentifier("receipt.view")
                if !processing { Button("Read amount again", systemImage: "text.viewfinder") { Task { await readAmount(data) } }.rowAction().accessibilityIdentifier("receipt.rescan") }
            }
            if processing { ProgressView("Reading receipt…") }
            PhotosPicker(selection: $selected, matching: .images) { Label(receiptID != nil || photoData != nil ? "Replace receipt photo" : "Attach receipt photo", systemImage: "photo") }.glassAction().disabled(processing).accessibilityIdentifier("receipt.attach")
            #if DEBUG
            if ReceiptUITestFixture.active {
                Button("Use sample receipt") { Task { await prepare(ReceiptUITestFixture.sample()) } }.rowAction().accessibilityIdentifier("receipt.sample")
            }
            #endif
            if receiptID != nil || photoData != nil {
                Button("Remove attachment", role: .destructive) { receiptID = nil; photoData = nil; preview = nil; suggestion = ReceiptSuggestions(); selected = nil }.rowAction().disabled(processing).accessibilityIdentifier("receipt.remove")
            }
            if let total = suggestion.amount { Button("Use suggested total: \(total)") { amount = NSDecimalNumber(decimal: total).stringValue }.rowAction().accessibilityIdentifier("receipt.useAmount") }
            if let day = suggestion.day, let date = TrackerCalendar.localDate(day) { Button("Use suggested date: " + displayDay(day)) { useDay(date) }.rowAction().accessibilityIdentifier("receipt.useDate") }
            if let kind = suggestedCategory, kind != category { Button("Use suggested type: \(kind.title)") { category = kind }.rowAction().accessibilityIdentifier("receipt.useCategory") }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Palette.muted) }
            Text("The detected total fills the amount automatically; check it before saving. Receipt copies are saved privately to your HowMuch account with the claim. Open View or save receipt to download a copy.").font(.caption).foregroundStyle(Palette.muted)
        }
        .sheet(isPresented: $viewingReceipt) { if let data = photoData ?? preview { ReceiptViewer(data: data) } }
        .task(id: receiptID) {
            guard let receiptID, photoData == nil else { return }
            do { preview = try await auth.api.request("/v1/receipts/" + receiptID.uuidString) }
            catch { message = "Couldn't load this receipt. Your saved attachment is kept; reopen to retry, or replace it." }
        }
        .onChange(of: selected) { _, value in
            guard let value else { return }
            Task {
                processing = true
                do {
                    guard let data = try await value.loadTransferable(type: Data.self) else { throw TrackerError.invalid("Couldn't load this photo.") }
                    await prepare(data)
                } catch { message = error.localizedDescription; processing = false }
            }
        }
    }
    private func prepare(_ input: Data) async {
        processing = true; defer { processing = false }
        do {
            // Decode, resize and encode off the main thread so the form never freezes.
            let (data, scan) = try await Task.detached(priority: .userInitiated) { () throws -> (Data, Data) in
                guard input.count <= 30_000_000,
                      let source = CGImageSourceCreateWithData(input as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw TrackerError.invalid("Choose a photo smaller than 30 MB.") }
                guard let data = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.55), data.count <= 750_000 else { throw TrackerError.invalid("This photo is too large. Crop it to the receipt and try again.") }
                // Recognise a sharper copy than the stored one (a high-quality JPEG, not a huge PNG).
                let scanImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 3200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) ?? thumbnail
                return (data, UIImage(cgImage: scanImage).jpegData(compressionQuality: 0.92) ?? data)
            }.value
            photoData = data; preview = nil; receiptID = nil
            suggestion = ReceiptSuggestions(); message = "Photo ready. Reading text on this iPhone…"
            await readAmount(scan)
        } catch { message = error.localizedDescription }
    }
    private func readAmount(_ data: Data) async {
        processing = true; defer { processing = false }
        let originalAmount = amount
        suggestion = ReceiptSuggestions()
        let text = await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(data: data).perform([request])
                var rows: [(y: CGFloat, height: CGFloat, items: [(CGFloat, String)])] = []
                for observation in (request.results ?? []).sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
                    guard let value = observation.topCandidates(1).first?.string else { continue }
                    let box = observation.boundingBox
                    if let index = rows.firstIndex(where: { abs($0.y - box.midY) < min($0.height, box.height) * 0.6 }) {
                        rows[index].items.append((box.minX, value))
                    } else { rows.append((box.midY, box.height, [(box.minX, value)])) }
                }
                return rows.map { $0.items.sorted { $0.0 < $1.0 }.map { $0.1 }.joined(separator: " ") }.joined(separator: "\n")
            } catch { return "" }
        }.value
        suggestion = ReceiptSuggestions(text: text)
        suggestedCategory = nil
        // Apple Intelligence (on the iPhone) fills what the rules missed: the total, any date format,
        // the claim type and a short note. Its total is only used if it's printed on the receipt.
        var helped = false
        if let read = await AppleIntelligence.readReceipt(text) {
            if suggestion.amount == nil, let total = read.total { suggestion.amount = total; helped = true }
            if suggestion.day == nil, let day = read.day { suggestion.day = day; helped = true }
            if let kind = read.category { suggestedCategory = kind }
            if note.trimmingCharacters(in: .whitespaces).isEmpty, let text = read.note { note = text; helped = true }
        }
        if let total = suggestion.amount {
            if amount == originalAmount { amount = NSDecimalNumber(decimal: total).stringValue; message = helped ? "Apple Intelligence read this receipt on your iPhone. Check the amount, date and note before saving." : "Detected total filled in. Check the amount against your receipt before saving." }
            else { message = "Total detected. Your amount was edited while scanning, so it has been kept. Use the suggested total to replace it." }
        } else { message = "Photo attached. A clear total could not be found; enter the amount or try a sharper receipt photo." }
    }

}

#if DEBUG
enum ReceiptUITestFixture {
    static var active: Bool { CommandLine.arguments.contains("--ui-test-receipts") }
    static func sample() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 700, height: 440)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 700, height: 440))
            let style: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.black]
            ("SAMPLE RECEIPT" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: style)
            ("Subtotal 10.00" as NSString).draw(at: CGPoint(x: 40, y: 110), withAttributes: style)
            ("Total" as NSString).draw(at: CGPoint(x: 40, y: 210), withAttributes: style)
            ("S$12.50" as NSString).draw(at: CGPoint(x: 490, y: 210), withAttributes: style)
            ("2026-11-05" as NSString).draw(at: CGPoint(x: 40, y: 300), withAttributes: style)
        }
    }
    private static var failedOnce = false
    static func response(for request: URLRequest) throws -> Data? {
        guard active, request.url?.path.hasPrefix("/v1/receipts/") == true else { return nil }
        if request.httpMethod == "PUT" {
            if CommandLine.arguments.contains("--ui-test-receipt-upload-error") && !failedOnce { failedOnce = true; throw AccountHTTPError(status: 503, message: "Receipt upload unavailable. Try again.") }
            return Data("{}".utf8)
        }
        return sample()
    }
}
#endif

struct JobTemplatesView: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var selected: JobTemplate?
    @State private var editing: JobTemplate?
    @State private var deleting: JobTemplate?
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if (store.data.settings.jobTemplates ?? []).isEmpty {
                    Card { Label("Your usual jobs, ready to reuse", systemImage: "square.stack.3d.up").font(.headline); Text("When adding a job, turn on Save these settings as a template. Locations, times, pay and breaks will be ready next time.").font(.subheadline).foregroundStyle(Palette.muted) }
                }
                ForEach(store.data.settings.jobTemplates ?? []) { template in
                    Card {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(template.name).font(.headline)
                                Text(template.shift.event).font(.subheadline)
                                Text("\(Shift.clock(template.shift.startMinute))–\(Shift.clock(template.shift.endMinute)) · \(template.shift.location)").font(.caption).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Menu {
                                Button("Edit template", systemImage: "pencil") { editing = template }
                                Button("Delete template", systemImage: "trash", role: .destructive) { deleting = template }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Template actions: " + template.name)
                        }
                        Button("Use template", systemImage: "plus") { selected = template }.rowAction().accessibilityIdentifier("template.use")
                    }
                }
                if store.canUndo { Button("Undo last change", systemImage: "arrow.uturn.backward") { store.undo() }.glassAction() }
            }.padding(20)
        }.detailStyle("Job templates")
            .sheet(item: $selected) { ShiftEditor(template: $0) }
            .sheet(item: $editing) { ShiftEditor(template: $0, templateOnly: true) }
            .alert("Delete template?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete", role: .destructive) { if let deleting { store.updatePreferences { $0.jobTemplates?.removeAll { $0.id == deleting.id } } }; deleting = nil }
                Button("Cancel", role: .cancel) { deleting = nil }
            }
    }
}


struct ReceiptViewer: View {
    @Environment(\.dismiss) private var dismiss
    let data: Data
    @State private var savedURL: URL?
    @State private var exportID = UUID()
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().accessibilityIdentifier("receipt.fullImage") }
                    Button("Save to Files", systemImage: "square.and.arrow.down") { saveCopy() }.glassAction().accessibilityIdentifier("receipt.download")
                    if let savedURL {
                        Label("Saved in Files → On My iPhone → HowMuch → Receipts", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(Palette.teal).accessibilityIdentifier("receipt.saved")
                        ShareLink(item: savedURL) { Label("Share receipt copy", systemImage: "square.and.arrow.up") }.glassAction()
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                    Text("Receipt copies saved to Files stay on this iPhone until you remove them, including after signing out.").font(.caption).foregroundStyle(Palette.muted)
                }.padding(20)
            }.detailStyle("Receipt")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func saveCopy() {
        do {
            let folder = URL.documentsDirectory.appending(path: "Receipts", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "HowMuch-receipt-" + exportID.uuidString + ".jpg")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            // Verify the exported copy before reporting success.
            guard try Data(contentsOf: url) == data else { throw TrackerError.invalid("The receipt copy could not be verified. Please try again.") }
            savedURL = url; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct SavedReceiptView: View {
    @EnvironmentObject private var auth: AppleAccountStore
    @Environment(\.dismiss) private var dismiss
    let receiptID: UUID
    @State private var data: Data?
    @State private var error: String?
    @State private var attempt = 0
    var body: some View {
        Group {
            if let data { ReceiptViewer(data: data) }
            else {
                NavigationStack {
                    VStack(spacing: 20) {
                        if let error {
                            Text(error)
                            Button("Try again") { attempt += 1 }
                        } else { ProgressView("Loading saved receipt…") }
                    }.padding(20).detailStyle("Receipt")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                }
            }
        }.task(id: attempt) {
            error = nil
            do { data = try await auth.api.request("/v1/receipts/" + receiptID.uuidString) }
            catch { self.error = error.localizedDescription }
        }
    }
}
