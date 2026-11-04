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
    private static func select<T: Equatable>(_ base: T, _ local: T, _ remote: T) throws -> T {
        if local == remote || remote == base { return local }
        if local == base { return remote }
        throw TrackerError.invalid("The same record changed on this phone and another device. Your versions have been kept for review.")
    }
    private static func mergeRecords<T: Identifiable & Equatable>(base: [T], local: [T], remote: [T]) throws -> [T] where T.ID == UUID {
        let a = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let b = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let c = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        return try Set(a.keys).union(b.keys).union(c.keys).sorted { $0.uuidString < $1.uuidString }.compactMap { key in
            try select(a[key], b[key], c[key])
        }
    }
}
