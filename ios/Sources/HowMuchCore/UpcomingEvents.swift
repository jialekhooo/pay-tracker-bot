import Foundation

public struct UpcomingEventGroup: Identifiable {
    public let id: String
    public let event: String
    public let currency: String
    public let shifts: [Shift]
    public var scheduledPay: Decimal { shifts.reduce(0) { $0 + $1.total } }
}

public enum UpcomingEvents {
    /// Groups only the supplied upcoming/in-progress shifts; currencies never combine.
    public static func groups(_ shifts: [Shift], now: Date, ascending: Bool = true) -> [UpcomingEventGroup] {
        let active = shifts.filter { $0.endDate > now }
        let grouped = Dictionary(grouping: active) { $0.currency + "|" + $0.event.lowercased() }
        return grouped.map { key, shifts in
            let ordered = shifts.sorted { $0.startDate == $1.startDate ? $0.id.uuidString < $1.id.uuidString : $0.startDate < $1.startDate }
            return UpcomingEventGroup(id: key, event: ordered[0].event, currency: ordered[0].currency, shifts: ordered)
        }.sorted { left, right in
            let a = left.shifts[0].startDate, b = right.shifts[0].startDate
            return a == b ? left.id < right.id : ascending ? a < b : a > b
        }
    }
}
