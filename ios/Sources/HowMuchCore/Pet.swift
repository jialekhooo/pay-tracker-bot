import Foundation

/// HowMuch's pet: a little coin creature that grows as shifts are worked and paid.
/// Everything is worked out from the shifts already in the account, so nothing extra is stored or synced.
public struct PetProgress: Equatable, Sendable {
    public enum Stage: Int, CaseIterable, Sendable {
        case egg, hatchling, coinling, golden
        /// Experience needed to reach this stage.
        public var threshold: Int { [0, 30, 150, 500][rawValue] }
        public var title: String { ["Egg", "Hatchling", "Coinling", "Golden coin"][rawValue] }
    }
    public enum Mood: String, Sendable { case happy, sleepy, worried }

    public static let xpPerWorkedShift = 10
    public static let xpPerPaidShift = 15

    public let xp: Int
    public let stage: Stage
    /// Shifts marked paid; the pet's coin count.
    public let coins: Int
    public let mood: Mood
    /// Weeks in a row, up to this one, with at least one shift worked or booked.
    public let streakWeeks: Int
    /// Pay from finished shifts past their payment due date.
    public let overdue: Decimal

    public var next: Stage? { Stage(rawValue: stage.rawValue + 1) }
    /// 0...1 progress from this stage to the next (1 at the last stage).
    public var progress: Double {
        guard let next else { return 1 }
        return Double(xp - stage.threshold) / Double(next.threshold - stage.threshold)
    }
    public var xpToNext: Int? { next.map { $0.threshold - xp } }

    public init(shifts: [Shift], now: Date = Date(), calendar: Calendar = TrackerCalendar.calendar) {
        let worked = shifts.filter { $0.endDate <= now }
        let paid = worked.filter(\.paid)
        let points = worked.count * Self.xpPerWorkedShift + paid.count * Self.xpPerPaidShift
        xp = points
        stage = Stage.allCases.last { points >= $0.threshold } ?? .egg
        coins = paid.count
        let today = Shift.dayString(now)
        let late = worked.filter { !$0.paid && ($0.paymentDue ?? "9999-12-31") < today }
        overdue = late.reduce(Decimal(0)) { $0 + $1.pay }
        let week: TimeInterval = 7 * 24 * 60 * 60
        let recent = shifts.contains { abs($0.startDate.timeIntervalSince(now)) <= week || ($0.startDate <= now && now < $0.endDate) }
        mood = !late.isEmpty ? .worried : recent ? .happy : .sleepy
        var streak = 0
        var weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let starts = Set(shifts.compactMap { calendar.dateInterval(of: .weekOfYear, for: $0.startDate)?.start })
        while starts.contains(weekStart) {
            streak += 1
            weekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart)!
        }
        streakWeeks = streak
    }

    /// What the pet says on Overview.
    public func message(name: String, currency: String) -> String {
        switch mood {
        case .worried: return "\(name) is worried: \(SpokenSummary.amount(overdue, currency)) of pay is overdue. Chase it up and mark it paid to cheer \(name) up."
        case .sleepy: return "\(name) is napping. Book your next shift to wake \(name) up."
        case .happy:
            if let xpToNext, let next { return "\(name) is happy! \(xpToNext) XP until \(next.title.lowercased())." }
            return "\(name) is a golden coin. Keep the streak going!"
        }
    }
}
