import SwiftUI
import HowMuchCore

struct WorkCalendarView: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var month = Date()
    @State private var selected = Date()
    @State private var adding = false
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
                NavigationLink { CalendarSettingsView() } label: { Label("Export", systemImage: "square.and.arrow.up").font(.caption.bold()) }.accessibilityIdentifier("calendar.export")
            }
            SectionHeading(title: selected.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)), detail: counted(selectedShifts.count, "shift"))
            if selectedShifts.isEmpty { EmptyCard(title: "A day with possibilities", message: "No shifts booked for this date.") }
            else { ShiftCards(shifts: selectedShifts) }
            Button("Add shift on this day", systemImage: "plus") { adding = true }.glassAction().accessibilityIdentifier("calendar.add")
        }.sheet(isPresented: $adding) { ShiftEditor(initialDay: selected) }
    }
    private func move(_ amount: Int) {
        month = TrackerCalendar.calendar.date(byAdding: .month, value: amount, to: month)!
        let components = TrackerCalendar.calendar.dateComponents([.year, .month], from: month)
        selected = TrackerCalendar.calendar.date(from: components)!
    }
}
