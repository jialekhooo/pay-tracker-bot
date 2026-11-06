import SwiftUI
import HowMuchCore

struct WorkCalendarView: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var month = Date()
    @State private var selected = Date()
    @State private var adding = false
    @State private var sharingAvailability = false
    init(initialDay: Date = Date()) {
        _month = State(initialValue: initialDay)
        _selected = State(initialValue: initialDay)
    }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
    private var monthShifts: [Shift] {
        guard let interval = TrackerCalendar.calendar.dateInterval(of: .month, for: month) else { return [] }
        return store.data.shifts.filter { $0.startDate < interval.end && $0.endDate > interval.start }
    }
    private var selectedShifts: [Shift] { TrackerCalendar.shifts(on: selected, from: store.data.shifts) }
    var body: some View {
        ScreenShell(title: "Calendar", subtitle: "A clearer view of your working days.") {
            Card {
                HStack {
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.system(.title3, design: .rounded, weight: .bold)).lineLimit(1).minimumScaleFactor(0.75)
                    Spacer()
                    Button { month = Date(); selected = Date() } label: { Text("Today").font(.caption.bold()).padding(.horizontal, 10).frame(minHeight: 44).background(Palette.mint, in: Capsule()).contentShape(Rectangle()) }.accessibilityIdentifier("calendar.today")
                    Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Previous month")
                    Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Next month")
                }
                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, label in Text(label).font(.caption2.weight(.semibold)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.bottom, 4) }
                    ForEach(Array(TrackerCalendar.monthDays(month).enumerated()), id: \.offset) { _, date in
                        if let date {
                            let key = Shift.dayString(date)
                            let items = TrackerCalendar.shifts(on: date, from: monthShifts)
                            let chosen = TrackerCalendar.calendar.isDate(date, inSameDayAs: selected)
                            let today = TrackerCalendar.calendar.isDateInToday(date)
                            let clash = items.contains { a in store.data.shifts.contains { a.overlaps($0) } }
                            Button { selected = date } label: {
                                VStack(spacing: 5) {
                                    Text("\(TrackerCalendar.calendar.component(.day, from: date))").font(.system(size: 14, weight: chosen || today ? .bold : .medium))
                                    HStack(spacing: 2) { ForEach(0..<min(3, items.count), id: \.self) { _ in Circle().fill(chosen ? .white : clash ? Color.orange : Palette.teal).frame(width: 3, height: 3) } }.frame(height: 4)
                                }.frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(chosen ? .white : today ? Palette.teal : Palette.ink)
                                    .background(chosen ? Palette.teal : today ? Palette.mint : .clear, in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("\(date.formatted(.dateTime.day().month(.wide).year())), \(counted(items.count, "shift"))")
                                .accessibilityIdentifier("calendar.day.\(key)").accessibilityAddTraits(chosen ? .isSelected : [])
                        } else { Color.clear.frame(height: 40) }
                    }
                }
                Divider()
                HStack(spacing: 6) { Circle().fill(Palette.teal).frame(width: 5, height: 5); Text("Booked shift"); Spacer(); Circle().fill(.orange).frame(width: 5, height: 5); Text("Overlapping") }.font(.caption2).foregroundStyle(Palette.muted)
            }
            HStack {
                Text("\(counted(monthShifts.count, "shift")) this month").font(.caption).foregroundStyle(Palette.muted)
                Spacer()
                Button { sharingAvailability = true } label: { Label("Share availability", systemImage: "person.badge.clock").font(.caption.bold()) }
                    .accessibilityIdentifier("calendar.availability")
                NavigationLink { CalendarSettingsView() } label: { Label("Export", systemImage: "square.and.arrow.up").font(.caption.bold()) }.accessibilityIdentifier("calendar.export")
            }
            SectionHeading(title: selected.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)), detail: counted(selectedShifts.count, "shift"))
            if selectedShifts.isEmpty { EmptyCard(title: "A day with possibilities", message: "No shifts booked for this date.") }
            else { ShiftCards(shifts: selectedShifts) }
            Button("Add shift on this day", systemImage: "plus") { adding = true }.glassAction().accessibilityIdentifier("calendar.add")
        }.sheet(isPresented: $adding) { ShiftEditor(initialDay: selected) }
            .sheet(isPresented: $sharingAvailability) { AvailabilitySheet() }
    }
    private func move(_ amount: Int) {
        month = TrackerCalendar.calendar.date(byAdding: .month, value: amount, to: month)!
        let components = TrackerCalendar.calendar.dateComponents([.year, .month], from: month)
        selected = TrackerCalendar.calendar.date(from: components)!
    }
}


/// "Send your availability": a message worked out from booked shifts and the days you block.
struct AvailabilitySheet: View {
    @EnvironmentObject private var store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    @State private var from = Date()
    @State private var to = TrackerCalendar.calendar.date(byAdding: .day, value: 30, to: Date())!
    @State private var blocked: Set<String> = []
    @State private var copied = false
    private var days: [Date] {
        var result: [Date] = []
        var cursor = TrackerCalendar.calendar.startOfDay(for: from)
        while cursor <= end, result.count < Self.maxDays { result.append(cursor); cursor = TrackerCalendar.calendar.date(byAdding: .day, value: 1, to: cursor)! }
        return result
    }
    static let maxDays = 93
    /// The last day covered: "To", kept within the grid even if "From" moved after "To" was picked.
    private var end: Date { min(max(from, to), TrackerCalendar.calendar.date(byAdding: .day, value: Self.maxDays - 1, to: from)!) }
    private var text: String { Availability.message(from: from, to: end, shifts: store.data.shifts, blocked: blocked) }
    var body: some View {
        NavigationStack {
            AppForm {
                Section(styled: "Dates") {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    // The day grid below shows up to 93 days, so the message never covers days you can't see or block.
                    DatePicker("To", selection: $to, in: from...TrackerCalendar.calendar.date(byAdding: .day, value: Self.maxDays - 1, to: from)!, displayedComponents: .date)
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                        ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { index in
                            Text(["M", "T", "W", "T", "F", "S", "S"][index]).font(.caption2.weight(.semibold)).foregroundStyle(Palette.muted)
                        }
                        // Line day 1 up under its weekday (weeks start on Monday).
                        ForEach(0..<((TrackerCalendar.calendar.component(.weekday, from: from) + 5) % 7), id: \.self) { _ in Color.clear.frame(height: 36) }
                        ForEach(days, id: \.self) { date in dayButton(date) }
                    }.padding(.vertical, 4)
                } header: { FormHeader("Tap a day you can't work") } footer: {
                    Text("Teal days have a shift booked. Blocked days are saved, and HowMuch warns you if you book a shift on one.").formFootnote()
                }
                Section(styled: "Your message") {
                    Text(text).font(.appBody).textSelection(.enabled).accessibilityIdentifier("availability.text")
                    ShareLink(item: text) { Label("Share to WhatsApp or Telegram", systemImage: "square.and.arrow.up") }
                    Button(copied ? "Copied" : "Copy message", systemImage: copied ? "checkmark" : "doc.on.doc") { UIPasteboard.general.string = text; copied = true }
                        .accessibilityIdentifier("availability.copy")
                }
            }.detailStyle("Share availability")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { save(); dismiss() } } }
                .onAppear { blocked = store.data.settings.blocked }
                .onDisappear { save() }
                .onChange(of: blocked) { _, _ in copied = false }
        }
    }
    private func dayButton(_ date: Date) -> some View {
        let key = Shift.dayString(date)
        let state = Availability.day(key, shifts: store.data.shifts, blocked: [])
        let isBlocked = blocked.contains(key)
        return Button {
            if isBlocked { blocked.remove(key) } else { blocked.insert(key) }
        } label: {
            Text("\(TrackerCalendar.calendar.component(.day, from: date))").font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(isBlocked ? .white : Palette.ink)
                .background(isBlocked ? Color.red.opacity(0.75) : state == .free ? Palette.mint.opacity(0.6) : Palette.teal.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) { if isBlocked { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white).padding(3) } }
        }.buttonStyle(.plain)
            .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).day().month(.wide)) + (isBlocked ? ", blocked" : state == .free ? ", free" : ", has a shift"))
            .accessibilityIdentifier("availability.day.\(key)")
    }
    private func save() {
        // Keep today and future blocks; past ones no longer matter.
        let today = Shift.dayString(Date())
        let next = blocked.filter { $0 >= today }.sorted()
        guard next != (store.data.settings.blockedDays ?? []).filter({ $0 >= today }).sorted() else { return }
        store.updatePreferences { $0.blockedDays = Array(next.prefix(400)) }
    }
}
