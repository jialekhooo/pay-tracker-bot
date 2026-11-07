import Foundation

/// One working date read from a pasted job message.
public struct PastedJobDate: Equatable {
    public var day: String
    public var startMinute: Int
    public var endMinute: Int
    public init(day: String, startMinute: Int, endMinute: Int) {
        self.day = day; self.startMinute = startMinute; self.endMinute = endMinute
    }
}

/// What a job offer message (WhatsApp, Telegram, email) says about the work.
/// Every field is a suggestion: the shift editor shows it for review before saving.
public struct PastedJob: Equatable {
    public var event: String?
    public var location: String?
    public var rate: Decimal?
    /// Fixed payout for each date (a per-day rate, or a lump sum split across the dates).
    public var fixedPay: Decimal?
    public var currency: String?
    public var breakMinutes: Int?
    public var dates: [PastedJobDate] = []
    /// Notes worth showing, such as how a lump sum was split.
    public var notes: [String] = []
    /// A lump sum split across the dates: the last date takes the leftover cents, so the shares add up exactly.
    public var lumpSum: Decimal?
    /// Lines with numbers that were not understood, so the person can check them.
    public var skipped: [String] = []
    public init() {}

    /// The event name to prefill: an explicit name, else the venue's name.
    public var name: String {
        if let event, !event.isEmpty { return event }
        if let location { return location.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? location }
        return ""
    }
}

public enum JobMessageParser {
    public static let maximumLength = 5000
    public static let maximumDates = 100

    public static func parse(_ text: String, today: Date = Date(), calendar: Calendar = TrackerCalendar.calendar) -> PastedJob {
        var job = PastedJob()
        var address: String?
        var role: String?
        // A heading line with no dates, times or pay ("Nike Pop-up"), used when no other line names the event.
        var title: String?
        var titleVenue: String?
        var sawLine = false
        var items: [Item] = []
        var flat: Decimal?
        // "19th: 3.30pm - 6pm" or "21,22nd: 9am - 6pm": times for days of the month listed on another line.
        var dayTimes: [(days: [Int], time: (start: Int, end: Int))] = []
        let today = calendar.startOfDay(for: today)

        for raw in normalized(String(text.prefix(maximumLength))).components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*>·").union(.whitespaces))
            guard !line.isEmpty else { continue }
            let isFirstLine = !sawLine
            sawLine = true
            var content = line
            // "📍 Marina Bay Sands": a pin marks the venue, as WhatsApp job posts often do.
            if let pin = line.firstMatch(of: #/^(?:📍|📌)\s*(.+)$/#) {
                if job.location == nil { job.location = clean(String(pin.1)) }
                continue
            }
            if let (days, rest) = dayPrefix(line) {
                var lower = rest.lowercased()
                if readDates(&lower, today: today, calendar: calendar).isEmpty, let time = readTime(&lower) {
                    dayTimes.append((days, time)); continue
                }
            }
            if let (key, value) = label(line) {
                switch key {
                case .location: if job.location == nil { job.location = clean(value) }; continue
                case .address: if address == nil { address = clean(value) }; continue
                case .event: if job.event == nil { job.event = clean(value) }; continue
                case .role: if role == nil { role = clean(value) }; continue
                case .ignored: continue
                case .breakTime: if job.breakMinutes == nil { job.breakMinutes = breakLength(value) }; continue
                case .schedule, .pay: content = value
                }
            }
            var lower = content.lowercased()
            let pay = readPay(&lower)
            if let pay {
                switch pay {
                case .hourly(let value, let currency): job.rate = job.rate ?? value; job.currency = job.currency ?? currency
                case .perDay(let value, let currency): job.fixedPay = job.fixedPay ?? value; job.currency = job.currency ?? currency
                case .flat(let value, let currency): flat = flat ?? value; job.currency = job.currency ?? currency
                }
            }
            if job.breakMinutes == nil, let match = lower.firstMatch(of: #/(\d+(?:\.\d+)?\s*(?:h|hr|hrs|hour|hours|m|min|mins|minutes))\s*(?:lunch\s*|meal\s*)?break/#) {
                job.breakMinutes = breakLength(String(match.1))
                lower = lower.replacingOccurrences(of: String(match.0), with: String(repeating: " ", count: match.0.count))
            }
            let days = readDates(&lower, today: today, calendar: calendar)
            let time = readTime(&lower)
            if days.isEmpty && time == nil {
                // Only lines with numbers left unread are skipped; a break already read ("1hr break") is not.
                if pay == nil, lower.rangeOfCharacter(from: .decimalDigits) != nil { job.skipped.append(line) }
                if isFirstLine, pay == nil, content == line, let found = heading(line) { title = found.name; titleVenue = found.venue }
                continue
            }
            items.append(Item(days: days, time: time))
            // Bot-style lines ("Wedding gig 12/8 6pm-11pm @ MBS") carry a name and venue too.
            if !days.isEmpty || time != nil {
                let rest = leftover(lower, original: content)
                if job.location == nil, let venue = rest.venue { job.location = venue }
                if job.event == nil, let name = rest.name { job.event = name }
            }
        }

        // Day times that match no listed date are treated as a time on its own line.
        let listed = Set(items.flatMap(\.days).compactMap { Int($0.suffix(2)) })
        for entry in dayTimes where !entry.days.contains(where: listed.contains) { items.append(Item(days: [], time: entry.time)) }
        // Dates listed without times take the nearest time given on its own line.
        let loneTimes = items.enumerated().filter { $0.element.days.isEmpty }.compactMap { index, item in item.time.map { (index, $0) } }
        var seen = Set<String>()
        for (index, item) in items.enumerated() where !item.days.isEmpty {
            let fallback = item.time ?? loneTimes.first(where: { $0.0 > index })?.1 ?? loneTimes.last(where: { $0.0 < index })?.1
            var missing: [String] = []
            for day in item.days {
                // A time written for this day of the month ("21,22nd: 9am - 6pm") wins over the shared one.
                let dayOfMonth = Int(day.suffix(2)) ?? 0
                guard let time = dayTimes.last(where: { $0.days.contains(dayOfMonth) })?.time ?? fallback else { missing.append(day); continue }
                let key = "\(day)|\(time.start)|\(time.end)"
                guard seen.insert(key).inserted, job.dates.count < maximumDates else { continue }
                job.dates.append(PastedJobDate(day: day, startMinute: time.start, endMinute: time.end))
            }
            if !missing.isEmpty { job.notes.append("No time found for " + missing.map(display).joined(separator: ", ") + ".") }
        }
        job.dates.sort { ($0.day, $0.startMinute) < ($1.day, $1.startMinute) }

        if job.event == nil, let title { job.event = title }
        if job.location == nil, let titleVenue { job.location = titleVenue }
        if job.event == nil, let role { job.event = role }
        if let address {
            if let location = job.location {
                if !address.lowercased().contains(location.lowercased()) { job.location = location + ", " + address }
            } else { job.location = address }
        }
        if let flat, job.fixedPay == nil, job.rate == nil {
            let count = max(job.dates.count, 1)
            let share = PayEngine.rounded(flat / Decimal(count))
            job.fixedPay = share
            if count > 1 {
                job.lumpSum = flat
                let last = flat - share * Decimal(count - 1)
                job.notes.append(last == share ? "Lump sum of \(flat) split across \(count) dates (\(share) each)."
                                               : "Lump sum of \(flat) split across \(count) dates (\(share) each, \(last) on the last date).")
            }
        }
        if let location = job.location, location.count > 1000 { job.location = String(location.prefix(1000)) }
        if let event = job.event, event.count > 120 { job.event = String(event.prefix(120)) }
        return job
    }

    // MARK: - Lines

    private struct Item { var days: [String]; var time: (start: Int, end: Int)? }
    private enum Label { case location, address, event, role, schedule, pay, breakTime, ignored }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "_", with: " ")
    }

    private static func label(_ line: String) -> (Label, String)? {
        guard let match = line.firstMatch(of: #/^([A-Za-z][A-Za-z ]{0,20}?)\s*:\s*(.*)$/#) else { return nil }
        let key = match.1.lowercased().trimmingCharacters(in: .whitespaces)
        let value = String(match.2).trimmingCharacters(in: .whitespaces)
        let groups: [(Label, [String])] = [
            (.location, ["location", "venue", "place", "loc", "where", "site"]),
            (.address, ["address", "addr"]),
            (.event, ["event", "event name", "job", "project", "show", "campaign", "brand", "client", "title"]),
            (.role, ["role", "position", "job scope", "scope"]),
            (.schedule, ["date", "dates", "day", "days", "time", "timing", "timings", "schedule", "when", "working hours", "hours", "shift", "shifts"]),
            (.breakTime, ["break", "breaks", "lunch", "lunch break", "meal break"]),
            (.pay, ["pay", "rate", "pay rate", "salary", "wage", "wages", "remuneration", "payment"]),
        ]
        for (kind, keys) in groups where keys.contains(key) { return value.isEmpty ? (.ignored, value) : (kind, value) }
        // Contact numbers, attire and similar details are deliberately not used.
        let ignored = ["contact", "contact person", "contact no", "pic", "poc", "name", "phone", "tel", "hp", "mobile", "email",
                       "attire", "dress code", "dresscode", "remarks", "remark", "note", "notes", "requirements", "requirement",
                       "reporting time", "report time", "call time", "meal", "meals", "gender", "age", "pax", "headcount", "deadline"]
        return ignored.contains(key) ? (.ignored, value) : nil
    }

    /// "19th:", "21,22nd:", "12 & 13:", "21-22:" at the start of a line: days of the month, then the rest of the line.
    /// A clock time such as "10:00" is never read as a day (the colon must not be followed by a digit).
    private static func dayPrefix(_ line: String) -> ([Int], String)? {
        guard let match = line.firstMatch(of: #/^((?:\d{1,2}(?:st|nd|rd|th)?\s*(?:,|&|and|-|to|/)\s*)*\d{1,2}(?:st|nd|rd|th)?)\s*:(?!\d)\s*(.+)$/#.ignoresCase()) else { return nil }
        var days: [Int] = [], rangeNext = false
        var number = ""
        func flush() {
            guard let value = Int(number) else { return }
            if rangeNext, let previous = days.last, value > previous, value - previous <= 31 { days += Array((previous + 1)...value) } else { days.append(value) }
            number = ""; rangeNext = false
        }
        for char in match.1.lowercased() {
            if char.isNumber { number.append(char) }
            else { flush(); if char == "-" || char == "t" { rangeNext = true } }
        }
        flush()
        let valid = days.filter { (1...31).contains($0) }
        return valid.isEmpty ? nil : (valid, String(match.2))
    }

    private static func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;-").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func breakLength(_ text: String) -> Int? {
        guard let match = text.lowercased().firstMatch(of: #/(\d+(?:\.\d+)?)\s*(h|hr|hrs|hour|hours|m|min|mins|minutes)\b/#),
              let value = Double(match.1) else { return nil }
        let minutes = Int((match.2.hasPrefix("h") ? value * 60 : value).rounded())
        return (1..<720).contains(minutes) ? minutes : nil
    }

    // MARK: - Pay

    private enum Pay { case hourly(Decimal, String?), perDay(Decimal, String?), flat(Decimal, String?) }

    private static func readPay(_ line: inout String) -> Pay? {
        // "1,200" is one amount; commas are stripped before reading it.
        let money = #"(?:(sgd|s\$|usd|myr|rm|\$)\s*)?((?:\d{1,3}(?:,\d{3})+|\d{1,5})(?:\.\d{1,2})?)(?![\d,]*\d)\s*(sgd)?"#
        let patterns: [(String, (Decimal, String?) -> Pay)] = [
            (money + #"\s*(?:/\s*|per\s+|an?\s+|p/)(?:h|hr|hrs|hour)\b"#, { .hourly($0, $1) }),
            (money + #"\s*(?:hourly|ph)\b"#, { .hourly($0, $1) }),
            (money + #"\s*(?:/\s*|per\s+|a\s+)(?:day|d|shift)\b"#, { .perDay($0, $1) }),
            (money + #"\s*(?:flat|lump\s*sum|total|nett|net|in\s+total)\b"#, { .flat($0, $1) }),
            (#"(?:flat|lump\s*sum|total)\s*(?:of\s*)?"# + money, { .flat($0, $1) }),
        ]
        for (pattern, make) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let amountRange = Range(match.range(at: 2), in: line),
                  let amount = Decimal(string: line[amountRange].replacingOccurrences(of: ",", with: "")) else { continue }
            let symbol = [1, 3].compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }.first
            // A bare number without a currency or unit word is never treated as pay.
            if symbol == nil, pattern.hasPrefix("(?:flat") == false, !pattern.contains("hour"), !pattern.contains("day") { continue }
            // "Total 3 days" is a count, not pay: a lump sum written before the number needs a currency.
            if symbol == nil, pattern.hasPrefix("(?:flat") { continue }
            let currency: String? = switch symbol { case "sgd", "s$": "SGD"; case "usd": "USD"; case "myr", "rm": "MYR"; default: nil }
            blank(&line, match.range)
            return make(amount, currency)
        }
        return nil
    }

    // MARK: - Dates

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let monthPattern = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)(?:uary|ruary|ch|il|e|y|ust|t|tember|ober|ember|\.)?"#
    private static let dayPattern = #"(\d{1,2})(?:st|nd|rd|th)?"#
    private static let joiner = #"\s*(?:-|to|till|until|&|and|,|/)\s*"#

    private struct Found { var range: NSRange; var days: [Date]; var single: Bool }

    private static func readDates(_ line: inout String, today: Date, calendar: Calendar) -> [String] {
        var found: [Found] = []
        func scan(_ pattern: String, _ build: (NSTextCheckingResult, String) -> [Date]?) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard !found.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }),
                      let days = build(match, line), !days.isEmpty else { continue }
                found.append(Found(range: match.range, days: days, single: days.count == 1))
            }
        }
        func group(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }

        // 2026-11-12
        scan(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#) { match, text in
            guard let y = group(match, 1, text).flatMap(Int.init), let m = group(match, 2, text).flatMap(Int.init),
                  let d = group(match, 3, text).flatMap(Int.init) else { return nil }
            return date(y, m, d, calendar).map { [$0] }
        }
        // 12th Nov, 13-14th Nov, 13, 14 & 16 November 2026
        scan(#"\b"# + dayPattern + #"((?:"# + joiner + dayPattern + #")*)\s*(?:of\s+)?"# + monthPattern + #"\b(?:\s*,?\s*(20\d{2})\b)?"#) { match, text in
            guard let month = group(match, 4, text).flatMap({ months.firstIndex(of: $0) }).map({ $0 + 1 }),
                  let listRange = Range(NSRange(location: match.range.location, length: match.range(at: 4).location - match.range.location), in: text) else { return nil }
            return expand(String(text[listRange]), month: month, year: group(match, 5, text).flatMap(Int.init), today: today, calendar: calendar)
        }
        // Nov 12, Nov 13-14, November 12 2026
        // The list stops before a number that is really a time ("Nov 15, 10-6pm", "Nov 15, 10:00").
        scan(#"\b"# + monthPattern + #"\s+"# + dayPattern + #"\b((?:"# + joiner + dayPattern + #"\b(?!\s*(?:[:.]\d{2}|(?:-|to)\s*\d{1,2}(?:[:.]\d{2})?\s*(?:am|pm|noon))))*)(?:\s*,?\s*(20\d{2})\b)?"#) { match, text in
            guard let month = group(match, 1, text).flatMap({ months.firstIndex(of: $0) }).map({ $0 + 1 }),
                  let first = group(match, 2, text) else { return nil }
            return expand(first + (group(match, 3, text) ?? ""), month: month, year: group(match, 5, text).flatMap(Int.init), today: today, calendar: calendar)
        }
        // 12/8, 12-14/8, 12/8/2026 (day first, as written in Singapore)
        scan(#"(?<![\d/.$])(\d{1,2})(?:\s*-\s*(\d{1,2}))?/(\d{1,2})(?:/(\d{2,4}))?(?![\d/])"#) { match, text in
            guard let d = group(match, 1, text).flatMap(Int.init), let m = group(match, 3, text).flatMap(Int.init), (1...12).contains(m) else { return nil }
            var year = group(match, 4, text).flatMap(Int.init)
            if let y = year, y < 100 { year = 2000 + y }
            let last = group(match, 2, text).flatMap(Int.init) ?? d
            return expand("\(d)-\(last)", month: m, year: year, today: today, calendar: calendar)
        }
        scan(#"\b(today|tonight|tomorrow|tmr|tmrw|tml)\b"#) { match, text in
            let offset = ["today", "tonight"].contains(group(match, 1, text) ?? "") ? 0 : 1
            return calendar.date(byAdding: .day, value: offset, to: today).map { [$0] }
        }
        if found.isEmpty {
            scan(#"\b(mon|tue|wed|thu|fri|sat|sun)(?:day|sday|nesday|rsday|urday|s|t|r|rs)?\b"#) { match, text in
                guard let name = group(match, 1, text),
                      let weekday = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].firstIndex(of: name) else { return nil }
                return calendar.nextDate(after: calendar.date(byAdding: .day, value: -1, to: today)!, matching: DateComponents(weekday: weekday + 1), matchingPolicy: .nextTime).map { [$0] }
            }
        }

        // "30 Nov - 2 Dec" or "12/8 to 14/8": two single dates joined by a range word.
        found.sort { $0.range.location < $1.range.location }
        var merged: [Found] = []
        for item in found {
            if let previous = merged.last, previous.single, item.single,
               let between = Range(NSRange(location: NSMaxRange(previous.range), length: item.range.location - NSMaxRange(previous.range)), in: line),
               line[between].firstMatch(of: #/^\s*(-|to|till|until)\s*$/#) != nil,
               let from = previous.days.first, let to = item.days.first, from < to,
               let span = calendar.dateComponents([.day], from: from, to: to).day, span <= 31 {
                merged[merged.count - 1] = Found(range: NSUnionRange(previous.range, item.range),
                                                 days: (0...span).compactMap { calendar.date(byAdding: .day, value: $0, to: from) }, single: false)
            } else { merged.append(item) }
        }
        for item in found { blank(&line, item.range) }
        // Remove weekday words such as "(Wed)" so they are not read as names.
        line = line.replacingOccurrences(of: #"\(?\b(mon|monday|tue|tues|tuesday|wed|weds|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday|sun|sunday)\b\)?"#, with: " ", options: .regularExpression)
        return merged.flatMap(\.days).map { date in
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
    }

    /// Expand "13-14", "13, 14 & 16" or "12" into dates of one month.
    private static func expand(_ list: String, month: Int, year: Int?, today: Date, calendar: Calendar) -> [Date]? {
        var tokens: [(Int, Bool)] = []  // day, joined to the previous one by a range word
        var rangeNext = false
        let scanner = list.lowercased()
        var index = scanner.startIndex
        while index < scanner.endIndex {
            if scanner[index].isNumber {
                var end = index
                while end < scanner.endIndex, scanner[end].isNumber { end = scanner.index(after: end) }
                if let value = Int(scanner[index..<end]) { tokens.append((value, rangeNext)) }
                rangeNext = false; index = end
            } else {
                let rest = scanner[index...]
                if rest.hasPrefix("-") || rest.hasPrefix("to") || rest.hasPrefix("till") || rest.hasPrefix("until") { rangeNext = true }
                else if rest.hasPrefix(",") || rest.hasPrefix("&") || rest.hasPrefix("and") || rest.hasPrefix("/") { rangeNext = false }
                index = scanner.index(after: index)
            }
        }
        var days: [Int] = []
        for (day, isRange) in tokens {
            // Days in a list only go forwards; anything else isn't part of the date list.
            if let previous = days.last, day <= previous { break }
            if isRange, let previous = days.last, day - previous <= 31 { days += Array((previous + 1)...day) }
            else { days.append(day) }
        }
        guard !days.isEmpty else { return nil }
        let resolvedYear: Int
        if let year { resolvedYear = year }
        else {
            let current = calendar.component(.year, from: today)
            guard let first = date(current, month, days[0], calendar) else { return nil }
            // A date more than two months ago most likely means next year.
            resolvedYear = first < calendar.date(byAdding: .day, value: -60, to: today)! ? current + 1 : current
        }
        let dates = days.compactMap { date(resolvedYear, month, $0, calendar) }
        return dates.count == days.count ? dates : nil
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar) -> Date? {
        guard (2000...2100).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.month, from: date) == month else { return nil }
        return date
    }

    private static func display(_ day: String) -> String {
        guard let date = Shift.date(day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_SG"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    // MARK: - Times

    private static func readTime(_ line: inout String) -> (start: Int, end: Int)? {
        let token = #"(\d{4}|\d{1,2}(?:[:.]\d{2})?)\s*(am|pm|a\.m\.|p\.m\.|noon)?"#
        let patterns = [
            #"(?<![\d/.$])"# + token + #"\s*(?:hrs?|h)?\s*(?:-|to|till|until)\s*"# + token + #"\s*(?:hrs?|h\b)?"#,
            #"(?<![\d/.$])(\d{1,2}:\d{2})()\s+(\d{1,2}:\d{2})()"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func part(_ index: Int) -> String? { Range(match.range(at: index), in: line).map { String(line[$0]) }.flatMap { $0.isEmpty ? nil : $0 } }
            guard let first = clock(part(1)), let second = clock(part(3)),
                  let resolved = resolve(first, part(2), second, part(4)) else { continue }
            blank(&line, match.range)
            return resolved
        }
        return nil
    }

    private struct Clock { var hour: Int; var minute: Int; var twentyFour: Bool }

    private static func clock(_ text: String?) -> Clock? {
        guard let text else { return nil }
        if text.count == 4, let value = Int(text) {
            let hour = value / 100, minute = value % 100
            guard hour <= 24, minute < 60 else { return nil }
            return Clock(hour: hour % 24, minute: minute, twentyFour: true)
        }
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "." }).compactMap { Int($0) }
        guard let hour = parts.first, hour <= 24 else { return nil }
        let minute = parts.count > 1 ? parts[1] : 0
        guard minute < 60 else { return nil }
        // "06:00" or "06.30" (a leading zero) is written on a 24-hour clock, so it's the morning.
        return Clock(hour: hour % 24, minute: minute, twentyFour: hour > 12 || (text.contains(":") && hour == 0) || (text.hasPrefix("0") && text.count > 1))
    }

    private static func resolve(_ start: Clock, _ startSuffix: String?, _ end: Clock, _ endSuffix: String?) -> (start: Int, end: Int)? {
        func meridiem(_ suffix: String?) -> Bool? {
            guard let suffix else { return nil }
            if suffix == "noon" { return true }
            return suffix.hasPrefix("p")
        }
        func minutes(_ clock: Clock, pm: Bool?) -> Int? {
            guard let pm, !clock.twentyFour else { return clock.hour * 60 + clock.minute }
            guard clock.hour <= 12 else { return nil }
            let hour = clock.hour % 12 + (pm ? 12 : 0)
            return hour * 60 + clock.minute
        }
        var startPM = meridiem(startSuffix), endPM = meridiem(endSuffix)
        if startPM == nil, let endPM, !start.twentyFour {
            // "9-5pm" starts in the morning; "6-11pm" starts in the evening.
            let same = minutes(start, pm: endPM), finish = minutes(end, pm: endPM)
            startPM = (same != nil && finish != nil && same! < finish!) ? endPM : !endPM
        }
        if endPM == nil, let startPM, !end.twentyFour {
            let same = minutes(end, pm: startPM), begin = minutes(start, pm: startPM)
            endPM = (same != nil && begin != nil && same! > begin!) ? startPM : !startPM
        }
        guard var first = minutes(start, pm: startPM), var last = minutes(end, pm: endPM) else { return nil }
        if startPM == nil, endPM == nil, !start.twentyFour, !end.twentyFour {
            // Plain "9-6" or "2-10": assume daytime work.
            if start.hour < 7 { first += 12 * 60 }
            if last <= first, last + 12 * 60 < 24 * 60 { last += 12 * 60 }
        }
        guard first != last, (0..<1440).contains(first), (0..<1440).contains(last) else { return nil }
        return (first, last)
    }

    // MARK: - Names

    private static func leftover(_ lower: String, original: String) -> (name: String?, venue: String?) {
        // Keep the original capitalisation for the parts that were not dates, times or pay.
        var kept = ""
        for (low, char) in zip(lower, original) { kept.append(low == " " && char != " " ? " " : char) }
        var name = kept, venue: String?
        if let at = kept.range(of: #"(\s@\s*|@|\s+at\s+)"#, options: [.regularExpression, .caseInsensitive]) {
            name = String(kept[..<at.lowerBound]); venue = clean(String(kept[at.upperBound...]))
        } else if kept.contains("|") {
            // "Event crew for AI pop up | 19, 21 Nov | New Bahru": name first, venue last.
            let parts = kept.split(separator: "|").compactMap { clean(String($0)) }
            if parts.count > 1 { name = parts[0]; venue = parts.last }
        }
        // "Event crew wanted for AI pop up" is about the AI pop up: drop the recruiting words in front.
        if let hiring = name.range(of: #"(?i)^.*?\b(?:wanted|needed|hiring|required|looking)\s+for\s+"#, options: .regularExpression),
           name[hiring.upperBound...].filter(\.isLetter).count >= 3 {
            name = String(name[hiring.upperBound...])
        }
        let filler = #"(?i)\b(from|on|hrs?|h|daily|each day|shift|shifts|and|available|anyone|need|needed|looking|pax|for|hi|hello|hey|free)\b|[()\[\]?!,&:]"#
        let words = name.replacingOccurrences(of: filler, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let letters = words.filter(\.isLetter).count
        return (letters >= 3 ? clean(words) : nil, venue)
    }

    /// A short heading such as "Nike Pop-up" or "Crew wanted for Nike Pop-up". Greetings, questions,
    /// sentences and lines with numbers are not headings.
    private static func heading(_ line: String) -> (name: String?, venue: String?)? {
        guard line.count <= 60, line.rangeOfCharacter(from: .decimalDigits) == nil, !line.hasSuffix("?"),
              line.range(of: #"(?i)^(hi|hello|hey|dear|urgent|good\s+(morning|afternoon|evening)|thank|thanks|pm|dm|whatsapp|text|looking|hiring|need|needed|seeking|urgently|anyone|available|calling)\b"#,
                         options: .regularExpression) == nil
        else { return nil }
        let found = leftover(line.lowercased(), original: line)
        return found.name == nil ? nil : found
    }

    private static func blank(_ line: inout String, _ range: NSRange) {
        guard let swiftRange = Range(range, in: line) else { return }
        line.replaceSubrange(swiftRange, with: String(repeating: " ", count: line[swiftRange].count))
    }
}
