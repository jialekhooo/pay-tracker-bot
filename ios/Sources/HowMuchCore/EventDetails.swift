import Foundation

public extension TrackerData {
    /// Event identity is currently its case-insensitive name, shared across currencies.
    /// A nil location preserves existing locations, including legacy mixed-location events.
    mutating func updateEventDetails(event originalName: String, name: String, location: String?) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw TrackerError.invalid("Enter an event name of 1–120 characters.") }
        if let location, location.count > 1000 { throw TrackerError.invalid("Keep the location under 1,000 characters.") }
        let oldKey = originalName.lowercased(), newKey = name.lowercased()
        let matches = shifts.indices.filter { shifts[$0].event.caseInsensitiveCompare(originalName) == .orderedSame }
        guard !matches.isEmpty else { throw TrackerError.invalid("This event was removed. Reopen your latest records.") }
        if oldKey != newKey {
            guard !shifts.contains(where: { $0.event.caseInsensitiveCompare(name) == .orderedSame }),
                  settings.payers[newKey] == nil, settings.eventPayerIDs?[newKey] == nil, settings.eventRates[newKey] == nil else {
                throw TrackerError.invalid("An event or saved event settings already use that name. Choose a different name to keep them separate.")
            }
        }
        var next = self
        for index in matches {
            next.shifts[index].event = name
            if let location { next.shifts[index].location = location }
        }
        if oldKey != newKey, next.preferences != nil {
            var preferences = next.settings
            if let payer = preferences.payers.removeValue(forKey: oldKey) { preferences.payers[newKey] = payer }
            if let id = preferences.eventPayerIDs?.removeValue(forKey: oldKey) { preferences.eventPayerIDs?[newKey] = id }
            if let rate = preferences.eventRates.removeValue(forKey: oldKey) { preferences.eventRates[newKey] = rate }
            next.preferences = preferences
        }
        try next.validate()
        self = next
    }

    /// Update one shift's schedule/pay while applying shared name/location changes atomically.
    mutating func editShift(original: Shift, replacement: Shift) throws {
        guard original.id == replacement.id, let index = shifts.firstIndex(where: { $0.id == original.id }) else {
            throw TrackerError.invalid("This shift was removed. Reopen your latest records.")
        }
        let current = shifts[index]
        let renamed = replacement.event != original.event
        let relocated = replacement.location != original.location
        guard (!renamed || current.event == original.event), (!relocated || current.location == original.location) else {
            throw TrackerError.invalid("This event's details changed elsewhere. Reopen the shift before editing them.")
        }
        var next = self
        var edited = replacement
        if !renamed { edited.event = current.event }
        if !relocated { edited.location = current.location }
        if renamed || relocated {
            try next.updateEventDetails(event: current.event, name: edited.event, location: relocated ? edited.location : nil)
        }
        next.shifts[index] = edited
        try next.validate()
        self = next
    }
}
