import SwiftUI
import HowMuchCore

struct ContentView: View {
    @State private var tab = "Overview"
    @State private var navigationID = UUID()
    @State private var widgetPath: [WidgetLink] = []
    @ObservedObject private var push = PushCenter.shared
    @State private var calendarDay = Date()
    @State private var adding = false
    @State private var finishing: Shift?
    @State private var shared: SharedMessage?
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: TrackerStore
    var body: some View {
        NavigationStack(path: $widgetPath) {
            ZStack {
                AppBackdrop()
                Group {
                    switch tab {
                    case "Earnings": EarningsView()
                    case "Calendar": WorkCalendarView(initialDay: calendarDay)
                    case "Settings": SettingsView()
                    default: DashboardView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    navigationDock.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
                }
            }
            .navigationDestination(for: WidgetLink.self) { route in
            switch route {
            case .shift(let id): ShiftDetailView(shiftID: id)
            case .event(let id):
                if let shift = store.data.shifts.first(where: { $0.id == id }) { EventDetailView(event: shift.event, currency: shift.currency) }
                else { Text("This event is no longer available.") }
            case .earnings: EarningsView()
            case .calendar(let day): WorkCalendarView(initialDay: TrackerCalendar.localDate(day) ?? Date())
            case .finish(let id): ShiftDetailView(shiftID: id)
            }
        }
        }
        .id(navigationID)
        .task(id: push.widgetURL) {
            guard let url = push.widgetURL else { return }
            push.widgetURL = nil
            guard let route = WidgetLink.parse(url, accountID: store.accountID) else { return }
            if case .finish(let id) = route {
                if let shift = store.data.shifts.first(where: { $0.id == id && $0.endDate <= Date() }) { adding = false; finishing = shift }
                else { widgetPath = [.shift(id)] }
                return
            }
            adding = false; widgetPath = []; navigationID = UUID()
            if case .calendar(let day) = route { calendarDay = TrackerCalendar.localDate(day) ?? Date(); tab = "Calendar" }
            else if route == .earnings { tab = "Earnings" }
            else { widgetPath = [route] }
        }
        .task(id: push.addJobRequest) {
            // Siri or Control Center: open Add shift, filled in when a job message is on the clipboard.
            guard push.addJobRequest != nil else { return }
            push.addJobRequest = nil
            finishing = nil; shared = nil; adding = false
            try? await Task.sleep(for: .milliseconds(400))
            if UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string,
               !JobMessageParser.parse(text).dates.isEmpty { shared = SharedMessage(text: text) }
            else { adding = true }
        }
        .sheet(isPresented: $adding) { ShiftEditor() }
        .sheet(item: $finishing, onDismiss: askNextFinish) { FinishShiftSheet(shift: $0) }
        .sheet(item: $shared) { ShiftEditor(initialMessage: $0.text) }
        .onChange(of: scenePhase) { _, value in if value == .active { store.refreshReminders(); store.refreshWidgets(); refreshLiveShift() } }
        .task {
            // Keeps the Lock Screen card in step while the app stays open across a shift's start or end.
            while !Task.isCancelled {
                refreshLiveShift()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
    private func refreshLiveShift() {
        LiveShiftCenter.sync(store.data, accountID: store.accountID)
        // A job shared from WhatsApp or another app comes first.
        if shared == nil, finishing == nil, !adding, UIApplication.shared.applicationState == .active, let text = SharedJobInbox.take() {
            shared = SharedMessage(text: text); return
        }
        askNextFinish()
    }
    private func askNextFinish() {
        // Ask the app directly: the minute timer holds a launch-time copy of scenePhase.
        guard finishing == nil, shared == nil, !adding, UIApplication.shared.applicationState == .active, push.widgetURL == nil else { return }
        finishing = LiveShiftCenter.nextToConfirm(store.data, accountID: store.accountID)
    }
    private var navigationDock: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                nav("Overview", "house")
                nav("Earnings", "chart.bar.xaxis")
                nav("Calendar", "calendar")
                nav("Settings", "gearshape")
            }.padding(5).glassChrome(in: Capsule())
            Button { adding = true } label: {
                Image(systemName: "plus").font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.white).frame(width: 58, height: 58).contentShape(Circle())
                    .glassChrome(in: Circle(), tint: Palette.teal)
            }.buttonStyle(.plain).accessibilityLabel("Add shift").accessibilityIdentifier("nav.add")
        }
    }
    private func nav(_ name: String, _ icon: String) -> some View {
        Button { tab = name } label: {
            VStack(spacing: 4) {
                // A fixed icon box keeps every label on the same line, whatever the symbol's height.
                Image(systemName: icon).font(.system(size: 19, weight: tab == name ? .semibold : .regular)).frame(height: 22)
                Text(name).font(.system(size: 9, weight: tab == name ? .bold : .medium)).lineLimit(1)
            }.foregroundStyle(tab == name ? Palette.teal : Palette.muted)
                .frame(maxWidth: .infinity, minHeight: 48).contentShape(Capsule())
                .background(tab == name ? Palette.mint.opacity(0.95) : Color.clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel(name).accessibilityIdentifier("nav.\(name.lowercased())")
            .accessibilityAddTraits(tab == name ? .isSelected : [])
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var period = "All time"
    @State private var month = Date()
    @State private var currency = "SGD"
    private var shifts: [Shift] {
        store.data.shifts.filter {
            $0.currency == currency && (period == "All time" || $0.day.hasPrefix(String(Shift.dayString(month).prefix(7))))
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { clock in
            ScreenShell(title: "Overview", subtitle: "Your work. Your worth.") {
                PillPicker(values: ["All time", "By month"], selection: $period, onDark: false)
                if period == "By month" {
                    PeriodNavigator(label: month.formatted(.dateTime.month(.wide).year()), dark: false,
                                    previous: { moveMonth(-1) }, next: { moveMonth(1) })
                }
                if store.data.currencies.count > 1 { PillPicker(values: store.data.currencies, selection: $currency, onDark: false) }
                EarningsHero(shifts: shifts, currency: currency, label: period == "All time" ? "ALL-TIME EARNINGS" : month.formatted(.dateTime.month(.wide)).uppercased() + " EARNINGS", now: clock.date)
                if period == "All time" {
                HStack(spacing: 12) {
                    NavigationLink { ShiftBrowser(mode: "Worked this month") } label: {
                        GlanceCard(title: "Worked this month", value: hoursText(workedHours(clock.date)), symbol: "clock")
                    }
                    NavigationLink { ShiftBrowser(mode: "Upcoming shifts") } label: {
                        let next = store.data.shifts.filter { $0.currency == currency && $0.endDate > clock.date && $0.day.hasPrefix(String(Shift.dayString(clock.date).prefix(7))) }
                        GlanceCard(title: "Left to earn this month", value: money(next.reduce(0) { $0 + $1.pay - $1.earned(at: clock.date) }, currency), symbol: "arrow.up.right")
                    }.accessibilityIdentifier("overview.upcoming")
                }.buttonStyle(.plain)
                // Today first: what's on now or later today (including an overnight shift that started yesterday).
                let todayShifts = store.data.shifts.filter { $0.day == Shift.dayString(clock.date) || ($0.startDate <= clock.date && clock.date < $0.endDate) }
                    .sorted { $0.startDate < $1.startDate }
                if !todayShifts.isEmpty {
                    SectionHeading(title: "Today", detail: clock.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    ShiftCards(shifts: todayShifts)
                }
                let tomorrow = TrackerCalendar.calendar.date(byAdding: .day, value: 1, to: clock.date)!
                let tomorrowShifts = store.data.shifts.filter { $0.day == Shift.dayString(tomorrow) }.sorted { $0.startMinute < $1.startMinute }
                let tomorrowLabel = tomorrow.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                if !tomorrowShifts.isEmpty {
                    SectionHeading(title: "Tomorrow", detail: tomorrowLabel)
                    UpcomingWorkList(shifts: tomorrowShifts)
                } else if let next = store.data.shifts.filter({ $0.startDate > clock.date && $0.day > Shift.dayString(tomorrow) }).min(by: { $0.startDate < $1.startDate }) {
                    // Nothing tomorrow: point to the next booked day instead of an empty card.
                    let calendar = TrackerCalendar.calendar
                    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: clock.date), to: calendar.startOfDay(for: next.startDate)).day ?? 0
                    SectionHeading(title: "Next up", detail: "in \(counted(days, "day"))")
                    UpcomingWorkList(shifts: store.data.shifts.filter { $0.day == next.day }.sorted { $0.startMinute < $1.startMinute })
                } else {
                    SectionHeading(title: "Tomorrow", detail: tomorrowLabel)
                    EmptyCard(message: "Nothing booked for tomorrow. Your next opportunity is ahead.")
                }
                } else {
                    SectionHeading(title: month.formatted(.dateTime.month(.wide)), detail: counted(shifts.count, "shift"))
                    if shifts.isEmpty { EmptyCard(title: "No shifts this month", message: "Browse another month or add your first shift.") }
                    else { ShiftCards(shifts: shifts.sorted { $0.startDate < $1.startDate }) }
                }
                SectionHeading(title: "Your shifts", detail: "\(store.data.shifts.count) total")
                NavigationLink { ShiftsView() } label: {
                    Card { HStack { Label("Browse all shifts", systemImage: "list.bullet.rectangle"); Spacer(); Image(systemName: "arrow.right") }.font(.subheadline.weight(.semibold)).foregroundStyle(Palette.teal) }
                }.buttonStyle(.plain).accessibilityIdentifier("browse.shifts")
                let unpaid = store.data.shifts.filter { !$0.paid && $0.endDate <= clock.date && $0.currency == currency }
                if !unpaid.isEmpty {
                    SectionHeading(title: "Awaiting payment", detail: money(unpaid.reduce(0) { $0 + $1.pay }, currency))
                    ShiftCards(shifts: Array(unpaid.sorted { ($0.paymentDue ?? $0.day) < ($1.paymentDue ?? $1.day) }.prefix(3)))
                }
            }
        }.onAppear { currency = store.data.rules.currency }
    }
    private func moveMonth(_ value: Int) { month = TrackerCalendar.calendar.date(byAdding: .month, value: value, to: month)! }
    private func workedHours(_ now: Date) -> Decimal {
        let key = String(Shift.dayString(now).prefix(7))
        return PayEngine.rounded(store.data.shifts.filter { $0.day.hasPrefix(key) && $0.startDate < now }.reduce(0) { result, shift in
            let fraction = min(1, max(0, now.timeIntervalSince(shift.startDate) / shift.endDate.timeIntervalSince(shift.startDate)))
            return result + shift.hours * Decimal(fraction)
        })
    }
}

struct EarningsHero: View {
    let shifts: [Shift]
    let currency: String
    var label = "TOTAL EARNINGS"
    var now = Date()
    var body: some View {
        let total = shifts.reduce(Decimal.zero) { $0 + $1.pay }
        let earned = shifts.reduce(Decimal.zero) { $0 + $1.earned(at: now) }
        Card {
            HStack {
                Text(label).font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(Palette.muted)
                Spacer()
                Image(systemName: "wallet.bifold").font(.system(size: 21, weight: .light)).foregroundStyle(Palette.teal)
            }
            Text(money(total, currency)).font(.system(size: 40, weight: .bold, design: .rounded)).tracking(-1.5)
                .minimumScaleFactor(0.5).lineLimit(1).foregroundStyle(Palette.ink).accessibilityIdentifier("earnings.total")
            Text("\(PayEngine.rounded(shifts.reduce(0) { $0 + $1.hours })) hours · \(counted(shifts.count, "shift"))")
                .font(.caption).foregroundStyle(Palette.muted)
            Divider().overlay(Palette.line)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Earned so far").font(.caption2).foregroundStyle(Palette.muted)
                    Text(money(earned, currency)).font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Palette.teal)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("Still to come").font(.caption2).foregroundStyle(Palette.muted)
                    Text(money(total - earned, currency)).font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Palette.ink)
                }
            }
        }
    }
}

struct GlanceCard: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        Card {
            HStack { Image(systemName: symbol).font(.caption).foregroundStyle(Palette.teal); Spacer(); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted) }
            Text(value).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}

struct ShiftsView: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var search = ""
    @State private var filter = "All"
    @State private var ascending = false
    private var shifts: [Shift] {
        store.data.shifts.filter { shift in
            (search.isEmpty || shift.event.localizedCaseInsensitiveContains(search) || shift.location.localizedCaseInsensitiveContains(search)) &&
            (filter == "All" || (filter == "Upcoming" && shift.endDate > Date()) || (filter == "Unpaid" && !shift.paid && shift.endDate <= Date()))
        }.sorted { ascending ? $0.startDate < $1.startDate : $0.startDate > $1.startDate }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PillPicker(values: ["All", "Upcoming", "Unpaid"], selection: $filter)
                UpcomingGroupingControl()
                HStack { Text(counted(shifts.count, "shift")).font(.caption).foregroundStyle(Palette.muted); Spacer(); Button(ascending ? "Earliest first" : "Latest first", systemImage: "arrow.up.arrow.down") { ascending.toggle() }.font(.caption) }
                if shifts.isEmpty { EmptyCard(title: "No shifts here", message: "Try another search or add a new shift.") }
                else if filter == "Upcoming" { UpcomingWorkList(shifts: shifts, ascending: ascending) }
                else if store.data.settings.groupUpcomingByEvent ?? false { groupedCards }
                else { ShiftCards(shifts: shifts) }
            }.padding(20)
        }.searchable(text: $search, prompt: "Event or location").detailStyle("All shifts")
            .onChange(of: filter) { _, value in if value == "Upcoming" { ascending = true } }
    }
    private var groupedCards: some View {
        let groups = Dictionary(grouping: shifts) { $0.currency + "|" + $0.event.lowercased() }
        let keys = groups.keys.sorted { a, b in
            let left = groups[a]!.first!.startDate, right = groups[b]!.first!.startDate
            return left == right ? a < b : ascending ? left < right : left > right
        }
        return VStack(spacing: 12) {
            ForEach(keys, id: \.self) { key in
                let items = groups[key]!
                let first = items[0]
                NavigationLink { EventDetailView(event: first.event, currency: first.currency) } label: {
                    Card {
                        HStack(alignment: .firstTextBaseline) {
                            Text(first.event).font(.headline)
                            Spacer()
                            Text(money(items.reduce(Decimal.zero) { $0 + $1.pay }, first.currency)).font(.headline)
                        }.foregroundStyle(Palette.ink)
                        HStack {
                            Text("\(items.count) \(items.count == 1 ? "shift" : "shifts")").font(.caption)
                            Spacer()
                            Text(displayDay(first.day)).font(.caption)
                            Image(systemName: "chevron.right").font(.caption)
                        }.foregroundStyle(Palette.muted)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("shifts.event." + key)
            }
        }
    }

}

struct ShiftBrowser: View {
    @EnvironmentObject private var store: TrackerStore
    let mode: String
    @State private var range = "All time"
    @State private var ascending = true
    private var shifts: [Shift] {
        let now = Date()
        return store.data.shifts.filter { shift in
            if mode == "Worked this month" { return shift.startDate < now && shift.day.hasPrefix(String(Shift.dayString(now).prefix(7))) }
            if shift.endDate <= now { return false }
            if range == "All time" { return true }
            if range == "Tomorrow" { return shift.day == Shift.dayString(TrackerCalendar.calendar.date(byAdding: .day, value: 1, to: now)!) }
            let days = Int(range.split(separator: " ")[0]) ?? 7
            return shift.startDate < TrackerCalendar.calendar.date(byAdding: .day, value: days, to: now)!
        }.sorted { ascending ? $0.startDate < $1.startDate : $0.startDate > $1.startDate }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if mode == "Upcoming shifts" {
                    PillPicker(values: ["Tomorrow", "7 days", "14 days", "30 days", "All time"], selection: $range)
                    UpcomingGroupingControl()
                }
                HStack { Text(counted(shifts.count, "shift")).font(.caption); Spacer(); Button(ascending ? "Earliest first" : "Latest first", systemImage: "arrow.up.arrow.down") { ascending.toggle() }.font(.caption) }
                if mode == "Upcoming shifts" { UpcomingWorkList(shifts: shifts, ascending: ascending) }
                else if shifts.isEmpty { EmptyCard() } else { ShiftCards(shifts: shifts) }
            }.padding(20)
        }.detailStyle(mode)
    }
}

struct UpcomingGroupingControl: View {
    @EnvironmentObject private var store: TrackerStore
    var body: some View {
        Card {
            Toggle("Group by events", isOn: Binding(get: { store.data.settings.groupUpcomingByEvent ?? false }, set: { value in
                store.updatePreferences { $0.groupUpcomingByEvent = value }
            })).font(.subheadline.weight(.semibold)).frame(minHeight: 44).accessibilityIdentifier("upcoming.groupEvents")
            Text("See one card per event, or switch off to browse individual shifts.").font(.caption).foregroundStyle(Palette.muted)
        }
    }
}

struct UpcomingWorkList: View {
    @EnvironmentObject private var store: TrackerStore
    let shifts: [Shift]
    var ascending = true
    private var groups: [UpcomingEventGroup] { UpcomingEvents.groups(shifts, now: Date(), ascending: ascending) }
    var body: some View {
        if groups.isEmpty { EmptyCard(title: "No upcoming shifts", message: "Your next shifts will appear here.") }
        else if store.data.settings.groupUpcomingByEvent ?? false {
            VStack(spacing: 12) {
                ForEach(groups) { group in
                    NavigationLink { UpcomingEventDetail(group: group) } label: {
                        UpcomingEventCard(group: group, navigates: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("upcoming.event.\(group.id)")
                }
            }
        } else { ShiftCards(shifts: shifts.filter { $0.endDate > Date() }.sorted { ascending ? $0.startDate < $1.startDate : $0.startDate > $1.startDate }) }
    }
}

struct UpcomingEventCard: View {
    let group: UpcomingEventGroup
    var navigates = false
    var body: some View {
        let next = group.shifts[0]
        let locations = Array(Set(group.shifts.map(\.location).filter { !$0.isEmpty })).sorted()
        Card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.event).font(.system(.headline, design: .rounded)).foregroundStyle(Palette.ink)
                    Text("\(group.shifts.count) upcoming \(group.shifts.count == 1 ? "shift" : "shifts")").font(.caption).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                if navigates { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted) }
            }
            Label(next.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " · " + Shift.clock(next.startMinute) + "–" + Shift.clock(next.endMinute) + (next.endMinute <= next.startMinute ? " (+1 day)" : ""), systemImage: "calendar").font(.caption).foregroundStyle(Palette.muted)
            if !locations.isEmpty {
                Label(locations.count == 1 ? locations[0] : "\(locations.count) locations", systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scheduled work pay").font(.caption).foregroundStyle(Palette.muted)
                    Text(money(group.scheduledPay, group.currency)).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink)
                }
                Spacer()
                StatusPill(title: next.startDate <= Date() ? "Working now" : "Upcoming")
            }
        }
    }
}

struct UpcomingEventDetail: View {
    @EnvironmentObject private var store: TrackerStore
    let group: UpcomingEventGroup
    private var shifts: [Shift] {
        let ids = Set(group.shifts.map(\.id))
        return store.data.shifts.filter { ids.contains($0.id) && $0.currency == group.currency && $0.endDate > Date() }.sorted { $0.startDate < $1.startDate }
    }
    private var event: String { shifts.first?.event ?? group.event }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let summary = UpcomingEvents.groups(shifts, now: Date()).first {
                    UpcomingEventCard(group: summary)
                    Text("Upcoming shifts in the selected date range. Completed work and claims are excluded from scheduled work pay.").font(.caption).foregroundStyle(Palette.muted)
                    ShiftCards(shifts: shifts)
                    NavigationLink { EventDetailView(event: event, currency: group.currency) } label: {
                        Label("View all event earnings", systemImage: "chart.bar.xaxis").frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.teal)
                } else { EmptyCard(title: "No upcoming shifts", message: "These shifts have ended or were removed.") }
            }.padding(20)
        }.detailStyle(event).accessibilityIdentifier("upcoming.eventDetail")
    }
}

private struct SharedMessage: Identifiable {
    let id = UUID()
    let text: String
}
