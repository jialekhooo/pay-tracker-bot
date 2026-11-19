import SwiftUI
import WidgetKit
import HowMuchCore

struct WidgetsSettingsView: View {
    @EnvironmentObject private var store: TrackerStore
    var body: some View { AccountWidgetPreviews().id(store.accountID) }
}

private struct AccountWidgetPreviews: View {
    @EnvironmentObject private var store: TrackerStore
    private var previews: WidgetPreviewPreferences { store.data.settings.widgetPreview ?? WidgetPreviewPreferences() }
    private var showPay: Bool { previews.showPay ?? false }
    private var showLocation: Bool { previews.showLocation ?? true }
    private func binding(_ path: WritableKeyPath<WidgetPreviewPreferences, Bool?>, default value: Bool) -> Binding<Bool> {
        Binding(get: { previews[keyPath: path] ?? value }, set: { new in
            store.updatePreferences { var previews = $0.widgetPreview ?? WidgetPreviewPreferences(); previews[keyPath: path] = new; $0.widgetPreview = previews }
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    Label("Your work, at a glance", systemImage: "rectangle.on.rectangle").font(.appHeadline)
                    Text("Touch and hold your Home Screen, tap Edit → Add Widget, then search HowMuch. Next Shift is also available on your Lock Screen.").font(.subheadline)
                    Text("Touch and hold an installed widget → Edit Widget to choose a currency and whether to show pay or location. Pay is hidden by default.").font(.caption).foregroundStyle(Palette.muted)
                }
                Card {
                    Toggle("Preview pay amounts", isOn: binding(\.showPay, default: false)).accessibilityIdentifier("widgets.previewPay")
                    Toggle("Preview locations", isOn: binding(\.showLocation, default: true)).accessibilityIdentifier("widgets.previewLocation")
                    Text("Preview choices are saved to your account. Each installed widget has its own options, set on that iPhone.").font(.caption).foregroundStyle(Palette.muted)
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
            Text(title).font(.appHeadline)
            HowMuchWidgetContents(snapshot: WidgetSnapshot(data: store.data, accountID: store.accountID), date: .now,
                kind: kind, family: .systemMedium, showPay: showPay, showLocation: showLocation)
                .padding(16).frame(height: height).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.adaptive((0.92, 0.97, 0.95), dark: (0.07, 0.16, 0.14)).gradient, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Palette.line.opacity(0.8)))
                .accessibilityIdentifier("widgets.preview.\(kind.rawValue)")
        }
    }
}
