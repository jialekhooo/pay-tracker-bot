import Foundation

public enum TrackerError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

public struct PayRules: Codable, Equatable {
    public var rate: Decimal = 15
    public var currency = "SGD"
    public var overtimeAfter: Decimal? = nil
    public var overtimeMultiplier: Decimal = Decimal(string: "1.5")!
    public init() {}
}

public enum PayEngine {
    public static func rounded(_ amount: Decimal) -> Decimal {
        var source = amount
        var result = Decimal()
        NSDecimalRound(&result, &source, 2, .plain)
        return result
    }

    // Mirrors paybot/pay.py: breaks are deducted before applying overtime.
    public static func calculate(hours: Decimal, rate: Decimal, rules: PayRules) -> Decimal {
        guard let threshold = rules.overtimeAfter, hours > threshold else {
            return rounded(hours * rate)
        }
        return rounded(threshold * rate + (hours - threshold) * rate * rules.overtimeMultiplier)
    }
}

public struct Shift: Identifiable, Codable, Equatable {
    public static let maxEvent = 120, maxLocation = 1000
    public var id: UUID
    public var sourceID: String?
    public var event: String
    public var location: String
    public var day: String
    public var startMinute: Int
    public var endMinute: Int
    public var breakMinutes: Int
    public var paidBreak: Bool
    public var rate: Decimal
    public var fixedPay: Decimal?
    public var pay: Decimal
    public var currency: String
    public var paid: Bool
    public var paymentDue: String?
    public var overtimeAfter: Decimal?
    public var overtimeMultiplier: Decimal

    public init(id: UUID = UUID(), sourceID: String? = nil, event: String, location: String = "",
                day: String, startMinute: Int, endMinute: Int, breakMinutes: Int = 0,
                paidBreak: Bool = false, rate: Decimal, fixedPay: Decimal? = nil,
                rules: PayRules = PayRules(), paid: Bool = false, paymentDue: String? = nil) throws {
        guard !event.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrackerError.invalid("Enter an event name.")
        }
        guard Self.date(day) != nil, (0..<1440).contains(startMinute), (0..<1440).contains(endMinute) else {
            throw TrackerError.invalid("Enter a valid date and times.")
        }
        // The same limits as the server, so a record saved here can always sync.
        guard event.count <= Self.maxEvent, location.count <= Self.maxLocation, (sourceID ?? "").count <= 100 else {
            throw TrackerError.invalid("Event names can be up to \(Self.maxEvent) characters and locations up to \(Self.maxLocation).")
        }
        let duration = endMinute > startMinute ? endMinute - startMinute : endMinute + 1440 - startMinute
        guard breakMinutes >= 0, breakMinutes < duration, rate >= 0, fixedPay == nil || fixedPay! >= 0,
              rules.overtimeAfter == nil || rules.overtimeAfter! > 0, rules.overtimeMultiplier >= 1,
              rules.currency.count == 3, rules.currency.allSatisfy({ $0.isASCII && $0.isUppercase }) else {
            throw TrackerError.invalid("Check the pay, currency, overtime and break values. Breaks must be shorter than the shift.")
        }
        if let paymentDue, Self.date(paymentDue) == nil { throw TrackerError.invalid("Invalid payment due date.") }
        self.id = id; self.sourceID = sourceID; self.event = event.trimmingCharacters(in: .whitespacesAndNewlines)
        self.location = location; self.day = day; self.startMinute = startMinute; self.endMinute = endMinute
        self.breakMinutes = breakMinutes; self.paidBreak = paidBreak; self.rate = rate
        self.fixedPay = fixedPay; self.currency = rules.currency; self.paid = paid; self.paymentDue = paymentDue
        self.overtimeAfter = rules.overtimeAfter; self.overtimeMultiplier = rules.overtimeMultiplier
        let hours = Decimal(duration - (paidBreak ? 0 : breakMinutes)) / 60
        self.pay = fixedPay.map(PayEngine.rounded) ?? PayEngine.calculate(hours: hours, rate: rate, rules: rules)
    }

    public var durationMinutes: Int { endMinute > startMinute ? endMinute - startMinute : endMinute + 1440 - startMinute }
    public var hours: Decimal { Decimal(durationMinutes - (paidBreak ? 0 : breakMinutes)) / 60 }
    public static func date(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: day), formatter.string(from: date) == day else { return nil }
        return date
    }
    public static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    public var startDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                  hour: startMinute / 60, minute: startMinute % 60))!
    }
    public var endDate: Date {
        let calendar = Calendar(identifier: .gregorian)
        let endDay = endMinute <= startMinute ? calendar.date(byAdding: .day, value: 1, to: startDate)! : startDate
        return calendar.date(bySettingHour: endMinute / 60, minute: endMinute % 60, second: 0, of: endDay)!
    }
    public func overlaps(_ other: Shift) -> Bool { id != other.id && startDate < other.endDate && other.startDate < endDate }
    public static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}

public enum ClaimCategory: String, Codable, CaseIterable, Identifiable {
    case cab, food, miscellaneous
    public var id: String { rawValue }
    public var title: String {
        switch self { case .cab: return "Cab"; case .food: return "Food"; case .miscellaneous: return "Miscellaneous" }
    }
    public var symbol: String {
        switch self { case .cab: return "car.fill"; case .food: return "fork.knife"; case .miscellaneous: return "receipt" }
    }
}

// The original type name stays source-compatible; claims now support multiple categories.
public struct CabClaim: Identifiable, Codable, Equatable {
    public static let maxNote = 250
    public var id = UUID()
    public var shiftID: UUID
    public var day: String
    public var amount: Decimal
    public var note: String
    public var receiptID: UUID?
    public var category: ClaimCategory = .cab
    public init(shiftID: UUID, day: String, amount: Decimal, note: String, category: ClaimCategory = .cab) {
        self.shiftID = shiftID; self.day = day; self.amount = amount; self.note = note; self.category = category
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(shiftID, forKey: .shiftID)
        try values.encode(day, forKey: .day); try values.encode(amount, forKey: .amount)
        try values.encode(note, forKey: .note); try values.encode(category, forKey: .category)
        try values.encode(receiptID, forKey: .receiptID)
    }
    private enum CodingKeys: String, CodingKey { case id, shiftID, day, amount, note, category, receiptID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        shiftID = try values.decode(UUID.self, forKey: .shiftID)
        day = try values.decode(String.self, forKey: .day)
        amount = try values.decode(Decimal.self, forKey: .amount)
        note = try values.decode(String.self, forKey: .note)
        category = try values.decodeIfPresent(ClaimCategory.self, forKey: .category) ?? .cab
        receiptID = try values.decodeIfPresent(UUID.self, forKey: .receiptID)
    }
}

public struct TrackerData: Codable, Equatable {
    public var version = 1
    public var shifts: [Shift] = []
    public var claims: [CabClaim] = []
    public var expenses: [CabClaim]?
    public var rules = PayRules()
    public var preferences: AppPreferences?
    public init() {}

    private enum CodingKeys: String, CodingKey { case version, shifts, claims, expenses, rules, preferences }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        shifts = try c.decode([Shift].self, forKey: .shifts)
        claims = try c.decode([CabClaim].self, forKey: .claims)
        expenses = try c.decodeIfPresent([CabClaim].self, forKey: .expenses)
        rules = try c.decode(PayRules.self, forKey: .rules)
        preferences = try c.decodeIfPresent(AppPreferences.self, forKey: .preferences)
        try validate()
        self = reimbursementsOnly
        try validate()
    }
    /// Preserve older expense records as reimbursements, including receipt references.
    public var reimbursementsOnly: TrackerData {
        var next = self
        for var claim in expenses ?? [] {
            if let old = next.claims.first(where: { $0.id == claim.id }) {
                if old == claim { continue }
                claim.id = SavedPayer.legacyID("reimbursement:" + claim.id.uuidString.lowercased())
                if next.claims.contains(where: { $0 == claim }) { continue }
            }
            next.claims.append(claim)
        }
        if expenses != nil { next.expenses = [] }
        return next
    }

    public mutating func importShifts(_ incoming: [Shift]) -> Int {
        var added = 0
        for shift in incoming {
            // IDs from separate Telegram accounts may be identical; include the exported content.
            let duplicate = shifts.contains {
                ($0.sourceID ?? $0.id.uuidString) == shift.sourceID && $0.day == shift.day &&
                $0.startMinute == shift.startMinute && $0.endMinute == shift.endMinute &&
                $0.event == shift.event && $0.pay == shift.pay && $0.currency == shift.currency &&
                $0.location == shift.location && $0.breakMinutes == shift.breakMinutes && $0.paidBreak == shift.paidBreak
            }
            if !duplicate { shifts.append(shift); added += 1 }
        }
        return added
    }

    /// Server limits: anything longer is trimmed before upload so one record can never block syncing.
    public var withinServerLimits: TrackerData {
        var copy = self
        for index in copy.shifts.indices {
            if copy.shifts[index].event.count > Shift.maxEvent { copy.shifts[index].event = String(copy.shifts[index].event.prefix(Shift.maxEvent)) }
            if copy.shifts[index].location.count > Shift.maxLocation { copy.shifts[index].location = String(copy.shifts[index].location.prefix(Shift.maxLocation)) }
        }
        for index in copy.claims.indices where copy.claims[index].note.count > CabClaim.maxNote {
            copy.claims[index].note = String(copy.claims[index].note.prefix(CabClaim.maxNote))
        }
        return copy
    }

    public func validate() throws {
        guard version == 1, Set(shifts.map(\.id)).count == shifts.count,
              Set(claims.map(\.id)).count == claims.count else {
            throw TrackerError.invalid("This archive is unsupported or contains duplicate records.")
        }
        // Reuse entry validation before any decoded record can be displayed.
        _ = try Shift(event: "Defaults", day: "2026-01-01", startMinute: 0, endMinute: 60, rate: rules.rate, rules: rules)
        for shift in shifts {
            var rules = PayRules()
            rules.currency = shift.currency; rules.overtimeAfter = shift.overtimeAfter
            rules.overtimeMultiplier = shift.overtimeMultiplier
            let checked = try Shift(id: shift.id, event: shift.event, location: shift.location, day: shift.day,
                                    startMinute: shift.startMinute, endMinute: shift.endMinute,
                                    breakMinutes: shift.breakMinutes, paidBreak: shift.paidBreak,
                                    rate: shift.rate, fixedPay: shift.fixedPay, rules: rules,
                                    paid: shift.paid, paymentDue: shift.paymentDue)
            guard checked.pay == shift.pay else { throw TrackerError.invalid("An archived payout does not match its saved pay rules.") }
        }
        guard (expenses ?? []).count <= 20000, Set((expenses ?? []).map(\.id)).count == (expenses ?? []).count else { throw TrackerError.invalid("Invalid reimbursement records.") }
        for claim in claims + (expenses ?? []) {
            guard shifts.contains(where: { $0.id == claim.shiftID }), Shift.date(claim.day) != nil,
                  claim.amount > 0, !claim.amount.isNaN else { throw TrackerError.invalid("An archived claim is invalid.") }
        }
        if let preferences { try preferences.validate() }
    }
}
