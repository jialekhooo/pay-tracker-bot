import Foundation

public extension Shift {
    /// The same shift with a different finishing time, with pay (including overtime) recalculated.
    func finishing(atMinute minute: Int) throws -> Shift {
        var rules = PayRules()
        rules.currency = currency; rules.overtimeAfter = overtimeAfter; rules.overtimeMultiplier = overtimeMultiplier
        var next = try Shift(id: id, sourceID: sourceID, event: event, location: location, day: day,
                             startMinute: startMinute, endMinute: minute, breakMinutes: breakMinutes, paidBreak: paidBreak,
                             rate: rate, fixedPay: fixedPay, rules: rules, paid: paid, paymentDue: paymentDue)
        next.extra = extra; next.extraNote = extraNote
        next.callMinute = callMinute; next.dressCode = dressCode; next.contact = contact
        return next
    }

    /// The same shift finishing `minutes` later (the live card's "+30 min"), kept under 24 hours long.
    func extended(byMinutes minutes: Int) throws -> Shift {
        guard minutes > 0, durationMinutes + minutes < 24 * 60 else {
            throw TrackerError.invalid("A shift can't run 24 hours or longer.")
        }
        return try finishing(atMinute: (endMinute + minutes) % (24 * 60))
    }

    /// Hourly shifts are the ones where the actual finishing time changes pay.
    var paysByTheHour: Bool { fixedPay == nil && rate > 0 }
}

public enum LiveShiftPlanner {
    /// How long before a shift starts its Live Activity may appear.
    public static let leadTime: TimeInterval = 30 * 60
    /// How long after a shift ends the app still asks for the actual finishing time.
    public static let finishWindow: TimeInterval = 12 * 60 * 60

    /// The shift to show on the Lock Screen: the one in progress, else the next one starting soon.
    public static func current(in shifts: [Shift], at now: Date) -> Shift? {
        shifts.filter { $0.startDate.addingTimeInterval(-leadTime) <= now && now < $0.endDate }
            .min { ($0.startDate, $0.endDate) < ($1.startDate, $1.endDate) }
    }

    /// Hourly shifts that ended recently and whose finishing time has not been confirmed yet, oldest first.
    public static func awaitingFinish(in shifts: [Shift], confirmed: Set<UUID>, at now: Date) -> [Shift] {
        shifts.filter { $0.paysByTheHour && !$0.paid && !confirmed.contains($0.id) &&
                        $0.endDate <= now && now.timeIntervalSince($0.endDate) <= finishWindow }
            .sorted { $0.endDate < $1.endDate }
    }

    /// The end minute for a chosen finishing time, rejecting times that would not make a valid shift.
    public static func endMinute(for finish: Date, of shift: Shift, calendar: Calendar = .current) throws -> Int {
        guard finish > shift.startDate, finish.timeIntervalSince(shift.startDate) < 24 * 60 * 60 else {
            throw TrackerError.invalid("Choose a finishing time after the shift started and within 24 hours.")
        }
        let parts = calendar.dateComponents([.hour, .minute], from: finish)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard minute != shift.startMinute else { throw TrackerError.invalid("The shift needs to last at least a minute.") }
        return minute
    }
}
