import Foundation

public struct JobTemplate: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var shift: Shift
    public var payerID: UUID?
    public init(id: UUID = UUID(), name: String, shift: Shift, payerID: UUID? = nil) { self.id = id; self.name = name; self.shift = shift; self.payerID = payerID }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else { throw TrackerError.invalid("Enter a template name of up to 120 characters.") }
        var data = TrackerData(); data.shifts = [shift]; try data.validate()
    }
    public func makeShift(on day: String) throws -> Shift {
        var rules = PayRules(); rules.currency = shift.currency; rules.overtimeAfter = shift.overtimeAfter; rules.overtimeMultiplier = shift.overtimeMultiplier
        var made = try Shift(event: shift.event, location: shift.location, day: day, startMinute: shift.startMinute, endMinute: shift.endMinute,
                             breakMinutes: shift.breakMinutes, paidBreak: shift.paidBreak, rate: shift.rate, fixedPay: shift.fixedPay, rules: rules)
        made.extra = shift.extra; made.extraNote = shift.extraNote
        made.callMinute = shift.callMinute; made.dressCode = shift.dressCode; made.contact = shift.contact
        return made
    }
}

public enum ShiftSeries {
    public static func make(from shift: Shift, every days: Int, count: Int) throws -> [Shift] {
        guard [1, 7, 14].contains(days), (2...52).contains(count), let first = TrackerCalendar.localDate(shift.day) else { throw TrackerError.invalid("Choose daily, weekly or fortnightly, with 2–52 shifts.") }
        let template = JobTemplate(name: shift.event, shift: shift)
        return try (0..<count).map { offset in
            guard let day = TrackerCalendar.calendar.date(byAdding: .day, value: offset * days, to: first) else { throw TrackerError.invalid("These dates are outside the supported range.") }
            return try template.makeShift(on: Shift.dayString(day))
        }
    }
}

public struct EventFinancialSummary {
    public let workPay: Decimal
    public let reimbursements: Decimal
    public let personalExpenses: Decimal
    public let paidHours: Decimal
    public var netWorkPay: Decimal { workPay }
    public var expectedCredit: Decimal { workPay + reimbursements }
    public var effectiveHourly: Decimal? { paidHours > 0 ? PayEngine.rounded(netWorkPay / paidHours) : nil }
    public init(data: TrackerData, event: String, currency: String) {
        let shifts = data.shifts.filter { $0.event.caseInsensitiveCompare(event) == .orderedSame && $0.currency == currency }
        let ids = Set(shifts.map(\.id))
        workPay = shifts.reduce(0) { $0 + $1.total }
        paidHours = shifts.reduce(0) { $0 + $1.hours }
        reimbursements = data.reimbursementsOnly.claims.filter { ids.contains($0.shiftID) }.reduce(0) { $0 + $1.amount }
        personalExpenses = 0
    }
}
