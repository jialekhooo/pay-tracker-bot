import Foundation

/// Where the money stands, split three ways so nothing is counted before it's earned:
/// paid (worked and received), owed (worked, not yet received) and booked (not worked yet).
/// A shift in progress counts the part already worked.
public struct EarningsBreakdown: Equatable, Sendable {
    public var paid: Decimal = 0
    public var owed: Decimal = 0
    public var booked: Decimal = 0
    public var hoursWorked: Decimal = 0
    public var shiftsWorked = 0
    public var shiftsBooked = 0

    /// Worked so far: paid plus owed.
    public var earned: Decimal { paid + owed }
    /// Everything, including shifts not worked yet.
    public var total: Decimal { earned + booked }

    public init(shifts: [Shift], now: Date = Date()) {
        for shift in shifts {
            let earned = shift.earned(at: now)
            if shift.paid { paid += earned } else { owed += earned }
            booked += shift.pay - earned
            if now >= shift.endDate {
                hoursWorked += shift.hours; shiftsWorked += 1
            } else if now > shift.startDate {
                // In progress: the hours worked so far, in the same proportion as the pay.
                let fraction = Decimal(min(1, max(0, now.timeIntervalSince(shift.startDate) / shift.endDate.timeIntervalSince(shift.startDate))))
                hoursWorked += PayEngine.rounded(shift.hours * fraction); shiftsBooked += 1
            } else {
                shiftsBooked += 1
            }
        }
    }
}
