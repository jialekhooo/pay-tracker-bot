import Foundation
import SwiftUI
import HowMuchCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence, on the iPhone only: nothing here leaves the device. Every use has a
/// plain fallback, so HowMuch works the same on iPhones without it.
enum AppleIntelligence {
    /// Whether the on-device model can be used right now.
    static var isAvailable: Bool {
        #if DEBUG
        if CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--ui-test-account") { return false }
        #endif
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    // MARK: Job messages

    /// Reads a job message with the usual rules, then lets Apple Intelligence fill what they missed
    /// (unusual date formats, rates written in words, the event's name). Rules win where both answer.
    static func readJob(_ text: String, today: Date = Date()) async -> PastedJob {
        var job = JobMessageParser.parse(text, today: today)
        let missing = job.dates.isEmpty || (job.rate == nil && job.fixedPay == nil) || job.name.isEmpty
        guard missing, isAvailable else { return job }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let read = try? await JobReader.read(text, today: today) {
            var helped = false
            if job.event?.isEmpty ?? true, let event = read.event?.trimmed, !event.isEmpty { job.event = event; helped = true }
            if job.location?.isEmpty ?? true, let location = read.location?.trimmed, !location.isEmpty { job.location = location; helped = true }
            if job.rate == nil, job.fixedPay == nil {
                // Round to cents: Decimal(Double) would give 12.300000000000001.
                func cents(_ value: Double) -> Decimal? { Decimal(string: String(format: "%.2f", value)) }
                if let rate = read.hourlyRate, rate > 0, rate < 1000, let value = cents(rate) { job.rate = value; helped = true }
                else if let pay = read.payPerDay, pay > 0, pay < 100_000, let value = cents(pay) { job.fixedPay = value; helped = true }
            }
            if job.dates.isEmpty {
                job.dates = read.shifts.compactMap { $0.pasted }.prefix(JobMessageParser.maximumDates).map { $0 }
                helped = helped || !job.dates.isEmpty
            }
            if helped { job.notes.append("Apple Intelligence filled in what the message didn't say plainly. Check it before saving.") }
        }
        #endif
        return job
    }

    // MARK: Bank notifications

    /// For bank wording the rules don't know: asks whether money came in, and how much from whom.
    /// Returns nil when it isn't a payment or the model isn't available.
    enum PaymentCheck { case payment(amount: Double, payer: String), notPayment, couldNotCheck }

    /// Tells "not money in" apart from "couldn't check" (model unavailable or failed), so the log is honest.
    static func readPayment(_ text: String) async -> PaymentCheck {
        // Cheap screen first: no written amount, or one-time-code wording, is never a payment.
        guard PayInText.mayBePayment(text) else { return .notPayment }
        guard isAvailable else { return .couldNotCheck }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard let read = try? await PaymentReader.read(text) else { return .couldNotCheck }
            guard read.isMoneyIn else { return .notPayment }
            // The model only says *whether* money came in; the amount must be one written in the alert.
            guard let amount = PayInText.confirmedAmount(in: text, suggested: read.amount.map { Decimal(string: String(format: "%.2f", $0)) ?? 0 }) else { return .couldNotCheck }
            return .payment(amount: NSDecimalNumber(decimal: amount).doubleValue, payer: read.from?.trimmed ?? "")
        }
        #endif
        return .couldNotCheck
    }

    // MARK: Receipts

    struct ReceiptRead { var total: Decimal?; var day: String?; var category: ClaimCategory?; var note: String? }

    /// Reads a receipt's text (already recognised on the iPhone) for a claim. The total is only
    /// trusted if it's printed on the receipt; the date must be a real date.
    static func readReceipt(_ text: String) async -> ReceiptRead? {
        guard isAvailable, !text.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let read = try? await ReceiptReader.read(text) {
            var result = ReceiptRead()
            if let total = read.total, total > 0 {
                let suggested = Decimal(string: String(format: "%.2f", total))
                if let suggested, PayInText.amounts(in: text).contains(suggested) || text.contains(String(format: "%.2f", total)) { result.total = suggested }
            }
            if let day = read.date?.trimmed, Shift.date(day) != nil { result.day = day }
            result.category = ClaimCategory(rawValue: read.category.lowercased()) ?? (read.category.lowercased() == "other" ? .miscellaneous : nil)
            if let note = read.note?.trimmed, !note.isEmpty { result.note = note.split(separator: " ").prefix(6).joined(separator: " ") }
            return result
        }
        #endif
        return nil
    }

    // MARK: Recaps

    /// Two friendly sentences about the month, written from the numbers it's given (and nothing else).
    static func recap(facts: String) async -> String? {
        guard isAvailable else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
                You write a short, upbeat recap for someone who tracks pay from part-time event jobs. \
                Talk to them as "you", like a friendly coach. Use only the facts given and copy numbers exactly. \
                Never invent numbers, names or money advice. Two short sentences, no greeting, no emoji, no lists.
                """)
            return try? await session.respond(to: "Facts:\n" + facts).content.trimmed
        }
        #endif
        return nil
    }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum JobReader {
    @Generable struct Shift {
        @Guide(description: "The working date as yyyy-MM-dd") var date: String
        @Guide(description: "Start time, 24-hour HH:mm") var start: String
        @Guide(description: "End time, 24-hour HH:mm") var end: String
    }
    @Generable struct Job {
        @Guide(description: "Short name of the event or job, e.g. 'Brand launch'. Empty if not given.") var event: String?
        @Guide(description: "Venue or address. Empty if not given.") var location: String?
        @Guide(description: "Pay per hour in dollars, if the message gives an hourly rate") var hourlyRate: Double?
        @Guide(description: "Pay per day in dollars, if the message gives a daily rate instead of hourly") var payPerDay: Double?
        @Guide(description: "Every working date with its hours", .maximumCount(60)) var shifts: [Shift]
    }

    static func read(_ text: String, today: Date) async throws -> Job {
        let formatter = DateFormatter(); formatter.dateFormat = "EEEE d MMMM yyyy"; formatter.locale = Locale(identifier: "en_SG")
        let session = LanguageModelSession(instructions: """
            You read job offer messages for part-time event work in Singapore and pull out the details. \
            Today is \(formatter.string(from: today)). Dates without a year are the next time that date comes. \
            Only use what the message says; leave a field empty rather than guess.
            """)
        return try await session.respond(to: String(text.prefix(JobMessageParser.maximumLength)), generating: Job.self).content
    }
}

@available(iOS 26.0, *)
private extension JobReader.Shift {
    var pasted: PastedJobDate? {
        func minutes(_ value: String) -> Int? {
            let parts = value.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
            return parts[0] * 60 + parts[1]
        }
        guard (try? HowMuchCore.Shift(event: "x", day: date, startMinute: 0, endMinute: 60, rate: 0)) != nil,
              let start = minutes(start), let end = minutes(end), start != end else { return nil }
        return PastedJobDate(day: date, startMinute: start, endMinute: end)
    }
}

@available(iOS 26.0, *)
private enum ReceiptReader {
    @Generable struct Receipt {
        @Guide(description: "The amount actually charged, as printed next to labels like You paid, Total, Grand total, Amount, NETS or Paid. A number like 19.30.") var total: Double?
        @Guide(description: "The date on the receipt as yyyy-MM-dd. Empty if none.") var date: String?
        @Guide(description: "What kind of expense", .anyOf(["cab", "food", "other"])) var category: String
        @Guide(description: "What it was for, in 3 to 6 words, e.g. Grab to Marina Bay Sands, Lunch at Toast Box, Stationery from Popular") var note: String?
    }

    static func read(_ text: String) async throws -> Receipt {
        let session = LanguageModelSession(instructions: """
            You read text recognised from a receipt photo, for a work expense claim in Singapore. \
            Taxi, Grab, Gojek, Tada, CDG and ComfortDelGro rides are "cab". Meals, drinks and groceries are "food". Anything else is "other". \
            Copy numbers exactly as printed. Leave a field empty rather than guess.
            """)
        return try await session.respond(to: String(text.prefix(4000)), generating: Receipt.self).content
    }
}

@available(iOS 26.0, *)
private enum PaymentReader {
    @Generable struct Payment {
        @Guide(description: "True only if this notification says money was received into the account") var isMoneyIn: Bool
        @Guide(description: "The amount received in dollars") var amount: Double?
        @Guide(description: "Who sent the money, as written. Empty if not said.") var from: String?
    }

    static func read(_ text: String) async throws -> Payment {
        let session = LanguageModelSession(instructions: """
            You read bank app notifications. Decide whether money came IN to the account (a transfer, PayNow or deposit received). \
            Spending, bills, one-time codes and promotions are not money in.
            """)
        return try await session.respond(to: String(text.prefix(1000)), generating: Payment.self).content
    }
}
#endif

/// A two-sentence recap of this month, written on the iPhone by Apple Intelligence from the real numbers.
/// Shown only where Apple Intelligence is available; rewritten when the numbers change.
struct MonthRecapCard: View {
    @EnvironmentObject private var store: TrackerStore
    let now: Date
    @State private var recap: String?

    var body: some View {
        Group {
            if let recap {
                Card {
                    Label("Your month so far", systemImage: "apple.intelligence").font(.caption.weight(.semibold)).foregroundStyle(Palette.teal)
                    Text(recap).font(.subheadline).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    Text("Written by Apple Intelligence on your iPhone").font(.caption2).foregroundStyle(Palette.muted)
                }.accessibilityIdentifier("recap.card")
            }
        }
        .task(id: facts) {
            guard AppleIntelligence.isAvailable else { return }
            let key = facts
            if let saved = UserDefaults.standard.string(forKey: "recap.text"), UserDefaults.standard.string(forKey: "recap.key") == key { recap = saved; return }
            guard let text = await AppleIntelligence.recap(facts: facts), !text.isEmpty else { return }
            recap = text
            UserDefaults.standard.set(text, forKey: "recap.text"); UserDefaults.standard.set(key, forKey: "recap.key")
        }
    }

    /// Plain facts for the model; it may only restate these.
    private var facts: String {
        // Rounded to the hour, so a shift in progress doesn't rewrite the recap every minute.
        let now = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        let currency = store.data.rules.currency
        let monthKey = String(Shift.dayString(now).prefix(7))
        let month = store.data.shifts.filter { $0.currency == currency && $0.day.hasPrefix(monthKey) }
        let split = EarningsBreakdown(shifts: month, now: now)
        var lines = [
            "Month: \(now.formatted(.dateTime.month(.wide)))",
            "Earned from work done: \(money(split.earned, currency))",
            "Already paid: \(money(split.paid, currency))",
            "Waiting to be paid: \(money(split.owed, currency))",
            "Still to work this month: \(money(split.booked, currency)) across \(split.shiftsBooked) shifts",
            "Hours worked: \(PayEngine.rounded(split.hoursWorked))",
            "Shifts worked: \(split.shiftsWorked)",
        ]
        let jobs = Dictionary(grouping: month, by: \.event).mapValues(\.count)
        if let top = jobs.max(by: { $0.value < $1.value }), top.value > 1 { lines.append("Most frequent job: \(top.key) (\(top.value) shifts)") }
        if let next = store.data.shifts.filter({ $0.startDate > now }).min(by: { $0.startDate < $1.startDate }) {
            lines.append("Next shift: \(next.event) on \(next.startDate.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
        }
        return lines.joined(separator: "\n")
    }
}
