import Foundation
import CryptoKit

public struct SavedPayer: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var bankNames: [String]
    public init(id: UUID = UUID(), name: String, bankNames: [String]) { self.id = id; self.name = name; self.bankNames = bankNames }
    /// Display casing is separate from exact bank-name matching.
    public var displayName: String { name == name.lowercased() ? name.uppercased() : name }
    public static func key(_ value: String) -> String { value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    public static func legacyID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(("howmuch.payer:" + key(value)).utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

public extension AppPreferences {
    /// Stable migration is safe to evaluate on any device before its first save.
    var migratedPayers: AppPreferences {
        var next = self
        var library = savedPayers ?? []
        var assignments = eventPayerIDs ?? [:]
        for (event, bank) in payers.sorted(by: { $0.key < $1.key }) where assignments[event] == nil && !SavedPayer.key(bank).isEmpty {
            let existing = library.first { $0.bankNames.contains { SavedPayer.key($0) == SavedPayer.key(bank) } }
            let payer = existing ?? SavedPayer(id: SavedPayer.legacyID(bank), name: String(bank.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)), bankNames: [bank.trimmingCharacters(in: .whitespacesAndNewlines)])
            if existing == nil { library.append(payer) }
            assignments[event] = payer.id
        }
        if !library.isEmpty || savedPayers != nil { next.savedPayers = library }
        if !assignments.isEmpty || eventPayerIDs != nil { next.eventPayerIDs = assignments }
        return next
    }
    func payer(for event: String) -> SavedPayer? {
        let next = migratedPayers
        guard let id = next.eventPayerIDs?[event.lowercased()] else { return nil }
        return next.savedPayers?.first { $0.id == id }
    }
    mutating func assignPayer(_ id: UUID?, to event: String) {
        self = migratedPayers
        let key = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if eventPayerIDs == nil { eventPayerIDs = [:] }
        eventPayerIDs?[key] = id
        payers[key] = savedPayers?.first { $0.id == id }?.bankNames.first ?? ""
    }
    mutating func savePayer(_ payer: SavedPayer) {
        self = migratedPayers
        var library = savedPayers ?? []; library.removeAll { $0.id == payer.id }; library.append(payer)
        savedPayers = library
        for (event, id) in eventPayerIDs ?? [:] where id == payer.id { payers[event] = payer.bankNames.first ?? "" }
    }
    mutating func removePayer(_ id: UUID) {
        self = migratedPayers
        for (event, assigned) in eventPayerIDs ?? [:] where assigned == id { assignPayer(nil, to: event) }
        savedPayers?.removeAll { $0.id == id }
        if jobTemplates != nil { for index in jobTemplates!.indices where jobTemplates![index].payerID == id { jobTemplates![index].payerID = nil } }
    }
    func validatePayers() throws {
        let library = savedPayers ?? []
        guard library.count <= 2000, Set(library.map(\.id)).count == library.count,
              Set(library.map { SavedPayer.key($0.name) }).count == library.count,
              (eventPayerIDs?.count ?? 0) <= 2000 else { throw TrackerError.invalid("Use unique payer names and keep up to 2,000 saved payers.") }
        var aliases = Set<String>()
        for payer in library {
            guard !SavedPayer.key(payer.name).isEmpty, payer.name.count <= 120, (1...20).contains(payer.bankNames.count) else { throw TrackerError.invalid("Add a company name and 1–20 exact bank payer names.") }
            for bank in payer.bankNames {
                guard !SavedPayer.key(bank).isEmpty, bank.count <= 200, aliases.insert(SavedPayer.key(bank)).inserted else { throw TrackerError.invalid("Each bank payer name must be unique across your saved companies (up to 200 characters).") }
            }
        }
        let ids = Set(library.map(\.id))
        guard (eventPayerIDs ?? [:]).allSatisfy({ !$0.key.isEmpty && $0.key.count <= 120 && ids.contains($0.value) }),
              (jobTemplates ?? []).allSatisfy({ $0.payerID == nil || ids.contains($0.payerID!) }) else { throw TrackerError.invalid("Choose an existing saved payer for this event or template.") }
    }
}
