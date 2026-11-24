import Foundation

/// What a HowMuch account without Pro can keep. The server applies the same rule (howmuch_api/store.py).
public enum FreePlan {
    /// Events (jobs, which group their shifts) a free account can keep. More shifts in an existing event are always free.
    public static let eventLimit = 5

    public static let limitMessage = "Free accounts can keep up to \(eventLimit) events. Add this to one of your events, delete an old event, or get HowMuch Pro for unlimited events."

    /// Events are told apart by name, ignoring case and surrounding spaces (as everywhere else in HowMuch).
    public static func events(in data: TrackerData) -> Set<String> {
        Set(data.shifts.map { $0.event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    /// True when `after` has more events than a free account may add. An account already above the limit
    /// (for example, after Pro ends) keeps what it has but can't add more events.
    public static func exceedsLimit(before: TrackerData, after: TrackerData) -> Bool {
        let count = events(in: after).count
        return count > eventLimit && count > events(in: before).count
    }

    /// True when saving a shift with this event name would start a new event the free plan can't hold.
    public static func needsPro(forEvent name: String, in data: TrackerData) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let current = events(in: data)
        return !key.isEmpty && !current.contains(key) && current.count >= eventLimit
    }
}
