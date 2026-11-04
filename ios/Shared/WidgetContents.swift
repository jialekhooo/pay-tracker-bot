import SwiftUI
import WidgetKit
import HowMuchCore

enum HowMuchWidgetKind: String, CaseIterable { case nextShift, events, month, calendar }

struct HowMuchWidgetContents: View {
    let snapshot: WidgetSnapshot?
    let date: Date
    let kind: HowMuchWidgetKind
    let family: WidgetFamily
    var currency: String? = nil
    var showPay = false
    var showLocation = true
    @Environment(\.colorScheme) private var colorScheme
    private var jade: Color { colorScheme == .dark ? Color(red: 0.53, green: 0.9, blue: 0.76) : Color(red: 0.04, green: 0.39, blue: 0.34) }
    private var valid: WidgetSnapshot? { snapshot.flatMap { $0.isCurrent(at: date) ? $0 : nil } }
    private var accessory: Bool { family == .accessoryInline || family == .accessoryRectangular || family == .accessoryCircular }
    var body: some View {
        Group {
            if let data = valid {
                switch kind {
                case .nextShift: nextShift(data)
                case .events: events(data)
                case .month: month(data)
                case .calendar: calendarWidget(data)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !accessory { brand("HOWMUCH") }
                    Label("Open HowMuch", systemImage: "person.crop.circle")
                        .font(accessory ? .caption : .headline)
                    if !accessory { Text("Sign in or refresh your widgets.").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.privacySensitive()
        .widgetURL(defaultURL)
    }
    private var defaultURL: URL {
        guard let data = valid else { return URL(string: "howmuch://widget/open")! }
        if kind == .calendar { return WidgetLink.calendar(Shift.dayString(date)).url(accountID: data.accountID) }
        if kind == .nextShift, let shift = data.upcoming(at: date, currency: currency).first { return WidgetLink.shift(shift.id).url(accountID: data.accountID) }
        if kind == .events, let event = data.events(at: date, currency: currency).first { return WidgetLink.event(event.id).url(accountID: data.accountID) }
        return WidgetLink.earnings.url(accountID: data.accountID)
    }
    private func brand(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image("BrandLogo").resizable().scaledToFit().frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 5))
            Text(title).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1)
            Spacer(minLength: 0)
        }.foregroundStyle(jade).widgetAccentable()
    }
    @ViewBuilder private func nextShift(_ data: WidgetSnapshot) -> some View {
        if let shift = data.upcoming(at: date, currency: currency).first {
            if accessory {
                if family == .accessoryInline {
                    Label(shift.event + " · " + shift.start.formatted(.dateTime.hour().minute()), systemImage: "calendar")
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(shift.start <= date ? "WORKING NOW" : "NEXT SHIFT").font(.caption2.bold())
                        Text(shift.event).font(.headline).lineLimit(1)
                        Text(shift.start.formatted(.dateTime.day().month().hour().minute())).font(.caption)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    brand(shift.start <= date ? "WORKING NOW" : "NEXT SHIFT")
                    Text(shift.event).font(.system(family == .systemSmall ? .headline : .title3, design: .rounded, weight: .bold)).lineLimit(2)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(shift.start, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated)).font(.caption).foregroundStyle(.secondary)
                            Text(shift.start.formatted(.dateTime.hour().minute()) + "–" + shift.end.formatted(.dateTime.hour().minute()) + (Calendar.current.isDate(shift.start, inSameDayAs: shift.end) ? "" : " (+1d)")).font(.caption.weight(.semibold))
                            if family != .systemSmall, showLocation, !shift.location.isEmpty {
                                Label(shift.location, systemImage: "mappin.and.ellipse").font(.caption).lineLimit(1).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if family != .systemSmall {
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(shift.start <= date ? "Ends in" : "Starts in").font(.caption2).foregroundStyle(.secondary)
                                Text(shift.start <= date ? shift.end : shift.start, style: .relative).font(.caption.weight(.semibold))
                            }.foregroundStyle(jade)
                        }
                    }
                    Spacer(minLength: 0)
                    if showPay { Text(amount(shift.pay, shift.currency)).font(.subheadline.bold()).foregroundStyle(jade) }
                }
            }
        } else { empty("Nothing booked", detail: "Your next shift will appear here.") }
    }
    @ViewBuilder private func events(_ data: WidgetSnapshot) -> some View {
        let events = Array(data.events(at: date, currency: currency).prefix(family == .systemLarge ? 5 : 2))
        VStack(alignment: .leading, spacing: 10) {
            brand("UPCOMING EVENTS")
            if events.isEmpty {
                Spacer(minLength: 0); Text("A little breathing room").font(.headline)
                Text("Add a shift to plan your next event.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(events) { event in
                    Link(destination: WidgetLink.event(event.id).url(accountID: data.accountID)) {
                        HStack(spacing: 10) {
                            VStack(spacing: 2) {
                                Text(event.next.start, format: .dateTime.day()).font(.system(.title3, design: .rounded, weight: .bold))
                                Text(event.next.start, format: .dateTime.month(.abbreviated)).font(.system(size: 9, weight: .semibold))
                            }.frame(width: 35).foregroundStyle(jade).widgetAccentable()
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.next.event).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(event.shifts.count) \(event.shifts.count == 1 ? "shift" : "shifts") · " + event.next.start.formatted(.dateTime.hour().minute()) + (data.currencies.count > 1 ? " · " + event.next.currency : "")).font(.caption2).foregroundStyle(.secondary)
                                if family == .systemLarge, showLocation, !event.next.location.isEmpty { Text(event.next.location).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                            if showPay { Text(amount(event.pay, event.next.currency)).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }
    private func calendarWidget(_ data: WidgetSnapshot) -> some View {
        let days = data.calendarDays(at: date, currency: currency)
        let upcoming = Array(data.upcoming(at: date, currency: currency).prefix(family == .systemLarge ? 3 : 1))
        return GeometryReader { geometry in
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(date, format: .dateTime.month(.wide)).textCase(.uppercase)
                        .font(.system(size: 12, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(jade)
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, label in
                                Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                            }
                        }.frame(height: 15)
                        let rows = days.count / 7
                        ForEach(0..<rows, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(Array(days[(row*7)..<(row*7+7)])) { day in
                                    if let value = day.date {
                                        Link(destination: WidgetLink.calendar(Shift.dayString(value)).url(accountID: data.accountID)) {
                                            calendarCell(day, today: TrackerCalendar.calendar.isDate(value, inSameDayAs: date), diameter: min(22, max(12, (geometry.size.height - 38) / CGFloat(days.count / 7) - 4)))
                                        }.buttonStyle(.plain)
                                    } else { Color.clear.frame(maxWidth: .infinity) }
                                }
                            }.frame(maxHeight: .infinity)
                        }
                    }.frame(maxHeight: .infinity)
                }.frame(width: geometry.size.width * 0.53)
                VStack(alignment: .leading, spacing: 9) {
                    Text("NEXT UP").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(jade)
                    if upcoming.isEmpty {
                        Spacer(minLength: 0)
                        Image(systemName: "calendar.badge.plus").font(.title2).foregroundStyle(jade)
                        Text("A little breathing room").font(.caption.weight(.semibold))
                        Text("No upcoming shifts").font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    } else {
                        ForEach(upcoming) { shift in
                            Link(destination: WidgetLink.shift(shift.id).url(accountID: data.accountID)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(shift.event).font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(2)
                                    Text(shift.start, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated)).font(.system(size: 10)).foregroundStyle(.secondary)
                                    Text(shift.start.formatted(.dateTime.hour().minute()) + "–" + shift.end.formatted(.dateTime.hour().minute()) + (TrackerCalendar.calendar.isDate(shift.start, inSameDayAs: shift.end) ? "" : " +1d"))
                                        .font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                    if showLocation, !shift.location.isEmpty { Text(shift.location).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                                    if showPay { Text(amount(shift.pay, shift.currency)).font(.system(size: 10, weight: .semibold)).foregroundStyle(jade).lineLimit(1).minimumScaleFactor(0.7) }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if family == .systemLarge { Divider() }
                        }
                        Spacer(minLength: 0)
                    }
                    Link(destination: WidgetLink.calendar(Shift.dayString(date)).url(accountID: data.accountID)) {
                        Label("View calendar", systemImage: "calendar").font(.system(size: 10, weight: .semibold)).foregroundStyle(jade)
                    }.buttonStyle(.plain)
                }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(jade.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private func calendarCell(_ day: WidgetCalendarDay, today: Bool, diameter: CGFloat) -> some View {
        VStack(spacing: 1) {
            Text("\(TrackerCalendar.calendar.component(.day, from: day.date!))")
                .font(.system(size: 11, weight: today || day.shiftCount > 0 ? .bold : .medium, design: .rounded))
                .fixedSize(horizontal: true, vertical: true)
                .frame(width: diameter, height: diameter)
                .foregroundStyle(today ? (colorScheme == .dark ? Color.black : Color.white) : .primary)
                .background(today ? jade : .clear, in: Circle())
            Circle().fill(day.shiftCount > 0 ? jade : .clear).frame(width: 3, height: 3)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(day.date!.formatted(.dateTime.day().month(.wide).year())), \(day.shiftCount) shifts\(today ? ", today" : "")")
    }
    private func month(_ data: WidgetSnapshot) -> some View {
        let code = currency ?? data.preferredCurrency
        let summary = data.month(at: date, currency: code)
        return VStack(alignment: .leading, spacing: 8) {
            brand(date.formatted(.dateTime.month(.wide)).uppercased())
            Text(showPay ? amount(summary.pay, code) : "\(NSDecimalNumber(decimal: PayEngine.rounded(summary.hours)).stringValue)h")
                .font(.system(family == .systemSmall ? .title2 : .largeTitle, design: .rounded, weight: .bold)).minimumScaleFactor(0.6).lineLimit(1).foregroundStyle(jade)
            Text(showPay ? "Scheduled work pay · \(code)" : "Scheduled paid hours · \(code)").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Text("\(summary.shifts.count) shifts").font(.caption.weight(.semibold))
                if family != .systemSmall { Spacer(); Text(showPay ? amount(summary.awaitingPayment, code) + " awaiting payment" : "Pay hidden · edit widget to show").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            if family != .systemSmall { Text("Work only · claims excluded").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !accessory { brand("HOWMUCH"); Spacer(minLength: 0) }
            Label(title, systemImage: "calendar").font(accessory ? .caption : .headline)
            if !accessory { Text(detail).font(.caption).foregroundStyle(.secondary); Spacer(minLength: 0) }
        }
    }
    private func amount(_ value: Decimal, _ currency: String) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = currency
        return currency + " " + (formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)")
    }
}
