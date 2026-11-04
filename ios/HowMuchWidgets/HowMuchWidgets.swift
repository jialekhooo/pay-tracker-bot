import SwiftUI
import WidgetKit
import AppIntents
import HowMuchCore

struct WidgetCurrency: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Currency"
    static var defaultQuery = CurrencyQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}
struct CurrencyQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetCurrency] {
        (SharedWidgetStorage.read()?.currencies ?? []).filter { identifiers.contains($0) }.map { WidgetCurrency(id: $0) }
    }
    func suggestedEntities() async throws -> [WidgetCurrency] { (SharedWidgetStorage.read()?.currencies ?? []).map { WidgetCurrency(id: $0) } }
}
struct HowMuchWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Widget options"
    static var description = IntentDescription("Choose an optional currency filter and the details shown on this widget.")
    @Parameter(title: "Currency (optional)") var currency: WidgetCurrency?
    @Parameter(title: "Show pay", default: false) var showPay: Bool
    @Parameter(title: "Show location", default: true) var showLocation: Bool
}
struct HowMuchEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let configuration: HowMuchWidgetConfiguration
}
struct HowMuchProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HowMuchEntry { HowMuchEntry(date: .now, snapshot: Self.sample(), configuration: HowMuchWidgetConfiguration()) }
    func snapshot(for configuration: HowMuchWidgetConfiguration, in context: Context) async -> HowMuchEntry {
        HowMuchEntry(date: .now, snapshot: context.isPreview ? Self.sample() : SharedWidgetStorage.read(), configuration: configuration)
    }
    func timeline(for configuration: HowMuchWidgetConfiguration, in context: Context) async -> Timeline<HowMuchEntry> {
        let now = Date(), snapshot = SharedWidgetStorage.read()
        let dates = snapshot?.timelineDates(from: now) ?? [now]
        return Timeline(entries: dates.map { HowMuchEntry(date: $0, snapshot: snapshot, configuration: configuration) }, policy: .after(now.addingTimeInterval(3600)))
    }
    static func sample() -> WidgetSnapshot {
        var data = TrackerData()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        if let shift = try? Shift(event: "Weekend roadshow", location: "Suntec City", day: Shift.dayString(tomorrow), startMinute: 9*60, endMinute: 18*60, breakMinutes: 60, rate: 20) { data.shifts = [shift] }
        return WidgetSnapshot(data: data, accountID: "00000000-0000-4000-8000-000000000001")
    }
}
struct WidgetEntryView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.widgetFamily) var family
    let entry: HowMuchEntry
    let kind: HowMuchWidgetKind
    var body: some View {
        HowMuchWidgetContents(snapshot: entry.snapshot, date: entry.date, kind: kind, family: family,
            currency: entry.configuration.currency?.id, showPay: entry.configuration.showPay, showLocation: entry.configuration.showLocation)
            .containerBackground(for: .widget) { Rectangle().fill((colorScheme == .dark ? Color(red: 0.04, green: 0.15, blue: 0.13) : Color(red: 0.92, green: 0.97, blue: 0.95)).gradient) }
    }
}
struct NextShiftWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "HowMuch.NextShift", intent: HowMuchWidgetConfiguration.self, provider: HowMuchProvider()) { WidgetEntryView(entry: $0, kind: .nextShift) }
            .configurationDisplayName("Next Shift").description("Your next shift or the job you’re working now, with a shortcut to its details.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular])
    }
}
struct UpcomingEventsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "HowMuch.UpcomingEvents", intent: HowMuchWidgetConfiguration.self, provider: HowMuchProvider()) { WidgetEntryView(entry: $0, kind: .events) }
            .configurationDisplayName("Upcoming Events").description("See your next events grouped together, with shift counts and dates.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}
struct ThisMonthWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "HowMuch.ThisMonth", intent: HowMuchWidgetConfiguration.self, provider: HowMuchProvider()) { WidgetEntryView(entry: $0, kind: .month) }
            .configurationDisplayName("This Month").description("Scheduled hours or work pay for the month, kept separate by currency.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct WorkCalendarWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "HowMuch.Calendar", intent: HowMuchWidgetConfiguration.self, provider: HowMuchProvider()) { WidgetEntryView(entry: $0, kind: .calendar) }
            .configurationDisplayName("Work Calendar").description("Your month with booked days and upcoming shifts. Tap a date to open your calendar.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}
@main struct HowMuchWidgets: WidgetBundle {
    var body: some Widget { NextShiftWidget(); UpcomingEventsWidget(); ThisMonthWidget(); WorkCalendarWidget() }
}
