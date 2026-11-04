import Foundation

/// A device-local projection. No account credentials, mail, notes, photos or claims are shared.
public struct WidgetShift: Codable, Equatable, Identifiable {
    public let id: UUID
    public let event: String
    public let location: String
    public let day: String
    public let start: Date
    public let end: Date
    public let hours: Decimal
    public let pay: Decimal
    public let currency: String
    public let paid: Bool
}

public struct WidgetEvent: Identifiable {
    public let shifts: [WidgetShift]
    public var id: UUID { shifts[0].id }
    public var next: WidgetShift { shifts[0] }
    public var pay: Decimal { shifts.reduce(0) { $0 + $1.pay } }
}

public struct WidgetMonth {
    public let shifts: [WidgetShift]
    public var hours: Decimal { shifts.reduce(0) { $0 + $1.hours } }
    public var pay: Decimal { shifts.reduce(0) { $0 + $1.pay } }
    public let awaitingPayment: Decimal
}

public struct WidgetCalendarDay: Identifiable {
    public let date: Date?
    public let index: Int
    public let shiftCount: Int
    public var id: Int { index }
}

public struct WidgetSnapshot: Codable, Equatable {
    public let version: Int
    public let accountID: String
    public let updatedAt: Date
    public let preferredCurrency: String
    public let shifts: [WidgetShift]
    public static let maximumAge: TimeInterval = 7 * 86400

    public init(data: TrackerData, accountID: String, updatedAt: Date = Date()) {
        version = 1; self.accountID = accountID.lowercased(); self.updatedAt = updatedAt
        preferredCurrency = data.rules.currency
        let monthStart = TrackerCalendar.calendar.date(from: TrackerCalendar.calendar.dateComponents([.year, .month], from: updatedAt))!
        shifts = data.shifts.filter { $0.endDate > monthStart }.map { WidgetShift(id: $0.id, event: $0.event, location: $0.location, day: $0.day,
            start: $0.startDate, end: $0.endDate, hours: $0.hours, pay: $0.pay, currency: $0.currency, paid: $0.paid) }
    }
    public func isCurrent(at now: Date) -> Bool {
        version == 1 && UUID(uuidString: accountID) != nil && now.timeIntervalSince(updatedAt) < Self.maximumAge
            && updatedAt.timeIntervalSince(now) < 300
    }
    public var currencies: [String] { Array(Set(shifts.map(\.currency) + [preferredCurrency])).sorted() }
    public func upcoming(at now: Date, currency: String? = nil) -> [WidgetShift] {
        shifts.filter { $0.end > now && (currency == nil || $0.currency == currency) }.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
    }
    public func events(at now: Date, currency: String? = nil) -> [WidgetEvent] {
        Dictionary(grouping: upcoming(at: now, currency: currency), by: { $0.currency + "|" + $0.event.lowercased() })
            .values.map { WidgetEvent(shifts: $0.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }) }
            .sorted { $0.next.start == $1.next.start ? $0.id.uuidString < $1.id.uuidString : $0.next.start < $1.next.start }
    }
    public func month(at now: Date, currency: String) -> WidgetMonth {
        let prefix = String(Shift.dayString(now).prefix(7))
        let items = shifts.filter { $0.currency == currency && $0.day.hasPrefix(prefix) }
        return WidgetMonth(shifts: items, awaitingPayment: items.filter { !$0.paid && $0.end <= now }.reduce(0) { $0 + $1.pay })
    }
    /// Use the same Monday-first Gregorian calendar as the app, including overnight workdays.
    public func calendarDays(at date: Date, currency: String? = nil) -> [WidgetCalendarDay] {
        let calendar = TrackerCalendar.calendar
        let items = shifts.filter { currency == nil || $0.currency == currency }
        return TrackerCalendar.monthDays(date).enumerated().map { index, day in
            guard let day else { return WidgetCalendarDay(date: nil, index: index, shiftCount: 0) }
            let start = calendar.startOfDay(for: day)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return WidgetCalendarDay(date: day, index: index, shiftCount: items.filter { $0.start < end && $0.end > start }.count)
        }
    }
    /// Precomputed transitions let ended shifts disappear even without reopening the app.
    public func timelineDates(from now: Date) -> [Date] {
        let horizon = now.addingTimeInterval(86400)
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let candidates = shifts.flatMap { [$0.start, $0.end] } + [midnight, updatedAt.addingTimeInterval(Self.maximumAge)]
        return [now] + Array(Set(candidates.filter { $0 > now && $0 <= horizon })).sorted().prefix(80)
    }
}

public enum WidgetLink: Hashable {
    case shift(UUID), event(UUID), earnings, calendar(String), finish(UUID)
    public func url(accountID: String) -> URL {
        var parts = URLComponents(); parts.scheme = "howmuch"; parts.host = "widget"
        var query = [URLQueryItem(name: "account", value: accountID.lowercased())]
        switch self {
        case .shift(let id): parts.path = "/shift"; query.append(URLQueryItem(name: "id", value: id.uuidString))
        case .event(let id): parts.path = "/event"; query.append(URLQueryItem(name: "id", value: id.uuidString))
        case .finish(let id): parts.path = "/finish"; query.append(URLQueryItem(name: "id", value: id.uuidString))
        case .earnings: parts.path = "/earnings"
        case .calendar(let day): parts.path = "/calendar"; query.append(URLQueryItem(name: "day", value: day))
        }
        parts.queryItems = query; return parts.url!
    }
    public static func parse(_ url: URL, accountID: String) -> WidgetLink? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "howmuch", parts.host == "widget",
              let owner = UUID(uuidString: accountID), let query = parts.queryItems,
              query.filter({ $0.name == "account" }).count == 1,
              query.first(where: { $0.name == "account" })?.value.flatMap(UUID.init(uuidString:)) == owner else { return nil }
        if parts.path == "/earnings" { return .earnings }
        if parts.path == "/calendar" {
            guard query.filter({ $0.name == "day" }).count == 1,
                  let day = query.first(where: { $0.name == "day" })?.value,
                  day.count == 10, let date = TrackerCalendar.localDate(day), Shift.dayString(date) == day else { return nil }
            return .calendar(day)
        }
        guard query.filter({ $0.name == "id" }).count == 1,
              let id = query.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:)) else { return nil }
        switch parts.path { case "/shift": return .shift(id); case "/event": return .event(id); case "/finish": return .finish(id); default: return nil }
    }
}

public enum WidgetSnapshotFile {
    public static let groupIdentifier = "group.com.jialekhoo.howmuch.widgets"
    public static func write(_ snapshot: WidgetSnapshot, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("widgets.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    public static func read(directory: URL, now: Date = Date()) -> WidgetSnapshot? {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("widgets.json")),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: bytes), snapshot.isCurrent(at: now) else { return nil }
        return snapshot
    }
    public static func clear(directory: URL) throws {
        let url = directory.appendingPathComponent("widgets.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
