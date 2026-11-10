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
// MARK: - Penny

struct PennyEntry: TimelineEntry {
    let date: Date
    let info: PennyWidgetInfo?
    let next: WidgetShift?
    let accountID: String?
}
struct PennyProvider: TimelineProvider {
    func placeholder(in context: Context) -> PennyEntry { Self.sample }
    func getSnapshot(in context: Context, completion: @escaping (PennyEntry) -> Void) {
        completion(context.isPreview && PennyWidgetFile.read() == nil ? Self.sample : entry(at: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PennyEntry>) -> Void) {
        let now = Date()
        // Refresh after the next shift starts, or hourly; the app also reloads it whenever Penny changes.
        var later = now.addingTimeInterval(3600)
        if let start = SharedWidgetStorage.read()?.upcoming(at: now).first?.start, start > now { later = min(later, start.addingTimeInterval(60)) }
        completion(Timeline(entries: [entry(at: now)], policy: .after(later)))
    }
    private func entry(at date: Date) -> PennyEntry {
        let snapshot = SharedWidgetStorage.read().flatMap { $0.isCurrent(at: date) ? $0 : nil }
        let info = PennyWidgetFile.read()
        return PennyEntry(date: date, info: info, next: snapshot?.upcoming(at: date).first, accountID: info?.accountID ?? snapshot?.accountID)
    }
    static let sample = PennyEntry(date: .now, info: PennyWidgetInfo(accountID: "", name: "Penny", stage: "Hatchling", level: 3, mood: "Happy", streakWeeks: 4, hatched: true), next: nil, accountID: nil)
}

struct PennyWidgetView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetFamily) private var family
    let entry: PennyEntry
    private var jade: Color { colorScheme == .dark ? Color(red: 0.53, green: 0.9, blue: 0.76) : Color(red: 0.04, green: 0.39, blue: 0.34) }
    private var picture: Image? {
        guard let url = PennyWidgetFile.imageURL(dark: colorScheme == .dark), let image = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: image)
    }
    var body: some View {
        Group {
            if let info = entry.info {
                if family == .systemMedium { medium(info) } else { small(info) }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image("BrandLogo").resizable().scaledToFit().frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 9))
                    Text("Open HowMuch to meet Penny").font(.headline)
                    Text("Your pay pet lives here once you sign in.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .widgetURL(entry.accountID.flatMap { UUID(uuidString: $0) != nil ? WidgetLink.pet.url(accountID: $0) : nil } ?? URL(string: "howmuch://widget/open")!)
    }
    private func streak(_ weeks: Int) -> some View {
        Label(weeks == 1 ? "1 wk" : "\(weeks) wk", systemImage: "flame.fill").font(.caption2.weight(.bold)).foregroundStyle(.orange)
    }
    private func subtitle(_ info: PennyWidgetInfo) -> String { info.hatched ? "\(info.stage) · Lv \(info.level)" : "Egg · ready to hatch" }
    private func small(_ info: PennyWidgetInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                if info.streakWeeks > 0 {
                    streak(info.streakWeeks).padding(.horizontal, 7).padding(.vertical, 4).background(.white.opacity(0.88), in: Capsule())
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name).font(.system(.subheadline, design: .rounded, weight: .bold)).lineLimit(1)
                Text(subtitle(info)).font(.caption2).lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(info.name), \(subtitle(info)), feeling \(info.mood.lowercased()), \(info.streakWeeks)-week streak")
    }
    private func medium(_ info: PennyWidgetInfo) -> some View {
        HStack(spacing: 14) {
            (picture ?? Image("BrandLogo")).resizable().scaledToFill().frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(info.name).font(.system(.title3, design: .rounded, weight: .bold)).lineLimit(1)
                Text(subtitle(info)).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if info.streakWeeks > 0 { streak(info.streakWeeks) }
                    Text("Feeling \(info.mood.lowercased())").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let next = entry.next {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(next.start <= entry.date ? "WORKING NOW" : "NEXT SHIFT").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.8).foregroundStyle(jade)
                        Text(next.event).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(next.start, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.caption2).foregroundStyle(.secondary)
                    }.privacySensitive()
                } else {
                    Text("No shifts booked. Add one to keep the streak going.").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct PennyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HowMuch.Penny", provider: PennyProvider()) { entry in
            PennyWidgetBackground(entry: entry)
        }
        .configurationDisplayName("Penny").description("Your pay pet on the Home Screen: her level, mood and streak, plus your next shift.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
/// The small size shows Penny's room edge to edge; the medium one sits on HowMuch's usual background.
private struct PennyWidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetFamily) private var family
    let entry: PennyEntry
    var body: some View {
        PennyWidgetView(entry: entry)
            .padding(family == .systemSmall && entry.info != nil ? 8 : 16)
            .containerBackground(for: .widget) {
                if family == .systemSmall, entry.info != nil, let url = PennyWidgetFile.imageURL(dark: colorScheme == .dark), let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill((colorScheme == .dark ? Color(red: 0.04, green: 0.15, blue: 0.13) : Color(red: 0.92, green: 0.97, blue: 0.95)).gradient)
                }
            }
    }
}

@main struct HowMuchWidgets: WidgetBundle {
    var body: some Widget {
        NextShiftWidget(); UpcomingEventsWidget(); ThisMonthWidget(); WorkCalendarWidget(); LiveShiftWidget(); PennyWidget()
        if #available(iOSApplicationExtension 18.0, *) { AddJobControl() }
    }
}
