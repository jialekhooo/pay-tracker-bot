import Foundation

public enum AccountMerge {
    /// Three-way merge preserves independent edits. Shared edits require an explicit user choice.
    public static func merge(base: TrackerData?, local: TrackerData, remote: TrackerData) throws -> TrackerData {
        let base = base?.reimbursementsOnly; let local = local.reimbursementsOnly; let remote = remote.reimbursementsOnly
        try base?.validate(); try local.validate(); try remote.validate()
        if local == remote { return local }
        guard let base else {
            if local == TrackerData() { return remote }
            if remote == TrackerData() { return local }
            throw TrackerError.invalid("This phone and your account both contain records. Choose which version to keep.")
        }
        var result = TrackerData()
        result.rules = try select(base.rules, local.rules, remote.rules)
        result.preferences = try select(base.preferences, local.preferences, remote.preferences)
        result.shifts = try mergeRecords(base: base.shifts, local: local.shifts, remote: remote.shifts)
        let costs = try mergeRecords(base: base.expenses ?? [], local: local.expenses ?? [], remote: remote.expenses ?? [])
        result.expenses = costs.isEmpty && base.expenses == nil && local.expenses == nil && remote.expenses == nil ? nil : costs
        result.claims = try mergeRecords(base: base.claims, local: local.claims, remote: remote.claims)
        try result.validate()
        return result
    }
    private static func select<T: Equatable & Codable>(_ base: T, _ local: T, _ remote: T) throws -> T {
        if local == remote || remote == base { return local }
        if local == base { return remote }
        // Both sides changed it: keep both if they changed different fields (e.g. a payment marked
        // a shift paid on the server while its note was edited here). Only a clash on one field asks.
        if let merged = fieldMerge(base, local, remote) { return merged }
        throw TrackerError.invalid("The same record changed on this phone and another device. Your versions have been kept for review.")
    }
    private static func select<T: Equatable & Codable>(_ base: T?, _ local: T?, _ remote: T?) throws -> T? {
        if local == remote || remote == base { return local }
        if local == base { return remote }
        if let base, let local, let remote, let merged = fieldMerge(base, local, remote) { return merged }
        throw TrackerError.invalid("The same record changed on this phone and another device. Your versions have been kept for review.")
    }

    /// Three-way merge of one record's fields, comparing exact JSON values (numbers as Decimal).
    static func fieldMerge<T: Codable>(_ base: T, _ local: T, _ remote: T) -> T? {
        let encoder = JSONEncoder()
        guard case .object(let a)? = try? JSONDecoder().decode(JSONValue.self, from: encoder.encode(base)),
              case .object(let b)? = try? JSONDecoder().decode(JSONValue.self, from: encoder.encode(local)),
              case .object(let c)? = try? JSONDecoder().decode(JSONValue.self, from: encoder.encode(remote)) else { return nil }
        var result: [String: JSONValue] = [:]
        for key in Set(a.keys).union(b.keys).union(c.keys) {
            let (x, y, z) = (a[key], b[key], c[key])
            let value: JSONValue?
            if y == z || z == x { value = y } else if y == x { value = z } else { return nil }
            if let value { result[key] = value }
        }
        guard let data = try? encoder.encode(JSONValue.object(result)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func mergeRecords<T: Identifiable & Equatable & Codable>(base: [T], local: [T], remote: [T]) throws -> [T] where T.ID == UUID {
        let a = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let b = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let c = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        return try Set(a.keys).union(b.keys).union(c.keys).sorted { $0.uuidString < $1.uuidString }.compactMap { key in
            try select(a[key], b[key], c[key])
        }
    }
}

/// A JSON value that keeps numbers exact, for comparing and merging records field by field.
indirect enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Decimal), string(String), array([JSONValue]), object([String: JSONValue])
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Decimal.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
