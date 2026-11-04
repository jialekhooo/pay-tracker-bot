import Foundation

public struct ReceiptSuggestions {
    public var amount: Decimal?
    public var day: String?
    public init(text: String = "") {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var candidates: [(Int, Decimal)] = []
        let number = #"(?<![0-9.\-])[0-9][0-9,]*\s*\.\s*[0-9]{2}(?![0-9])"#
        for (index, line) in lines.enumerated() {
            guard let label = line.range(of: #"^\s*(grand\s+total|total(?:\s+(?:paid|amount|fare))?|amount\s+(?:paid|due|charged)|payment\s+total|fare)\b"#, options: [.regularExpression, .caseInsensitive]) else { continue }
            let title = String(line[label]).lowercased()
            let priority = title.contains("grand") || title.contains("paid") || title.contains("charged") ? 3 : title == "fare" ? 1 : 2
            var suffix = String(line[label.upperBound...])
            // OCR often returns the total label and right-aligned price as separate observations.
            if suffix.range(of: #"^\s*:?\s*(?:SGD|S\$|SG\$|USD|US\$|EUR|GBP|MYR|RM|\$|€|£)?\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil, index + 1 < lines.count {
                let next = lines[index + 1]
                if next.range(of: #"^(?:(?:SGD|S\$|SG\$|USD|US\$|EUR|GBP|MYR|RM|\$|€|£)\s*)?[0-9][0-9,]*\s*\.\s*[0-9]{2}\s*[>›]?$"#, options: [.regularExpression, .caseInsensitive]) != nil { suffix = next }
            }
            guard let regex = try? NSRegularExpression(pattern: number),
                  let match = regex.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)),
                  regex.numberOfMatches(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)) == 1,
                  let range = Range(match.range, in: suffix),
                  let value = ShiftCSV.decimal(String(suffix[range]).filter { !$0.isWhitespace && $0 != "," }), value > 0 else { continue }
            candidates.append((priority, value))
        }
        if let rank = candidates.map({ $0.0 }).max() {
            let values = Set(candidates.filter { $0.0 == rank }.map { $0.1 })
            if values.count == 1 { amount = values.first }
        }
        if let range = text.range(of: #"\b[0-9]{4}-[0-9]{2}-[0-9]{2}\b"#, options: .regularExpression) {
            let value = String(text[range]); if Shift.date(value) != nil { day = value }
        } else if let range = text.range(of: #"\b[0-9]{2}/[0-9]{2}/[0-9]{4}\b"#, options: .regularExpression) {
            let parts = text[range].split(separator: "/")
            let value = "\(parts[2])-\(parts[1])-\(parts[0])"; if Shift.date(value) != nil { day = value }
        }
    }
}
