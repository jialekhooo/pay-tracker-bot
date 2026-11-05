import SwiftUI
import HowMuchCore

enum Palette {
    static let ink = Color(red: 0.094, green: 0.231, blue: 0.216)
    static let muted = Color(red: 0.392, green: 0.471, blue: 0.451)
    static let teal = Color(red: 0.071, green: 0.42, blue: 0.369)
    static let canvas = Color(red: 0.953, green: 0.965, blue: 0.961)
    static let mint = Color(red: 0.89, green: 0.95, blue: 0.92)
    static let line = Color(red: 0.86, green: 0.90, blue: 0.88)
}

struct AppBackdrop: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: Color(red: 0.80, green: 0.92, blue: 0.87), location: 0),
            .init(color: Color(red: 0.90, green: 0.95, blue: 0.92), location: 0.34),
            .init(color: Palette.canvas, location: 0.65),
            .init(color: Color(red: 0.89, green: 0.94, blue: 0.91), location: 1)
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
                .overlay(shape.stroke(.white.opacity(0.7), lineWidth: 0.7).allowsHitTesting(false))
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 20))
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
                        Text("HOWMUCH").font(.system(size: 10, weight: .bold)).tracking(2.2).opacity(0.65)
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
            Text(title).font(.system(.headline, design: .rounded)).foregroundStyle(Palette.ink)
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
                            .foregroundStyle(selection == value ? (onDark ? Palette.ink : Color.white) : (onDark ? .white : Palette.muted))
                            .background(selection == value ? (onDark ? Color.white : Palette.teal) : (onDark ? .white.opacity(0.12) : .white), in: Capsule()).contentShape(Capsule())
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
                Text(title).font(.headline)
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
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(paid ? Color(red: 0.15, green: 0.42, blue: 0.27) : Palette.teal)
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
                Text(shift.event).font(.system(.headline, design: .rounded)).foregroundStyle(Palette.ink).lineLimit(2)
                Spacer(minLength: 4)
                Text(money(shift.pay, shift.currency)).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink).fixedSize()
            }
            VStack(alignment: .leading, spacing: 7) {
                Label(shift.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " · " + Shift.clock(shift.startMinute) + "–" + Shift.clock(shift.endMinute) + (shift.endMinute <= shift.startMinute ? " (+1 day)" : ""), systemImage: "calendar")
                if !shift.location.isEmpty { Label(shift.location, systemImage: "mappin.and.ellipse").lineLimit(2) }
            }.font(.caption).foregroundStyle(Palette.muted)
            HStack {
                StatusPill(title: shift.state(at: Date()), paid: shift.paid && shift.endDate <= Date())
                Spacer()
                Text(hoursText(shift.hours) + " paid time").font(.caption).foregroundStyle(Palette.muted)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
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

extension View {
    func glassChrome<S: Shape>(in shape: S, tint: Color? = nil) -> some View { modifier(GlassChrome(shape: shape, tint: tint)) }
    func glassAction() -> some View { self.buttonStyle(GlassActionButtonStyle()) }
    func primaryButton() -> some View { self.buttonStyle(PrimaryActionButtonStyle()) }
    func rowAction() -> some View { self.buttonStyle(RowActionButtonStyle()) }
    func iconAction() -> some View { self.buttonStyle(IconActionButtonStyle()) }
    func detailStyle(_ title: String) -> some View {
        self.navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .scrollContentBackground(.hidden).background { AppBackdrop() }.foregroundStyle(Palette.ink)
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
            .glassChrome(in: RoundedRectangle(cornerRadius: 16), tint: Palette.teal)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
private struct RowActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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
