import Foundation

/// "Send your availability for December": a ready-to-paste message worked out from booked shifts
/// and days the person has blocked (exams, holidays).
public enum Availability {
    public enum Day: Equatable {
        case free
        /// Free for part of the day, e.g. "after 2pm" or "before 6pm".
        case partly(String)
        case busy
    }

    /// The working window a coordinator cares about, and how much free time counts.
    public static let dayStart = 8 * 60, dayEnd = 23 * 60, usefulGap = 4 * 60

    public static func day(_ key: String, shifts: [Shift], blocked: Set<String>, calendar: Calendar = TrackerCalendar.calendar) -> Day {
        if blocked.contains(key) { return .busy }
        guard let date = TrackerCalendar.localDate(key) else { return .free }
        // Minutes of this day taken by shifts, including one running past midnight from the day before.
        var taken: [(Int, Int)] = []
        for shift in shifts {
            let start = shift.startDate, end = shift.endDate
            guard let dayStartDate = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: date),
                  let dayEndDate = calendar.date(byAdding: .day, value: 1, to: dayStartDate),
                  start < dayEndDate, end > dayStartDate else { continue }
            let from = max(0, Int(start.timeIntervalSince(dayStartDate) / 60))
            let to = min(24 * 60, Int(end.timeIntervalSince(dayStartDate) / 60))
            taken.append((from, to))
        }
        guard !taken.isEmpty else { return .free }
        let earliest = taken.map(\.0).min()!, latest = taken.map(\.1).max()!
        let before = earliest - dayStart, after = dayEnd - latest
        // Merge overlaps while looking for usable gaps between bookings. Looking only
        // at the first and last shift hides a free afternoon between two jobs.
        var end = dayStart
        var middle: (start: Int, end: Int)?
        for (from, to) in taken.sorted(by: { $0.0 < $1.0 }) {
            let start = max(dayStart, end), finish = min(dayEnd, from)
            if end > dayStart, finish - start >= usefulGap,
               finish - start > (middle.map { $0.end - $0.start } ?? 0) {
                middle = (start, finish)
            }
            end = max(end, to)
        }
        if let middle, middle.end - middle.start >= max(before, after) {
            return .partly("from " + clock(middle.start) + " to " + clock(middle.end))
        }
        if after >= usefulGap, after >= before { return .partly("after " + clock(latest)) }
        if before >= usefulGap { return .partly("before " + clock(earliest)) }
        return .busy
    }

    /// e.g. "My availability, 12–31 Dec:\nFree all day: 12, 13, 15–17 Dec\nPart of the day: 18 Dec after 2pm\nNot available: 14 Dec"
    public static func message(from: Date, to: Date, shifts: [Shift], blocked: Set<String>, calendar: Calendar = TrackerCalendar.calendar) -> String {
        var free: [Date] = [], busy: [Date] = [], partly: [(Date, String)] = []
        var cursor = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: max(from, to))
        while cursor <= last, free.count + busy.count + partly.count < 366 {
            switch day(Shift.dayString(cursor), shifts: shifts, blocked: blocked, calendar: calendar) {
            case .free: free.append(cursor)
            case .busy: busy.append(cursor)
            case .partly(let when): partly.append((cursor, when))
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        var lines = ["My availability, \(span(from, last, calendar)):"]
        lines.append("Free all day: " + (free.isEmpty ? "none" : ranges(free, calendar)))
        if !partly.isEmpty { lines.append("Part of the day: " + partly.map { "\(short($0.0, calendar)) \($0.1)" }.joined(separator: ", ")) }
        if !busy.isEmpty { lines.append("Not available: " + ranges(busy, calendar)) }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting

    private static func clock(_ minutes: Int) -> String {
        let hour = (minutes / 60) % 24, minute = minutes % 60
        let suffix = hour < 12 ? "am" : "pm"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return minute == 0 ? "\(twelve)\(suffix)" : String(format: "%d:%02d%@", twelve, minute, suffix)
    }

    private static func monthName(_ date: Date, _ calendar: Calendar) -> String {
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][calendar.component(.month, from: date) - 1]
    }

    private static func short(_ date: Date, _ calendar: Calendar) -> String { "\(calendar.component(.day, from: date)) \(monthName(date, calendar))" }

    private static func span(_ from: Date, _ to: Date, _ calendar: Calendar) -> String {
        if calendar.isDate(from, equalTo: to, toGranularity: .month) {
            return "\(calendar.component(.day, from: from))–\(calendar.component(.day, from: to)) \(monthName(to, calendar))"
        }
        return "\(short(from, calendar)) – \(short(to, calendar))"
    }

    /// Consecutive days joined into ranges and grouped by month: "12, 13, 15–17 Dec, 2 Jan".
    static func ranges(_ days: [Date], _ calendar: Calendar) -> String {
        var groups: [[Date]] = []
        for day in days.sorted() {
            if let previous = groups.last?.last, calendar.date(byAdding: .day, value: 1, to: previous) == day,
               calendar.isDate(previous, equalTo: day, toGranularity: .month) { groups[groups.count - 1].append(day) }
            else { groups.append([day]) }
        }
        var parts: [String] = [], current: [String] = []
        for (index, group) in groups.enumerated() {
            let first = calendar.component(.day, from: group[0]), last = calendar.component(.day, from: group[group.count - 1])
            current.append(group.count == 1 ? "\(first)" : group.count == 2 ? "\(first), \(last)" : "\(first)–\(last)")
            let nextMonthDiffers = index + 1 == groups.count || !calendar.isDate(groups[index + 1][0], equalTo: group[0], toGranularity: .month)
            if nextMonthDiffers { parts.append(current.joined(separator: ", ") + " " + monthName(group[0], calendar)); current = [] }
        }
        return parts.joined(separator: ", ")
    }
}
