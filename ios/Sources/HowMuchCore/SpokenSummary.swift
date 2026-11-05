import Foundation

/// What Siri and Shortcuts say for "How much did I earn this week?" and "How much am I owed?".
/// Amounts stay separate by currency, matching the Earnings screen.
public enum SpokenSummary {
    public enum Period: String, CaseIterable, Sendable { case week, month }

    /// Pay from shifts that started in this week or month: what's been worked so far, and what's still booked.
    public static func earnings(_ shifts: [Shift], period: Period, now: Date = Date(), calendar: Calendar = TrackerCalendar.calendar) -> String {
        let unit: Calendar.Component = period == .week ? .weekOfYear : .month
        let name = "this \(period.rawValue)"
        guard let interval = calendar.dateInterval(of: unit, for: now) else { return "I couldn't work out \(name)." }
        let items = shifts.filter { interval.contains($0.startDate) }
        guard !items.isEmpty else { return "You have no shifts \(name)." }
        let done = items.filter { $0.endDate <= now }, booked = items.filter { $0.endDate > now }
        let opening = name.prefix(1).uppercased() + name.dropFirst()
        if done.isEmpty {
            return "You haven't finished a shift \(name) yet. \(total(booked)) is booked across \(count(booked.count, "shift"))."
        }
        var text = "\(opening) you've earned \(total(done)) from \(count(done.count, "shift"))"
        text += booked.isEmpty ? "." : ", with \(total(booked)) more booked."
        return text
    }

    /// Finished shifts not yet marked paid, and how much of that is past its payment due date.
    public static func owed(_ shifts: [Shift], now: Date = Date()) -> String {
        let unpaid = shifts.filter { !$0.paid && $0.endDate <= now }
        guard !unpaid.isEmpty else { return "Nothing is owed. Every finished shift is marked paid." }
        let today = Shift.dayString(now)
        let overdue = unpaid.filter { ($0.paymentDue ?? "9999-12-31") < today }
        var text = "You're owed \(total(unpaid)) for \(count(unpaid.count, "shift"))."
        if !overdue.isEmpty {
            let oldest = overdue.min { ($0.paymentDue ?? "", $0.day) < ($1.paymentDue ?? "", $1.day) }!
            text += " \(total(overdue)) of it is overdue, the oldest from \(oldest.event)."
        }
        return text
    }

    /// "SGD 360", or "SGD 360 and MYR 120" across currencies, largest first.
    static func total(_ shifts: [Shift]) -> String {
        let sums = Dictionary(grouping: shifts, by: \.currency).mapValues { $0.reduce(Decimal(0)) { $0 + $1.pay } }
        let parts = sums.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { amount($0.value, $0.key) }
        return parts.count <= 1 ? (parts.first ?? "nothing") : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    static func amount(_ value: Decimal, _ currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        let whole = NSDecimalNumber(decimal: value).doubleValue.rounded() == NSDecimalNumber(decimal: value).doubleValue
        formatter.minimumFractionDigits = whole ? 0 : 2
        formatter.maximumFractionDigits = whole ? 0 : 2
        return currency + " " + (formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)")
    }

    private static func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }
}
