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
    /// Nested settings merge the same way, so two devices changing different parts of Penny or the
    /// notification options don't clash. Lists of plain values (finish times, blocked days) combine,
    /// and lists of records with an "id" merge record by record.
    static func fieldMerge<T: Codable>(_ base: T, _ local: T, _ remote: T) -> T? {
        let encoder = JSONEncoder()
        guard let a = try? JSONDecoder().decode(JSONValue.self, from: encoder.encode(base)),
              let b = try? JSONDecoder().decode(JSONValue.self, from: encoder.encode(local)),
              let c = try? JSONDecoder().decode(JSONValue.self, from: encoder.encode(remote)),
              case .object = b, case .some(.some(let merged)) = mergeValue(a, b, c),
              let data = try? encoder.encode(merged) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// `.some(value)` is the merged value (`.some(nil)`: the field is absent); `nil` is a real clash.
    static func mergeValue(_ x: JSONValue?, _ y: JSONValue?, _ z: JSONValue?) -> JSONValue?? {
        if y == z || z == x { return .some(y) }
        if y == x { return .some(z) }
        switch (y, z) {
        case (.object(let local)?, .object(let remote)?):
            let base: [String: JSONValue]
            switch x { case .object(let value)?: base = value; case nil, .null?: base = [:]; default: return nil }
            var result: [String: JSONValue] = [:]
            for key in Set(base.keys).union(local.keys).union(remote.keys) {
                guard case .some(let value) = mergeValue(base[key], local[key], remote[key]) else { return nil }
                if let value { result[key] = value }
            }
            return .some(.object(result))
        case (.array(let local)?, .array(let remote)?):
            let base: [JSONValue]
            switch x { case .array(let value)?: base = value; case nil, .null?: base = []; default: return nil }
            return mergeList(base, local, remote).map { .some(.array($0)) }
        default:
            return nil
        }
    }

    private static func recordID(_ value: JSONValue) -> JSONValue? {
        if case .object(let fields) = value, let id = fields["id"] { return id }
        return nil
    }

    private static func mergeList(_ base: [JSONValue], _ local: [JSONValue], _ remote: [JSONValue]) -> [JSONValue]? {
        let all = base + local + remote
        if all.allSatisfy({ recordID($0) != nil }) {
            // Records: merge each by id, keeping this phone's order and adding the other device's new ones.
            func index(_ list: [JSONValue]) -> [JSONValue: JSONValue] {
                var result: [JSONValue: JSONValue] = [:]
                for item in list { if let id = recordID(item) { result[id] = item } }
                return result
            }
            let (a, b, c) = (index(base), index(local), index(remote))
            var order: [JSONValue] = []
            for item in local + remote { if let id = recordID(item), !order.contains(id) { order.append(id) } }
            var result: [JSONValue] = []
            for id in order {
                guard case .some(let value) = mergeValue(a[id], b[id], c[id]) else { return nil }
                if let value { result.append(value) }
            }
            return result
        }
        guard !all.contains(where: { if case .object = $0 { return true }; if case .array = $0 { return true }; return false }) else { return nil }
        // Plain values: keep what either side added, drop what either side removed.
        let removed = Set(base).subtracting(local).union(Set(base).subtracting(remote))
        var result: [JSONValue] = []
        for item in local + remote where !removed.contains(item) && !result.contains(item) { result.append(item) }
        return result
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
indirect enum JSONValue: Codable, Hashable {
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
