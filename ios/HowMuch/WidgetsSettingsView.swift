import SwiftUI
import WidgetKit
import HowMuchCore

struct WidgetsSettingsView: View {
    @EnvironmentObject private var store: TrackerStore
    var body: some View { AccountWidgetPreviews(accountID: store.accountID).id(store.accountID) }
}

private struct AccountWidgetPreviews: View {
    @EnvironmentObject private var store: TrackerStore
    @AppStorage private var showPay: Bool
    @AppStorage private var showLocation: Bool
    init(accountID: String) {
        let prefix = "howmuch.widgetPreviews." + accountID.lowercased()
        _showPay = AppStorage(wrappedValue: false, prefix + ".showPay")
        _showLocation = AppStorage(wrappedValue: true, prefix + ".showLocation")
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    Label("Your work, at a glance", systemImage: "rectangle.on.rectangle").font(.headline)
                    Text("Touch and hold your Home Screen, tap Edit → Add Widget, then search HowMuch. Next Shift is also available on your Lock Screen.").font(.subheadline)
                    Text("Touch and hold an installed widget → Edit Widget to choose a currency and whether to show pay or location. Pay is hidden by default.").font(.caption).foregroundStyle(Palette.muted)
                }
                Card {
                    Toggle("Preview pay amounts", isOn: $showPay).accessibilityIdentifier("widgets.previewPay")
                    Toggle("Preview locations", isOn: $showLocation).accessibilityIdentifier("widgets.previewLocation")
                    Text("Preview choices save automatically for this account on this iPhone. Each installed widget has its own options.").font(.caption).foregroundStyle(Palette.muted)
                }
                preview("Work Calendar", .calendar, height: 172)
                preview("Next Shift", .nextShift, height: 158)
                preview("Upcoming Events", .events, height: 165)
                preview("This Month", .month, height: 158)
                Card {
                    Text(store.widgetMessage).font(.caption).accessibilityIdentifier("widgets.status")
                    Button("Refresh widget data", systemImage: "arrow.clockwise") { store.refreshWidgets() }.rowAction().accessibilityIdentifier("widgets.refresh")
                    Text("Widgets use the last data saved on this iPhone. iOS controls refresh timing. Open HowMuch after edits on another device to sync. Signing out clears shared widget data; iOS may take time to replace an already displayed snapshot.").font(.caption).foregroundStyle(Palette.muted)
                    Text("Only shift details and work-pay summaries are shared with the widget extension. Mail, account tokens, profile photos and claim notes are excluded.").font(.caption).foregroundStyle(Palette.muted)
                }
            }.padding(20)
        }.detailStyle("Widgets")
    }
    private func preview(_ title: String, _ kind: HowMuchWidgetKind, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HowMuchWidgetContents(snapshot: WidgetSnapshot(data: store.data, accountID: store.accountID), date: .now,
                kind: kind, family: .systemMedium, showPay: showPay, showLocation: showLocation)
                .padding(16).frame(height: height).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.92, green: 0.97, blue: 0.95).gradient, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.8)))
                .accessibilityIdentifier("widgets.preview.\(kind.rawValue)")
        }
    }
}
