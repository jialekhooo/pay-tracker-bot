import SwiftUI
import HowMuchCore

struct EarningsView: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var scope = "All time"
    @State private var grouping = "Events"
    @State private var filter = "All events"
    @State private var date = Date()
    @State private var currency = "SGD"
    @State private var newest = true
    @State private var upcomingAscending = true
    private var shifts: [Shift] {
        store.data.shifts.filter { shift in
            guard shift.currency == currency else { return false }
            switch scope {
            case "Day": return shift.day == Shift.dayString(date)
            case "Week":
                // Half-open: a shift starting at midnight on Monday belongs to the new week only.
                guard let week = TrackerCalendar.calendar.dateInterval(of: .weekOfYear, for: date) else { return false }
                return week.start <= shift.startDate && shift.startDate < week.end
            case "Month": return shift.day.hasPrefix(String(Shift.dayString(date).prefix(7)))
            default: return true
            }
        }
    }
    private var eventNames: [String] {
        Dictionary(grouping: shifts, by: { $0.event.lowercased() }).values.compactMap { $0.first?.event }.filter { name in
            let items = shifts.filter { $0.event.caseInsensitiveCompare(name) == .orderedSame }
            let done = items.allSatisfy { $0.endDate <= Date() }
            let upcoming = items.allSatisfy { $0.startDate > Date() }
            switch filter {
            case "Ongoing": return !done && !upcoming
            case "Upcoming": return items.contains { $0.endDate > Date() }
            case "Unpaid": return done && items.contains { !$0.paid }
            case "Paid out": return done && items.allSatisfy(\.paid)
            default: return true
            }
        }.sorted { left, right in
            let a = shifts.filter { $0.event.caseInsensitiveCompare(left) == .orderedSame }.map(\.day).max() ?? ""
            let b = shifts.filter { $0.event.caseInsensitiveCompare(right) == .orderedSame }.map(\.day).max() ?? ""
            return a == b ? left < right : (newest ? a > b : a < b)
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { clock in
            ScreenShell(title: "Earnings", subtitle: "Every shift, every dollar.") {
                PillPicker(values: ["Day", "Week", "Month", "All time"], selection: $scope, onDark: false)
                if scope != "All time" { PeriodNavigator(label: periodLabel, dark: false, previous: { move(-1) }, next: { move(1) }) }
                if store.data.currencies.count > 1 { PillPicker(values: store.data.currencies, selection: $currency, onDark: false) }
                EarningsHero(shifts: shifts, currency: currency, label: scope == "All time" ? "ALL-TIME EARNINGS" : "\(scope.uppercased()) EARNINGS", now: clock.date)
                if scope == "All time" {
                    PillPicker(values: ["Events", "Months"], selection: $grouping)
                    if grouping == "Events" {
                        PillPicker(values: ["All events", "Ongoing", "Upcoming", "Unpaid", "Paid out"], selection: $filter)
                        if filter == "Upcoming" {
                            UpcomingGroupingControl()
                            HStack {
                                SectionHeading(title: "Upcoming work", detail: counted(shifts.filter { $0.endDate > Date() }.count, "shift"))
                                Button { upcomingAscending.toggle() } label: { Image(systemName: upcomingAscending ? "arrow.up" : "arrow.down") }.iconAction().accessibilityLabel(upcomingAscending ? "Earliest first" : "Latest first")
                            }
                            UpcomingWorkList(shifts: shifts.filter { $0.endDate > Date() }, ascending: upcomingAscending)
                        } else {
                            HStack { SectionHeading(title: "Your work events", detail: "\(eventNames.count)"); Button { newest.toggle() } label: { Image(systemName: newest ? "arrow.down" : "arrow.up") }.iconAction().accessibilityLabel(newest ? "Most recent first" : "Oldest first") }
                            ForEach(eventNames, id: \.self) { name in
                                NavigationLink { EventDetailView(event: name, currency: currency) } label: { EventCard(event: name, currency: currency, showsDisclosure: true) }.buttonStyle(.plain)
                            }
                            if eventNames.isEmpty { EmptyCard(title: "Nothing in this view", message: "Your events will appear here as you add shifts.", symbol: "chart.bar") }
                        }
                    } else {
                        ForEach(Array(Set(shifts.map { String($0.day.prefix(7)) })).sorted(by: >), id: \.self) { month in
                            let records = shifts.filter { $0.day.hasPrefix(month) }
                            NavigationLink { PeriodShiftsView(month: month, currency: currency) } label: {
                                Card {
                                    HStack {
                                        Image(systemName: "calendar").foregroundStyle(Palette.teal)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(TrackerCalendar.localDate(month + "-01")?.formatted(.dateTime.month(.wide).year()) ?? month).font(.appHeadline)
                                            Text("\(counted(records.count, "shift")) · \(PayEngine.rounded(records.reduce(0) { $0 + $1.hours }))h").font(.caption).foregroundStyle(Palette.muted)
                                        }
                                        Spacer()
                                        Text(money(records.reduce(0) { $0 + $1.total }, currency)).font(.subheadline.bold())
                                        Image(systemName: "chevron.right").font(.chevron)
                                    }.foregroundStyle(Palette.ink)
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("earnings.month.\(month)")
                        }
                        if shifts.isEmpty { EmptyCard(title: "Your monthly breakdown", message: "Add your first shift to start tracking earnings by month.") }
                    }
                } else if shifts.isEmpty { EmptyCard(title: "No shifts for this period", message: "Use the arrows to browse another \(scope.lowercased()).") }
                else { ShiftCards(shifts: shifts.sorted { $0.startDate < $1.startDate }) }
            }
        }.onAppear { currency = store.data.rules.currency }
    }
    private var periodLabel: String {
        if scope == "Day" { return date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide)) }
        if scope == "Week", let interval = TrackerCalendar.calendar.dateInterval(of: .weekOfYear, for: date) {
            let end = TrackerCalendar.calendar.date(byAdding: .day, value: -1, to: interval.end)!
            return "\(interval.start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
    private func move(_ amount: Int) { date = TrackerCalendar.calendar.date(byAdding: scope == "Day" ? .day : scope == "Week" ? .weekOfYear : .month, value: amount, to: date)! }
}

struct EventCard: View {
    @EnvironmentObject private var store: TrackerStore
    let event: String
    let currency: String
    var showsDisclosure = false
    private var shifts: [Shift] { store.data.shifts.filter { $0.event.caseInsensitiveCompare(event) == .orderedSame && $0.currency == currency } }
    private var claims: [CabClaim] { store.data.claims.filter { claim in shifts.contains { $0.id == claim.shiftID } } }
    var body: some View {
        let earnings = shifts.reduce(Decimal.zero) { $0 + $1.total }
        let cabs = claims.reduce(Decimal.zero) { $0 + $1.amount }
        let completed = shifts.allSatisfy { $0.endDate <= Date() }
        let paid = completed && shifts.allSatisfy(\.paid)
        Card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event).font(.appHeadline).foregroundStyle(Palette.ink)
                    Text("\(shifts.count) \(shifts.count == 1 ? "shift" : "shifts") · \(displayDay(shifts.map(\.day).max() ?? ""))").font(.caption).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                if showsDisclosure { Image(systemName: "chevron.right").font(.chevron).foregroundStyle(Palette.muted).padding(.top, 3) }
            }
            let locations = Array(Set(shifts.map(\.location).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted()
            Label(locations.count == 1 ? locations[0] : locations.isEmpty ? "No location added" : "\(locations.count) locations", systemImage: "mappin.and.ellipse")
                .font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Work earnings").font(.caption).foregroundStyle(Palette.muted)
                    Text(money(earnings, currency)).font(.appTitle).foregroundStyle(Palette.ink).minimumScaleFactor(0.65).lineLimit(1)
                }
                Spacer(minLength: 0)
                StatusPill(title: paid ? "Paid" : completed ? "Awaiting payment" : shifts.allSatisfy { $0.startDate > Date() } ? "Upcoming" : "In progress", paid: paid)
            }
            if cabs > 0 {
                Divider()
                HStack {
                    Label("+" + money(cabs, currency) + " claims", systemImage: "receipt").foregroundStyle(Palette.teal)
                    Spacer(minLength: 4)
                    Text("Est. credit " + money(earnings + cabs, currency)).foregroundStyle(Palette.muted)
                }.font(.caption)
            }
        }
    }
}

struct EventDetailView: View {
    @EnvironmentObject private var store: TrackerStore
    let event: String
    let currency: String
    @State private var currentEvent: String
    @State private var anchorID: UUID?
    @State private var editingDetails = false
    @State private var directions = false
    init(event: String, currency: String) {
        self.event = event; self.currency = currency
        _currentEvent = State(initialValue: event)
    }
    private var activeEvent: String { store.data.shifts.first(where: { $0.id == anchorID })?.event ?? currentEvent }
    private var locations: [String] { Array(Set(shifts.map(\.location).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted() }
    private var shifts: [Shift] { store.data.shifts.filter { $0.event.caseInsensitiveCompare(activeEvent) == .orderedSame && $0.currency == currency }.sorted { $0.startDate < $1.startDate } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                EventCard(event: activeEvent, currency: currency)
                EventMoneySummary(event: activeEvent, currency: currency)
                Card {
                    Label("EVENT LOCATION", systemImage: "mappin.and.ellipse").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.muted)
                    if locations.isEmpty { Text("No location added").font(.subheadline).foregroundStyle(Palette.muted) }
                    ForEach(locations, id: \.self) { location in Text(location).font(.subheadline).foregroundStyle(Palette.ink) }
                    if locations.count == 1 { Button("Map & directions", systemImage: "map") { directions = true }.glassAction() }
                    Button("Edit event details", systemImage: "pencil") { editingDetails = true }.glassAction().accessibilityIdentifier("event.editDetails")
                        .disabled(shifts.isEmpty)
                    Text("Name and location are shared across all shifts in this event.").font(.caption).foregroundStyle(Palette.muted)
                }
                Card { EventPayerRow(event: activeEvent) }
                if !shifts.isEmpty && shifts.allSatisfy({ $0.endDate <= Date() }) {
                    Button(shifts.allSatisfy(\.paid) ? "Mark event as unpaid" : "Mark event as paid", systemImage: "checkmark.circle") {
                        let paid = !shifts.allSatisfy(\.paid)
                        store.update { data in for index in data.shifts.indices where data.shifts[index].event.caseInsensitiveCompare(activeEvent) == .orderedSame && data.shifts[index].currency == currency { data.shifts[index].paid = paid } }
                    }.primaryButton()
                    if store.canUndo { Button("Undo payment change", systemImage: "arrow.uturn.backward") { store.undo() }.font(.caption).rowAction() }
                }
                SectionHeading(title: "Shifts")
                ShiftCards(shifts: shifts)
                ReimbursementsSection(shifts: shifts, currency: currency)
                if store.canUndo { Button("Undo last change", systemImage: "arrow.uturn.backward") { store.undo() }.glassAction() }
            }.padding(20)
        }.accessibilityIdentifier("event.detail").detailStyle(activeEvent)
            .onAppear {
                if anchorID == nil { anchorID = shifts.first?.id }
            }
            .onChange(of: activeEvent) { _, name in
                currentEvent = name
            }
            .sheet(isPresented: $editingDetails) { EventDetailsEditor(event: activeEvent) }
            .sheet(isPresented: $directions) { if let location = locations.first { JobDirectionsView(location: location) } }
    }
}

struct PeriodShiftsView: View {
    @EnvironmentObject private var store: TrackerStore
    let month: String
    let currency: String
    private var shifts: [Shift] { store.data.shifts.filter { $0.day.hasPrefix(month) && $0.currency == currency } }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForEach(Array(Set(shifts.map(\.currency))).sorted(), id: \.self) { currency in EarningsHero(shifts: shifts.filter { $0.currency == currency }, currency: currency) }
                if shifts.isEmpty { EmptyCard() } else { ShiftCards(shifts: shifts.sorted { $0.startDate < $1.startDate }) }
            }.padding(20)
        }.detailStyle(TrackerCalendar.localDate(month + "-01")?.formatted(.dateTime.month(.wide).year()) ?? month)
    }
}

struct EventDetailsEditor: View {
    @EnvironmentObject private var store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    let event: String
    @State private var name = ""
    @State private var location = ""
    @State private var initialLocation = ""
    @State private var clearLocation = false
    @State private var findingLocation = false
    @State private var loaded = false
    @State private var error: String?
    private var shifts: [Shift] { store.data.shifts.filter { $0.event.caseInsensitiveCompare(event) == .orderedSame } }
    private var locations: [String] { Array(Set(shifts.map(\.location))).sorted() }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Card {
                        Label("EVENT DETAILS", systemImage: "briefcase").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.muted)
                        TextField("Event name", text: $name).font(.system(.title3, design: .rounded, weight: .semibold)).frame(minHeight: 48)
                        Divider()
                        TextField("Location (optional)", text: $location).font(.subheadline).frame(minHeight: 48)
                        Button("Find a place in Apple Maps", systemImage: "map") { findingLocation = true }.glassAction().accessibilityIdentifier("event.findLocation")
                        if locations.count > 1 {
                            Text("These shifts currently have different locations. Enter a shared location to replace them all.").font(.caption).foregroundStyle(Palette.muted)
                            ForEach(locations, id: \.self) { value in Text(value.isEmpty ? "No location" : value).font(.caption).foregroundStyle(Palette.muted) }
                        }
                        Button("Clear location for all shifts", role: .destructive) { location = ""; clearLocation = true }.rowAction().font(.subheadline)
                    }
                    Text("Saving updates the name and changed location for all \(shifts.count) shifts in this event, including other currencies. Dates, hours, rates, paid status and claims are kept.").font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 4)
                    if let error { Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.red) }
                }.padding(20)
            }.detailStyle("Edit event details").scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        if store.update({ data in
                            try data.updateEventDetails(event: event, name: name, location: clearLocation || location != initialLocation ? location : nil)
                        }) { dismiss() } else { error = store.error }
                    } }
                }
                .sheet(isPresented: $findingLocation) { JobLocationPicker(initial: location) { location = $0 } }
                .onAppear {
                    if !loaded { name = event; location = locations.count == 1 ? locations[0] : ""; initialLocation = location; loaded = true }
                }
                .onChange(of: [name, location]) { _, _ in error = nil }
        }
    }
}


struct EventMoneySummary: View {
    @EnvironmentObject private var store: TrackerStore
    let event: String
    let currency: String
    private var summary: EventFinancialSummary { EventFinancialSummary(data: store.data, event: event, currency: currency) }
    var body: some View {
        Card {
            Label("EVENT SUMMARY", systemImage: "chart.bar.xaxis").font(.caption.weight(.semibold)).foregroundStyle(Palette.teal)
            Text(money(summary.netWorkPay, currency)).font(.amount).foregroundStyle(Palette.ink).accessibilityIdentifier("event.netWork")
            Text("Work earnings · including scheduled shifts").font(.caption).foregroundStyle(Palette.muted)
            Divider()
            LabeledContent("Work pay", value: money(summary.workPay, currency))
            LabeledContent("Reimbursements", value: money(summary.reimbursements, currency))
            LabeledContent("Expected bank credit", value: money(summary.expectedCredit, currency))
            LabeledContent("Paid hours", value: "\(PayEngine.rounded(summary.paidHours))")
            if let hourly = summary.effectiveHourly { LabeledContent("Effective hourly rate", value: money(hourly, currency)).accessibilityIdentifier("event.effectiveHourly") }
            Text("Cab, food and miscellaneous claims are reimbursements. They are added to your expected bank credit and do not reduce your work earnings.").font(.caption).foregroundStyle(Palette.muted)
        }
    }
}
