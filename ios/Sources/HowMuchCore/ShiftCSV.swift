import Foundation

public enum ShiftCSV {
    // Handles both /export and Mini App exports, including quoted multiline fields.
    public static func decode(_ text: String) throws -> [Shift] {
        let rows = try parse(text.replacingOccurrences(of: "\u{feff}", with: ""))
        guard let header = rows.first else { throw TrackerError.invalid("The CSV is empty.") }
        let keys = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_") }
        guard Set(["date", "start", "end", "event", "pay", "currency"]).isSubset(of: Set(keys)),
              Set(keys).count == keys.count else {
            throw TrackerError.invalid("Choose a shift CSV exported by the Telegram bot or Mini App.")
        }
        return try rows.dropFirst().enumerated().compactMap { index, row in
            if row.allSatisfy({ $0.isEmpty }) { return nil }
            guard row.count == keys.count else { throw TrackerError.invalid("CSV row \(index + 2) has missing or extra columns.") }
            let values = Dictionary(uniqueKeysWithValues: zip(keys, row))
            func value(_ key: String) -> String { values[key, default: ""] }
            func minute(_ key: String) throws -> Int {
                let parts = value(key).split(separator: ":")
                guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
                      (0..<24).contains(h), (0..<60).contains(m) else {
                    throw TrackerError.invalid("CSV row \(index + 2) has an invalid time.")
                }
                return h * 60 + m
            }
            guard let pay = decimal(value("pay")), pay >= 0,
                  let breaks = decimal(values["break_hours"] ?? "0"), breaks >= 0,
                  breaks < 24 else {
                throw TrackerError.invalid("CSV row \(index + 2) has an invalid pay or break amount.")
            }
            // "Break minutes" is exact; "Break hours" may be rounded to 2 places (0.83 h = 50 min).
            let minuteValue = values["break_minutes"].flatMap { Double($0) } ?? NSDecimalNumber(decimal: breaks * 60).doubleValue
            let wholeMinutes = minuteValue.rounded()
            // Break hours rounded to 2 places are off by at most 0.3 minutes; anything more precise must be exact.
            let hoursText = values["break_hours"] ?? "0"
            let places = hoursText.split(separator: ".").dropFirst().first?.count ?? 0
            let tolerance = values["break_minutes"] == nil && places > 2 ? 0.000001 : 0.31
            guard abs(minuteValue - wholeMinutes) < tolerance, wholeMinutes >= 0, wholeMinutes < 24 * 60 else {
                throw TrackerError.invalid("CSV row \(index + 2) has a break that is not a whole number of minutes.")
            }
            let breakFlag = values["paid_break"] ?? values["break_paid"] ?? "no"
            guard ["yes", "no", "paid", "unpaid", "true", "false", "0", "1"].contains(breakFlag.lowercased()) else {
                throw TrackerError.invalid("CSV row \(index + 2) has an invalid paid break value.")
            }
            let paidFlag = (values["paid"] ?? "no").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ["yes", "no", "paid", "unpaid", "true", "false", "0", "1"].contains(paidFlag) else {
                throw TrackerError.invalid("CSV row \(index + 2) has an invalid paid status.")
            }
            let due = value("payment_due").trimmingCharacters(in: .whitespacesAndNewlines)
            var rules = PayRules()
            rules.currency = value("currency").uppercased()
            // Preserve the exported payout exactly: source files don't contain rate/overtime rules.
            return try Shift(sourceID: values["shift_id"] ?? values["id"], event: value("event"),
                             location: value("location"), day: value("date"),
                             startMinute: minute("start"), endMinute: minute("end"),
                             breakMinutes: Int(wholeMinutes),
                             paidBreak: ["yes", "paid", "true", "1"].contains(breakFlag.lowercased()),
                             rate: 0, fixedPay: pay, rules: rules,
                             paid: ["yes", "paid", "true", "1"].contains(paidFlag), paymentDue: due.isEmpty ? nil : due)
        }
    }

    public static func decimal(_ text: String) -> Decimal? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func encode(_ shifts: [Shift]) -> String {
        let header = ["Shift ID", "Date", "Start", "End", "Event", "Location", "Hours", "Break hours", "Break minutes", "Paid break", "Pay", "Currency", "Paid", "Payment due"]
        var rows = [header]
        for shift in shifts {
            rows.append([shift.sourceID ?? shift.id.uuidString, shift.day, Shift.clock(shift.startMinute),
                         Shift.clock(shift.endMinute), shift.event, shift.location, "\(PayEngine.rounded(shift.hours))",
                         "\(PayEngine.rounded(Decimal(shift.breakMinutes) / 60))", "\(shift.breakMinutes)", shift.paidBreak ? "Yes" : "No", "\(shift.pay)", shift.currency, shift.paid ? "Yes" : "No", shift.paymentDue ?? ""])
        }
        return rows.map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    private static func parse(_ text: String) throws -> [[String]] {
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false, i = 0
        while i < chars.count {
            let char = chars[i]
            if quoted {
                if char == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(char) }
            } else if char == "," || char == "\n" {
                row.append(field); field = ""; closed = false
                if char == "\n" { rows.append(row); row = [] }
            } else if char == "\"" && field.isEmpty && !closed {
                quoted = true
            } else {
                guard !closed && char != "\"" else { throw TrackerError.invalid("Malformed CSV quoting.") }
                field.append(char)
            }
            i += 1
        }
        guard !quoted else { throw TrackerError.invalid("The CSV has an unclosed quoted field.") }
        if !field.isEmpty || !row.isEmpty || closed { row.append(field); rows.append(row) }
        return rows
    }
}
