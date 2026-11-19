import Foundation

public struct JobNotificationOptions: Codable, Equatable {
    public var enabled = true
    public var upcoming = true
    public var starts = true
    public var ends = true
    public var paymentDue = true
    public var leadMinutes = 30
    // Optional for decoding existing accounts and archives without changing their reminder.
    public var startLeadMinutes: [Int]?
    public var startReminderMinutes: [Int] {
        get { Array(Set(startLeadMinutes ?? [leadMinutes])).sorted(by: >) }
        set { startLeadMinutes = Array(Set(newValue)).sorted(by: >); leadMinutes = startLeadMinutes?.first ?? 30 }
    }
    public var dayBeforeMinute = 20 * 60
    public var dueMinute = 9 * 60
    public var showDetails = false
    public init() {}
    public func validate() throws {
        guard (0...1440).contains(leadMinutes), (startLeadMinutes?.count ?? 1) <= 12, startReminderMinutes.allSatisfy({ (0...1440).contains($0) }), (!starts || !startReminderMinutes.isEmpty), (0..<1440).contains(dayBeforeMinute), (0..<1440).contains(dueMinute) else {
            throw TrackerError.invalid("Choose valid job reminder times.")
        }
    }
}

public struct ScheduledJobReminder: Identifiable, Equatable {
    public let id: String
    public let kind: String
    public let fireDate: Date
    public let title: String
    public let body: String
    public let shiftID: UUID
}

public enum JobReminderPlan {
    public static func make(data: TrackerData, accountID: String, now: Date = Date()) -> [ScheduledJobReminder] {
        let options = data.settings.jobNotifications
        guard options.enabled else { return [] }
        let calendar = TrackerCalendar.calendar
        var result: [ScheduledJobReminder] = []
        func add(_ kind: String, key: String, fire: Date, shift: Shift, title: String, details: String) {
            guard fire > now else { return }
            result.append(ScheduledJobReminder(id: "howmuch.\(accountID).\(kind).\(key)", kind: kind, fireDate: fire, title: title,
                body: details, shiftID: shift.id))
        }
        for shift in data.shifts {
            if options.starts && shift.startDate > now {
                for minutes in options.startReminderMinutes {
                    let lead = shift.startDate.addingTimeInterval(-Double(minutes) * 60)
                    // Existing single-time accounts retain their original at-start fallback.
                    let fire = options.startLeadMinutes == nil && lead <= now ? shift.startDate : lead
                    add("start", key: "\(shift.id.uuidString).\(minutes)", fire: fire, shift: shift,
                    title: "Shift starts at \(Shift.clock(shift.startMinute))", details: options.showDetails ? "\(shift.event) · \(Shift.clock(shift.startMinute))–\(Shift.clock(shift.endMinute))\(shift.endMinute <= shift.startMinute ? " (+1 day)" : "")\(shift.location.isEmpty ? "" : " · " + shift.location)" : "Open HowMuch for your location and job details.")
                }
            }
            if options.ends {
                add("end", key: shift.id.uuidString, fire: shift.endDate, shift: shift, title: "Shift ended at \(Shift.clock(shift.endMinute))", details: options.showDetails ? "\(shift.event) · Review your hours and add any claims." : "Review your hours and add any claims in HowMuch.")
            }
        }
        if options.upcoming {
            let future = Dictionary(grouping: data.shifts.filter { $0.startDate > now }, by: \.day)
            for day in future.keys.sorted() {
                guard let shift = future[day]?.sorted(by: { $0.startMinute < $1.startMinute }).first,
                      let date = TrackerCalendar.localDate(day), let previous = calendar.date(byAdding: .day, value: -1, to: date),
                      let fire = calendar.date(bySettingHour: options.dayBeforeMinute / 60, minute: options.dayBeforeMinute % 60, second: 0, of: previous) else { continue }
                add("upcoming", key: day, fire: fire, shift: shift, title: "Tomorrow: \(future[day]!.count) \(future[day]!.count == 1 ? "shift" : "shifts")", details: options.showDetails ? "First: \(shift.event) at \(Shift.clock(shift.startMinute))\(shift.location.isEmpty ? "" : " · " + shift.location)" : "First shift at \(Shift.clock(shift.startMinute)). Open HowMuch to plan your day.")
            }
        }
        if options.paymentDue {
            let unpaid = data.shifts.filter { !$0.paid && $0.paymentDue != nil }
            let groups = Dictionary(grouping: unpaid) { "\($0.event.lowercased())|\($0.currency)|\($0.paymentDue!)" }
            for key in groups.keys.sorted() {
                guard let shift = groups[key]?.first, let due = shift.paymentDue, let date = TrackerCalendar.localDate(due),
                      let fire = calendar.date(bySettingHour: options.dueMinute / 60, minute: options.dueMinute % 60, second: 0, of: date) else { continue }
                // An event can have many shifts; send one payment reminder for its due date.
                let stableKey = Data(key.utf8).base64EncodedString()
                add("payment_due", key: stableKey, fire: fire, shift: shift, title: "Payment due today", details: options.showDetails ? "\(shift.event) · \(groups[key]!.count) unpaid \(groups[key]!.count == 1 ? "shift" : "shifts"). Check payment, then mark paid." : "Check your unpaid work in HowMuch and mark payments received.")
            }
        }
        return result.sorted { $0.fireDate == $1.fireDate ? $0.id < $1.id : $0.fireDate < $1.fireDate }
    }
}

public enum TransitReminderPlan {
    public static func make(shift: Shift, options: TravelReminderOptions, accountID: String, leaveAt: Date, showDetails: Bool, now: Date = Date()) -> [ScheduledJobReminder] {
        guard options.enabled, options.transit == true, shift.startDate > now else { return [] }
        let clock = leaveAt.formatted(date: .omitted, time: .shortened)
        return [("travel_prepare", leaveAt.addingTimeInterval(-Double(options.prepareMinutes) * 60), "Get ready for public transport"),
                ("travel_leave", leaveAt, "Time to leave for public transport")].compactMap { kind, fire, title in
            guard fire > now, fire < shift.startDate, kind != "travel_prepare" || options.prepareMinutes > 0 else { return nil }
            return ScheduledJobReminder(id: "howmuch.\(accountID).transit.\(shift.id.uuidString).\(kind)", kind: kind, fireDate: fire, title: title + " · " + clock,
                body: (showDetails ? shift.event + " · " : "") + "Apple Maps estimate from your last refresh. Check the current bus/MRT service before leaving.", shiftID: shift.id)
        }
    }
}
