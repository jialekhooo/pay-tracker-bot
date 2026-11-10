import SwiftUI
import HowMuchCore

/// One type scale for the whole app. Headings are rounded; amounts use fixed sizes so cards line up.
extension Font {
    /// Page and sheet titles inside the content.
    static let appTitle = Font.system(.title2, design: .rounded, weight: .bold)
    /// Card and row titles.
    static let appHeadline = Font.system(.headline, design: .rounded)
    /// The big line at the top of a card (one step under a page title).
    static let cardTitle = Font.system(.title3, design: .rounded, weight: .bold)
    /// Everyday text, rows and controls: the same size on cards and in forms.
    static let appBody = Font.subheadline
    /// Disclosure chevrons on rows and cards.
    static let chevron = Font.caption2.weight(.semibold)
    /// Icons in the 32-point tiles beside settings rows.
    static let rowIcon = Font.system(size: 15, weight: .medium)
}

/// The app's colors, each with a Dark Mode value. Light values are the original design.
enum Palette {
    /// Main text.
    static let ink = adaptive((0.094, 0.231, 0.216), dark: (0.90, 0.96, 0.93))
    /// Secondary text.
    static let muted = adaptive((0.392, 0.471, 0.451), dark: (0.62, 0.71, 0.68))
    /// Teal text, icons and outlines. Brighter in Dark Mode so it reads on dark backgrounds.
    static let teal = adaptive((0.071, 0.42, 0.369), dark: (0.45, 0.85, 0.71))
    /// Teal fills behind white text (buttons, chips, selected days). Stays deep in Dark Mode.
    static let accent = adaptive((0.071, 0.42, 0.369), dark: (0.11, 0.50, 0.43))
    static let canvas = adaptive((0.953, 0.965, 0.961), dark: (0.035, 0.075, 0.068))
    /// Light tiles behind icons and chips.
    static let mint = adaptive((0.89, 0.95, 0.92), dark: (0.10, 0.21, 0.18))
    static let line = adaptive((0.86, 0.90, 0.88), dark: (0.18, 0.27, 0.25))
    /// Cards and grouped rows.
    static let surface = adaptive((1, 1, 1), dark: (0.075, 0.135, 0.125), lightAlpha: 0.88)
    /// Money waiting to be paid.
    static let warning = adaptive((0.8, 0.42, 0.12), dark: (0.98, 0.62, 0.32))
    /// Paid.
    static let success = adaptive((0.15, 0.42, 0.27), dark: (0.45, 0.85, 0.55))

    static func adaptive(_ light: (Double, Double, Double), dark: (Double, Double, Double), lightAlpha: Double = 1) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1)
                : UIColor(red: light.0, green: light.1, blue: light.2, alpha: lightAlpha)
        })
    }
}

/// Which look the app uses: the iPhone's setting, or always light or dark. Settings → Appearance.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appearance"
    var id: String { rawValue }
    var title: String { switch self { case .system: "Match iPhone"; case .light: "Light"; case .dark: "Dark" } }
    var scheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    var style: UIUserInterfaceStyle { switch self { case .system: .unspecified; case .light: .light; case .dark: .dark } }
    static var current: AppAppearance { AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
}

struct AppBackdrop: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: Palette.adaptive((0.80, 0.92, 0.87), dark: (0.04, 0.20, 0.17)), location: 0),
            .init(color: Palette.adaptive((0.90, 0.95, 0.92), dark: (0.04, 0.12, 0.11)), location: 0.34),
            .init(color: Palette.canvas, location: 0.65),
            .init(color: Palette.adaptive((0.89, 0.94, 0.91), dark: (0.03, 0.09, 0.08)), location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        .ignoresSafeArea().allowsHitTesting(false)
    }
}

// Reserve Liquid Glass for navigation and controls, keeping financial content readable.
private struct GlassChrome<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(tint ?? Palette.canvas, in: shape)
                .overlay(shape.stroke(Palette.line, lineWidth: 1).allowsHitTesting(false))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint ?? .clear).interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .background(tint ?? .clear, in: shape)
                .overlay(shape.stroke(Palette.adaptive((1, 1, 1), dark: (0.3, 0.4, 0.37)).opacity(0.7), lineWidth: 0.7).allowsHitTesting(false))
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .font(.appBody)
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line.opacity(0.7), lineWidth: 0.6).allowsHitTesting(false))
    }
}

struct ScreenShell<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    @EnvironmentObject private var store: TrackerStore
    @State private var search = false
    var body: some View {
        // The header scrolls away with the page so content gets the whole screen.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HOWMUCH").font(.caption2.weight(.bold)).tracking(2.2).opacity(0.65)
                        Text(title).font(.system(.title, design: .rounded, weight: .bold))
                        Text(subtitle).font(.caption).opacity(0.78)
                    }
                    Spacer(minLength: 10)
                    Button { search = true } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44).contentShape(Rectangle())
                            .glassChrome(in: Circle())
                    }.accessibilityLabel("Search shifts")
                    NavigationLink { ProfileSettingsView() } label: { ProfileAvatar(size: 38).frame(width: 46, height: 46).contentShape(Circle()).glassChrome(in: Circle()) }
                        .accessibilityLabel("Profile settings")
                }.foregroundStyle(Palette.ink).padding(.top, 10)
                content
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }.scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $search) { NavigationStack { ShiftsView().toolbar { Button("Done") { search = false } } } }
    }
}

struct ProfileAvatar: View {
    @EnvironmentObject private var store: TrackerStore
    var size: CGFloat = 48
    var body: some View {
        Group {
            if let data = store.data.settings.avatar, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill().accessibilityLabel("Profile photo")
            } else {
                Text(String(store.data.settings.displayName.first ?? "H")).font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(Palette.ink).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.mint)
            }
        }.frame(width: size, height: size).clipShape(Circle())
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String = ""
    var body: some View {
        HStack {
            Text(title).font(.appHeadline).foregroundStyle(Palette.ink)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(Palette.muted)
        }.padding(.top, 4)
    }
}

struct PillPicker: View {
    let values: [String]
    @Binding var selection: String
    var onDark = false
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    Button { selection = value } label: {
                        Text(value).font(.system(.caption, design: .rounded, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 11).frame(minHeight: 44)
                            .foregroundStyle(selection == value ? (onDark ? Color(red: 0.094, green: 0.231, blue: 0.216) : Color.white) : (onDark ? .white : Palette.muted))
                            .background(selection == value ? (onDark ? Color.white : Palette.accent) : (onDark ? .white.opacity(0.12) : Palette.surface), in: Capsule()).contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }
        }.scrollIndicators(.hidden)
            // Pills scroll out to the screen edge instead of being cut off at the card margin.
            .scrollClipDisabled()
    }
}

struct EmptyCard: View {
    var title = "A little breathing room"
    var message = "No shifts booked. Add one whenever you’re ready."
    var symbol = "calendar"
    var body: some View {
        Card {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Palette.teal).padding(15).background(Palette.mint, in: Circle())
                Text(title).font(.appHeadline)
                Text(message).font(.subheadline).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.vertical, 18)
        }
    }
}

struct StatusPill: View {
    let title: String
    var paid = false
    var body: some View {
        Label(title, systemImage: paid ? "checkmark.circle.fill" : title == "Working now" ? "clock.fill" : "circle.fill")
            .font(.caption2.weight(.semibold)).foregroundStyle(paid ? Palette.success : Palette.teal)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((paid ? Color.green : Palette.teal).opacity(0.08), in: Capsule())
    }
}

struct ShiftRow: View {
    @EnvironmentObject private var store: TrackerStore
    let shift: Shift
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(shift.event).font(.appHeadline).foregroundStyle(Palette.ink).lineLimit(2)
                Spacer(minLength: 4)
                Text(money(shift.total, shift.currency)).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink).fixedSize()
            }
            VStack(alignment: .leading, spacing: 7) {
                Label(shift.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " · " + Shift.clock(shift.startMinute) + "–" + Shift.clock(shift.endMinute) + (shift.endMinute <= shift.startMinute ? " (+1 day)" : ""), systemImage: "calendar")
                if !shift.location.isEmpty { Label(shift.location, systemImage: "mappin.and.ellipse").lineLimit(2) }
            }.font(.caption).foregroundStyle(Palette.muted)
            HStack {
                StatusPill(title: shift.state(at: Date()), paid: shift.paid && shift.endDate <= Date())
                Spacer()
                Text(hoursText(shift.hours) + " paid time").font(.caption).foregroundStyle(Palette.muted)
                Image(systemName: "chevron.right").font(.chevron).foregroundStyle(Palette.muted)
            }
            if store.data.shifts.contains(where: { shift.overlaps($0) }) {
                Label("Overlapping shift", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2).contentShape(Rectangle())
    }
}

struct ShiftCards: View {
    let shifts: [Shift]
    var body: some View {
        VStack(spacing: 12) {
            ForEach(shifts) { shift in
                NavigationLink { ShiftDetailView(shiftID: shift.id) } label: { Card { ShiftRow(shift: shift) } }.buttonStyle(.plain)
            }
        }
    }
}

struct PeriodNavigator: View {
    let label: String
    var dark = false
    let previous: () -> Void
    let next: () -> Void
    var body: some View {
        HStack {
            Button(action: previous) { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Previous period")
            Spacer()
            Text(label).font(.system(.subheadline, design: .rounded, weight: .semibold))
            Spacer()
            Button(action: next) { Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Next period")
        }.foregroundStyle(dark ? .white : Palette.ink)
    }
}

private struct InAppFormKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True inside a settings-style Form, where rows set their own height.
    var inAppForm: Bool { get { self[InAppFormKey.self] } set { self[InAppFormKey.self] = newValue } }
}

/// A Form section title styled like `SectionHeading`, so form pages and card pages match.
struct FormHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title).font(.appHeadline).foregroundStyle(Palette.ink).textCase(nil) }
}

extension Section where Parent == FormHeader, Footer == EmptyView, Content: View {
    /// `Section(styled: "Title") { … }`: a section with the app's heading style.
    init(styled title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { FormHeader(title) })
    }
}

/// The app's settings-style form: compact sections, styled headers and rows that size themselves.
struct AppForm<Content: View>: View {
    @ViewBuilder var content: Content
    // Rows use the app's card colour (white, or dark jade in Dark Mode) instead of the system's grouped grey.
    var body: some View { Form { content.listRowBackground(Palette.surface) }.appForm() }
}

extension View {
    /// Settings-style forms: compact section spacing and rows that size themselves.
    func appForm() -> some View { self.environment(\.inAppForm, true).listSectionSpacing(.compact) }
    /// A Form footer note: caption size and muted, matching notes on card pages.
    func formFootnote() -> some View { self.font(.caption).foregroundStyle(Palette.muted) }
    func glassChrome<S: Shape>(in shape: S, tint: Color? = nil) -> some View { modifier(GlassChrome(shape: shape, tint: tint)) }
    func glassAction() -> some View { self.buttonStyle(GlassActionButtonStyle()) }
    func primaryButton() -> some View { self.buttonStyle(PrimaryActionButtonStyle()) }
    func rowAction() -> some View { self.buttonStyle(RowActionButtonStyle()) }
    func iconAction() -> some View { self.buttonStyle(IconActionButtonStyle()) }
    func detailStyle(_ title: String) -> some View {
        self.navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .scrollContentBackground(.hidden).background { AppBackdrop() }.foregroundStyle(Palette.ink)
            // Forms and cards share one text size and a compact row height, so no page looks oversized.
            .font(.appBody)
            .environment(\.defaultMinListRowHeight, 44)
    }
}

// Layout belongs inside the Button label. Styling the outside of a Button can
// paint a full-width surface while leaving only its text responsive to taps.
private struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(.white).padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            // Teal-tinted Liquid Glass, like the + button, so the main action keeps its emphasis without a flat slab.
            .glassChrome(in: RoundedRectangle(cornerRadius: 16), tint: Palette.accent)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
private struct RowActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.inAppForm) private var inForm
    func makeBody(configuration: Configuration) -> some View {
        // Same type as the app's other buttons, so text actions don't look bigger or lighter than boxed ones.
        configuration.label.font(.system(.subheadline, design: .rounded, weight: .semibold))
            // Form rows are already at least 44 points tall; adding 44 more left big gaps between actions.
            .frame(maxWidth: .infinity, minHeight: inForm ? nil : 44, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(configuration.role == .destructive ? Color.red : Palette.teal)
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
    }
}
private struct IconActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct GlassActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(configuration.role == .destructive ? Color.red : Palette.teal)
            .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .glassChrome(in: RoundedRectangle(cornerRadius: 16))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

/// A fixed design size that still follows the iPhone's text size setting, up to `limit` times larger.
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    private let size: CGFloat, weight: Font.Weight, design: Font.Design, limit: CGFloat
    init(size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight, design: Font.Design, limit: CGFloat) {
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.size = size; self.weight = weight; self.design = design; self.limit = limit
    }
    func body(content: Content) -> some View { content.font(.system(size: min(scaled, size * limit), weight: weight, design: design)) }
}

extension View {
    func scaledFont(_ size: CGFloat, relativeTo style: Font.TextStyle = .body, weight: Font.Weight = .regular, design: Font.Design = .default, limit: CGFloat = 2) -> some View {
        modifier(ScaledFont(size: size, relativeTo: style, weight: weight, design: design, limit: limit))
    }
    /// Money stays on one line: it grows with the text size, then shrinks to fit rather than wrapping mid-number.
    func heroAmountFont() -> some View { scaledFont(40, relativeTo: .largeTitle, weight: .bold, design: .rounded, limit: 1.6).lineLimit(1).minimumScaleFactor(0.5) }
    func amountFont() -> some View { scaledFont(34, relativeTo: .largeTitle, weight: .bold, design: .rounded, limit: 1.6).lineLimit(1).minimumScaleFactor(0.5) }
    func amountFieldFont() -> some View { scaledFont(34, relativeTo: .largeTitle, weight: .semibold, design: .rounded, limit: 1.6).minimumScaleFactor(0.5) }
}
