import Foundation

public struct AppPreferences: Codable, Equatable {
    public var displayName = ""
    public var avatar: Data? = nil
    public var defaultBreakMinutes = 0
    public var defaultBreakPaid = false
    public var eventRates: [String: Decimal] = [:]
    public var payers: [String: String] = [:]
    public var savedPayers: [SavedPayer]?
    public var eventPayerIDs: [String: UUID]?
    public var remindersEnabled = false
    public var reminderMinute = 20 * 60
    public var groupUpcomingByEvent: Bool?
    public var notifications: JobNotificationOptions?
    public var travel: TravelReminderOptions?
    public var jobTemplates: [JobTemplate]?
    /// Penny's name, wardrobe and spent coins.
    public var pet: PetPreferences?
    /// Live shift choices and which finished shifts already had their finish time confirmed.
    public var liveShift: LiveShiftPreferences?
    /// Settings → Widgets preview toggles.
    public var widgetPreview: WidgetPreviewPreferences?
    public init() {}
    public func validate() throws {
        guard (0..<1440).contains(defaultBreakMinutes), (0..<1440).contains(reminderMinute),
              eventRates.values.allSatisfy({ !$0.isNaN && $0 >= 0 }), (avatar?.count ?? 0) <= 2_000_000 else {
            throw TrackerError.invalid("Check your break, reminder and event-rate settings.")
        }
        try validatePayers()
        if let notifications { try notifications.validate() }
        if let travel { try travel.validate() }
        if let jobTemplates {
            guard jobTemplates.count <= 100, Set(jobTemplates.map(\.id)).count == jobTemplates.count else { throw TrackerError.invalid("Keep up to 100 unique templates.") }
            for template in jobTemplates { try template.validate() }
        }
        if let pet { try pet.validate() }
        if let liveShift { try liveShift.validate() }
    }
    public var travelEnabled: Bool { travel?.enabled == true }
    public var jobNotifications: JobNotificationOptions { notifications ?? JobNotificationOptions() }
}

public extension TrackerData {
    var settings: AppPreferences { (preferences ?? AppPreferences()).migratedPayers }
    var currencies: [String] { Array(Set(shifts.map(\.currency) + [rules.currency])).sorted() }
}

public extension Shift {
    func earned(at now: Date) -> Decimal {
        if now <= startDate { return 0 }
        if now >= endDate { return pay }
        let fraction = Decimal(min(1, max(0, now.timeIntervalSince(startDate) / endDate.timeIntervalSince(startDate))))
        return PayEngine.rounded(pay * fraction)
    }
    func state(at now: Date) -> String {
        if now < startDate { return "Upcoming" }
        if now < endDate { return "Working now" }
        return paid ? "Paid" : "Awaiting payment"
    }
}

public enum TrackerCalendar {
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }
    public static func localDate(_ key: String) -> Date? {
        guard Shift.date(key) != nil else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
    public static func monthDays(_ date: Date) -> [Date?] {
        let components = calendar.dateComponents([.year, .month], from: date)
        let first = calendar.date(from: components)!
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        let count = calendar.range(of: .day, in: .month, for: first)!.count
        var result: [Date?] = Array(repeating: nil, count: offset)
        result += (0..<count).map { calendar.date(byAdding: .day, value: $0, to: first) }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }
    /// Work on a calendar day includes a shift continuing past midnight, but
    /// excludes a shift ending exactly as that day begins.
    public static func shifts(on date: Date, from shifts: [Shift]) -> [Shift] {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return shifts.filter { $0.startDate < end && $0.endDate > start }.sorted {
            $0.startDate == $1.startDate ? $0.id.uuidString < $1.id.uuidString : $0.startDate < $1.startDate
        }
    }
    public static func defaultDueDate(for day: Date, existing: [Shift], event: String) -> Date {
        let last = existing.filter { $0.event.caseInsensitiveCompare(event) == .orderedSame }
            .compactMap { localDate($0.day) }.reduce(day, max)
        let twoWeeks = calendar.date(byAdding: .day, value: 14, to: last)!
        let offset = (6 - calendar.component(.weekday, from: twoWeeks) + 7) % 7
        return calendar.date(byAdding: .day, value: offset, to: twoWeeks)!
    }
}

public enum CalendarExport {
    public static func encode(_ shifts: [Shift], now: Date = Date()) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//HowMuch//iOS//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH"]
        for shift in shifts {
            lines += ["BEGIN:VEVENT", "UID:\(shift.id.uuidString)@howmuch", "DTSTAMP:\(formatter.string(from: now))",
                      "DTSTART:\(formatter.string(from: shift.startDate))", "DTEND:\(formatter.string(from: shift.endDate))",
                      "SUMMARY:\(escape(shift.event))", "LOCATION:\(escape(shift.location))",
                      "DESCRIPTION:\(escape("\(shift.currency) \(shift.pay) · \(PayEngine.rounded(shift.hours)) paid hours"))", "END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        // RFC 5545 folding is measured in UTF-8 octets, not Character count.
        return lines.map { line in
            var folded = "", bytes = 0
            for scalar in line.unicodeScalars {
                let size = scalar.utf8.count
                if bytes + size > 75 { folded += "\r\n "; bytes = 1 }
                folded.unicodeScalars.append(scalar); bytes += size
            }
            return folded
        }.joined(separator: "\r\n") + "\r\n"
    }
}

public struct TravelReminderOptions: Codable, Equatable {
    public var enabled = false
    public var origin = ""
    public var mode = "automobile"
    public var transit: Bool?
    public var effectiveMode: String { transit == true ? "transit" : mode }
    public var arrivalBuffer = 15
    public var prepareMinutes = 10
    public var trafficUpdates = true
    public init() {}
    public func directionsURL(destination: String, modern: Bool = true) -> URL? {
        guard !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, modern || effectiveMode != "cycling" else { return nil }
        var parts = URLComponents(string: modern ? "https://maps.apple.com/directions" : "https://maps.apple.com/")!
        parts.queryItems = [URLQueryItem(name: modern ? "source" : "saddr", value: origin),
                           URLQueryItem(name: modern ? "destination" : "daddr", value: destination),
                           URLQueryItem(name: modern ? "mode" : "dirflg", value: modern ? (effectiveMode == "automobile" ? "driving" : effectiveMode) : (effectiveMode == "transit" ? "r" : mode == "walking" ? "w" : "d"))]
        return parts.url
    }
    public func validate() throws {
        guard origin.count <= 1000, (!enabled || !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              ["automobile", "walking", "cycling"].contains(mode), (0...120).contains(arrivalBuffer), (0...60).contains(prepareMinutes) else {
            throw TrackerError.invalid("Choose a departure address, travel mode and valid reminder times.")
        }
    }
}
