import SwiftUI

/// iOS doesn't let apps create Shortcuts automations themselves, so this is the next best thing
/// (built the same way as SmartSpend's): one page per step with a drawing of the iOS 27 Shortcuts
/// screen and exactly what to tap, remembered progress, and a live check that turns green once
/// the automation runs.
struct BankSetupStep {
    enum Action { case openShortcuts }
    let instruction: LocalizedStringKey
    let detail: LocalizedStringKey?
    let mock: BankMockScreen
    let action: Action?
    init(_ instruction: LocalizedStringKey, detail: LocalizedStringKey? = nil, mock: BankMockScreen, action: Action? = nil) {
        self.instruction = instruction; self.detail = detail; self.mock = mock; self.action = action
    }

    static let bankApp = "DBS digibank"

    /// The iOS 27 flow, checked step by step in the Shortcuts app.
    static let all: [BankSetupStep] = [
        BankSetupStep("Open Shortcuts and tap 'Automation'", detail: "It's in the Library list. Shortcuts comes with every iPhone.",
                      mock: .library, action: .openShortcuts),
        BankSetupStep("Tap + at the bottom", mock: .noAutomations),
        BankSetupStep("Tap 'Edit'", detail: "If you see 'Describe a Shortcut', tap Edit to build it yourself. If not, go to the next step.",
                      mock: .describe),
        BankSetupStep("Tap the 'Automation' button", detail: "It sits above the list of actions at the bottom.", mock: .actionSheet),
        BankSetupStep("Search 'Notification' and tap it", mock: .triggerSearch),
        BankSetupStep("Tap 'App'", detail: "This is where you choose which app HowMuch listens to.", mock: .trigger(app: nil, filter: false, focus: .app)),
        BankSetupStep("Search for your bank app and tap it", detail: "For example DBS digibank, OCBC, UOB TMRW or Trust. Tap + afterwards to add more banks. No filter is needed: HowMuch only reads alerts about money coming in.",
                      mock: .appPicker),
        BankSetupStep("Search 'HowMuch' and tap 'Record pay received'", detail: "Use the search bar at the bottom.", mock: .actionSearch),
        BankSetupStep("Pass it the blue 'Notification'",
                      detail: "Tap the grey Notification field, tap Select Variable, then tap the blue Notification.", mock: .variable),
        BankSetupStep("Tap the back arrow to save, and you're all done!", detail: "Your automation is saved and switched on.", mock: .saved),
    ]
}

enum BankMockFocus: Equatable { case none, app, filter }

enum BankMockScreen {
    case library, noAutomations, describe, actionSheet, triggerSearch
    case trigger(app: String?, filter: Bool, focus: BankMockFocus)
    case appPicker, actionSearch, variable, saved
}

/// The last few times the automation ran, so setup can confirm it works. Kept short and on this iPhone.
enum PayInLog {
    struct Entry: Codable { var date: Date; var result: String }
    private static let key = "payin.notificationLog"
    /// Signing out or deleting the account leaves nothing about payments on the phone.
    static func clear() {
        for key in [key, "payin.setupStarted", "payin.setupPage", "recap.text", "recap.key"] { UserDefaults.standard.removeObject(forKey: key) }
    }
    static func record(_ result: String) {
        var entries = load()
        entries.insert(Entry(date: .now, result: result), at: 0)
        if let data = try? JSONEncoder().encode(Array(entries.prefix(5))) { UserDefaults.standard.set(data, forKey: key) }
    }
    static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}

struct BankSetupWizard: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = 0
    @State private var verified: String?
    private let steps = BankSetupStep.all
    private let startKey = "payin.setupStarted"
    private let pageKey = "payin.setupPage"
    private var onFinish: Bool { page >= steps.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
                    .frame(width: 48, height: 48).glassChrome(in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Close").accessibilityIdentifier("bank.close").padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("Bank Notification Setup").font(.system(.title, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink)
                    .lineLimit(2).minimumScaleFactor(0.8)
                Text("When your bank app says money came in, HowMuch marks the matching job paid. Set it up once in the Shortcuts app.")
                    .font(.subheadline).foregroundStyle(Palette.muted)
            }.padding(.top, 18)

            TabView(selection: $page) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in stepPage(index, step).tag(index) }
                finishPage.tag(steps.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: page)

            dots.frame(maxWidth: .infinity).padding(.bottom, 18)
            bottomBar
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
        .background { AppBackdrop().ignoresSafeArea() }
        .onAppear {
            // The demo always starts at step 1; real setups pick up where they left off.
            page = CommandLine.arguments.contains("--preview") ? 0 : min(UserDefaults.standard.integer(forKey: pageKey), steps.count)
            if UserDefaults.standard.object(forKey: startKey) == nil {
                UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: startKey)
            }
            check()
        }
        .onChange(of: page) { _, new in UserDefaults.standard.set(new, forKey: pageKey) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { check() } }
        .task {
            // Keep looking while setup is open; automations run in the background.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                check()
            }
        }
        .sensoryFeedback(.success, trigger: verified)
    }

    private func stepPage(_ index: Int, _ step: BankSetupStep) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 24).fill(.white.opacity(0.7))
                    RoundedRectangle(cornerRadius: 24).stroke(Palette.line, lineWidth: 1)
                    BankMockPhone(screen: step.mock).padding(.top, 22)
                }
                .frame(height: 340, alignment: .top)
                .clipShape(.rect(cornerRadius: 24))
                .padding(.top, 18)

                Text("Step \(index + 1) of \(steps.count)").font(.subheadline.weight(.medium)).foregroundStyle(Palette.muted).padding(.top, 8)
                    .accessibilityIdentifier("bank.step")
                Text(step.instruction).font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                if let detail = step.detail {
                    Text(detail).font(.subheadline).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                }
            }.padding(.horizontal, 2).padding(.bottom, 20)
        }.scrollIndicators(.hidden)
    }

    private var finishPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: verified == nil ? "checkmark.circle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 72)).foregroundStyle(verified == nil ? Palette.teal : .green)
                    .symbolEffect(.bounce, value: verified).padding(.top, 60)
                Text(verified == nil ? "And you're done!" : "It's working!").font(.system(.title, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink)
                Text(verified ?? "When your next PayNow or transfer alert arrives, HowMuch checks it against your unpaid jobs. Make sure who pays you is saved as Paid by on their jobs.")
                    .multilineTextAlignment(.center).foregroundStyle(Palette.muted)
                if verified == nil {
                    Label("Waiting for the first one…", systemImage: "hourglass").font(.footnote.weight(.medium)).foregroundStyle(Palette.muted)
                        .symbolEffect(.pulse).padding(.top, 6)
                }
            }.padding(.horizontal, 12)
        }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0...steps.count, id: \.self) { index in
                Capsule().fill(index == page ? Palette.ink : Palette.muted.opacity(0.3))
                    .frame(width: index == page ? 26 : 7, height: 7)
            }
        }.animation(.snappy, value: page).accessibilityHidden(true)
    }

    @ViewBuilder private var bottomBar: some View {
        HStack(spacing: 14) {
            if onFinish {
                wideButton("Back to Pay-in tracking", style: .dark) { dismiss() }
            } else {
                if steps[page].action == .openShortcuts {
                    wideButton("Open Shortcuts", symbol: "arrow.up.forward.square", style: .accent) {
                        if let url = URL(string: "shortcuts://") { openURL(url) }
                    }
                } else {
                    wideButton("Back", style: .light) { page = max(page - 1, 0) }
                }
                wideButton(page == steps.count - 1 ? "Done" : "Next", style: .dark) { page += 1 }.accessibilityIdentifier("bank.next")
            }
        }
    }

    private enum ButtonLook { case dark, light, accent }

    private func wideButton(_ title: String, symbol: String? = nil, style: ButtonLook, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(style == .light ? Palette.ink : .white)
            .background(style == .dark ? Palette.ink : style == .accent ? Palette.teal : .white.opacity(0.9), in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: style == .light ? 1 : 0))
        }.buttonStyle(.plain)
    }

    /// Looks for the first notification the automation handed over since setup began.
    private func check() {
        guard verified == nil else { return }
        let started = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: startKey))
        if let entry = PayInLog.load().first(where: { $0.date >= started }) {
            verified = "HowMuch read a bank notification \(entry.date.formatted(.relative(presentation: .named))): \(entry.result)"
            page = steps.count
        }
    }
}

// MARK: - Drawn iOS 27 Shortcuts screens

/// A drawing of the Shortcuts screen for a step, with the thing to tap ringed.
struct BankMockPhone: View {
    let screen: BankMockScreen
    private let canvas = Color(white: 0.95)
    private let row = Color.white
    private let dim = Color(white: 0.5)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("9:41").font(.system(size: 11, weight: .semibold))
                Spacer()
                Capsule().fill(.black).frame(width: 62, height: 18)
                Spacer()
                Image(systemName: "battery.75percent").font(.system(size: 11))
            }.padding(.horizontal, 8)
            content
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12).padding(.top, 10)
        .frame(width: 240, height: 400)
        .background(canvas, in: .rect(cornerRadius: 38))
        .overlay(RoundedRectangle(cornerRadius: 38).stroke(Color(white: 0.2), lineWidth: 5))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .library:
            Text("Library").font(.system(size: 20, weight: .bold)).padding(.top, 6)
            VStack(spacing: 0) {
                listRow("All Shortcuts", "rectangle.stack").opacity(0.5)
                listRow("Share Sheet", "square.and.arrow.up").opacity(0.5)
                listRow("Gallery", "square.grid.2x2").opacity(0.5)
                listRow("Automation", "clock.badge.checkmark").modifier(BankHighlight())
            }.background(row, in: .rect(cornerRadius: 14))
            Text("Apps").font(.system(size: 12, weight: .semibold)).padding(.top, 6).padding(.leading, 6)
            HStack(spacing: 8) { appIcon(size: 22); Text("HowMuch").font(.system(size: 11)); Spacer() }
                .padding(.horizontal, 8).padding(.vertical, 6).background(row, in: .rect(cornerRadius: 14)).opacity(0.5)

        case .noAutomations:
            HStack { circleIcon("chevron.left"); Spacer(); circleIcon("line.3.horizontal.decrease") }
            Text("Automation").font(.system(size: 20, weight: .bold))
            Spacer(minLength: 60)
            VStack(spacing: 4) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(dim)
                Text("No Automations").font(.system(size: 13, weight: .semibold))
                Text("Make shortcuts run automatically.").font(.system(size: 9)).foregroundStyle(dim)
            }.frame(maxWidth: .infinity)
            Spacer(minLength: 70)
            Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                .frame(width: 46, height: 46).background(row, in: Circle()).overlay(Circle().stroke(Color(white: 0.85)))
                .modifier(BankHighlight()).frame(maxWidth: .infinity)

        case .describe:
            HStack {
                circleIcon("chevron.left")
                Spacer()
                Text("New Shortcut").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("Edit").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(row, in: Capsule()).modifier(BankHighlight())
            }
            Text("Describe a Shortcut").font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(LinearGradient(colors: [.white, Color(red: 1, green: 0.96, blue: 0.94)], startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 30))
                .padding(.top, 20).opacity(0.6)

        case .actionSheet:
            HStack { circleIcon("chevron.left"); Spacer(); Text("New Shortcut").font(.system(size: 11, weight: .semibold)); Spacer(); circleIcon("sparkle") }
            Text("Add actions from below to create a shortcut.").font(.system(size: 9)).foregroundStyle(dim)
                .frame(maxWidth: .infinity).padding(.vertical, 36)
            VStack(alignment: .leading, spacing: 8) {
                searchBar("Search")
                HStack(spacing: 6) {
                    chip("Automation", "clock.badge.checkmark").modifier(BankHighlight())
                    chip("Scripting", "curlybraces").opacity(0.5)
                }
                actionRow("Send Message", color: .green).opacity(0.5)
                actionRow("Open App", color: .indigo).opacity(0.5)
            }.padding(10).background(Color(white: 0.9), in: .rect(cornerRadius: 22))

        case .triggerSearch:
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(dim)
                Text("Automation").font(.system(size: 9, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3).background(Color(white: 0.5), in: .rect(cornerRadius: 5))
                Text("Notification").font(.system(size: 11))
                Rectangle().fill(.blue).frame(width: 1.5, height: 12)
                Spacer()
            }.padding(.horizontal, 10).padding(.vertical, 8).background(Color(white: 0.88), in: Capsule())
            Text("Apps").font(.system(size: 13, weight: .bold)).padding(.top, 8)
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill").font(.system(size: 13)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Notification").font(.system(size: 11, weight: .semibold))
                    Text("“When I receive a notification from an app”").font(.system(size: 8)).foregroundStyle(dim).lineLimit(1)
                }
                Spacer()
            }.padding(10).background(row, in: .rect(cornerRadius: 16)).modifier(BankHighlight())

        case .trigger(let app, let filter, let focus):
            editorHeader
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "bell.badge.fill").font(.system(size: 10)).foregroundStyle(.red)
                        Text("When I receive a notification").font(.system(size: 11, weight: .medium))
                    }
                    HStack(spacing: 5) {
                        Text("from").font(.system(size: 11, weight: .medium))
                        if let app {
                            token(app)
                            Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.blue)
                                .frame(width: 20, height: 20).background(Color.blue.opacity(0.12), in: Circle())
                        } else {
                            token("App", placeholder: true).modifier(BankHighlight(active: focus == .app))
                        }
                    }
                }.padding(10)
                if filter {
                    Divider()
                    HStack(spacing: 5) {
                        token("Message"); Text("contains").font(.system(size: 10)); token("Received")
                        Spacer()
                    }.padding(10).modifier(BankHighlight(active: focus == .filter))
                }
                Divider()
                Label("Add Filter", systemImage: "plus.circle").font(.system(size: 10)).foregroundStyle(.blue).padding(10)
            }.background(row, in: .rect(cornerRadius: 14))

        case .appPicker:
            HStack { circleIcon("xmark"); Spacer(); Text("App").font(.system(size: 13, weight: .semibold)); Spacer(); Color.clear.frame(width: 24, height: 24) }
            searchBar("DBS", active: true)
            VStack(spacing: 0) {
                appRow(BankSetupStep.bankApp, color: .red, picked: false).modifier(BankHighlight())
                appRow("DBS PayLah!", color: .red, picked: false).opacity(0.5)
                appRow("DBS IDEAL", color: .gray, picked: false).opacity(0.5)
            }.background(row, in: .rect(cornerRadius: 12))

        case .actionSearch:
            searchBar("HowMuch", active: true)
            HStack(spacing: 8) { appIcon(size: 26); Text("HowMuch").font(.system(size: 12, weight: .semibold)) }.padding(.vertical, 4)
            VStack(spacing: 6) {
                actionRow("Add a job").opacity(0.5)
                actionRow("Earnings this week").opacity(0.5)
                actionRow("Record pay received").modifier(BankHighlight())
                actionRow("How much am I owed").opacity(0.5)
            }

        case .variable:
            HStack { circleIcon("chevron.left"); Spacer(); Text("Select Variable").font(.system(size: 11, weight: .semibold)); Spacer(); circleIcon("xmark") }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "bell.badge.fill").font(.system(size: 10)).foregroundStyle(.red)
                    Text("When I receive a notification").font(.system(size: 10, weight: .medium))
                }
                HStack(spacing: 5) { Text("from").font(.system(size: 10)); token(BankSetupStep.bankApp) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(row, in: .rect(cornerRadius: 14))
            Label("Notification", systemImage: "bell.badge").font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                .padding(.horizontal, 10).padding(.vertical, 5).background(Color.blue.opacity(0.12), in: .rect(cornerRadius: 8))
                .modifier(BankHighlight()).frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { appIcon(size: 18); Text("Record pay received from").font(.system(size: 11, weight: .medium)) }
                Text("Notification").font(.system(size: 10)).foregroundStyle(dim)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Color(white: 0.92), in: .rect(cornerRadius: 6))
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(row, in: .rect(cornerRadius: 14))

        case .saved:
            HStack { circleIcon("chevron.left"); Spacer(); circleIcon("line.3.horizontal.decrease") }
            Text("Automation").font(.system(size: 20, weight: .bold))
            Text("Personal").font(.system(size: 12, weight: .semibold)).padding(.leading, 6)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.badge.fill").font(.system(size: 14)).foregroundStyle(.red)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(dim)
                        appIcon(size: 20)
                    }
                    Text("When I get a notification from \(BankSetupStep.bankApp)").font(.system(size: 11, weight: .semibold)).lineLimit(2)
                    Text("Record pay received").font(.system(size: 9)).foregroundStyle(dim)
                }
                Spacer()
                Capsule().fill(Color.green).frame(width: 34, height: 20)
                    .overlay(alignment: .trailing) { Circle().fill(.white).frame(width: 16, height: 16).padding(2) }
                    .modifier(BankHighlight())
            }.padding(12).background(row, in: .rect(cornerRadius: 16))
        }
    }

    // MARK: Pieces

    private var editorHeader: some View {
        HStack(spacing: 6) {
            circleIcon("chevron.left")
            Spacer(minLength: 0)
            Text("New Shortcut").font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
            circleIcon("sparkle")
        }
    }

    private func listRow(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.blue).frame(width: 20)
            Text(title).font(.system(size: 11))
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(dim)
        }.padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func chip(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.blue)
            .padding(.horizontal, 9).padding(.vertical, 6).background(row, in: Capsule())
    }

    private func actionRow(_ title: String, color: Color? = nil) -> some View {
        HStack(spacing: 8) {
            if let color {
                RoundedRectangle(cornerRadius: 5).fill(color.gradient).frame(width: 20, height: 20)
            } else {
                appIcon(size: 20)
            }
            Text(title).font(.system(size: 11, weight: .medium))
            Spacer()
            Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(dim)
        }.padding(.horizontal, 8).padding(.vertical, 7).background(row, in: Capsule())
    }

    private func appIcon(size: CGFloat) -> some View {
        Text("H").font(.system(size: size * 0.55, weight: .heavy, design: .rounded)).foregroundStyle(Palette.teal)
            .frame(width: size, height: size).background(Color(red: 0.95, green: 0.94, blue: 0.91), in: .rect(cornerRadius: size * 0.25))
            .overlay(RoundedRectangle(cornerRadius: size * 0.25).stroke(Color(white: 0.8), lineWidth: 0.5))
    }

    private func appRow(_ name: String, color: Color, picked: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5).fill(color.gradient).frame(width: 22, height: 22)
            Text(name).font(.system(size: 11))
            Spacer()
            if picked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.blue) }
        }.padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func searchBar(_ text: String, active: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(dim)
            Text(text).font(.system(size: 11)).foregroundStyle(active ? .black : dim)
            if active { Rectangle().fill(.blue).frame(width: 1.5, height: 12) }
            Spacer()
            Image(systemName: "mic.fill").font(.system(size: 10)).foregroundStyle(dim)
        }.padding(.horizontal, 10).padding(.vertical, 7).background(Color(white: 0.88), in: Capsule())
    }

    private func token(_ title: String, placeholder: Bool = false) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(placeholder ? Color.blue.opacity(0.6) : .blue)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.blue.opacity(0.1), in: .rect(cornerRadius: 6))
    }

    private func circleIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            .frame(width: 24, height: 24).background(row, in: Circle()).overlay(Circle().stroke(Color(white: 0.85)))
    }
}

/// Pulsing teal ring with a pointing hand: "tap here".
private struct BankHighlight: ViewModifier {
    var active = true
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active {
            content
                .overlay(
                    RoundedRectangle(cornerRadius: 10).stroke(Palette.teal, lineWidth: 2.5).padding(-3)
                        .scaleEffect(pulse ? 1.05 : 1).opacity(pulse ? 0.5 : 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "hand.point.up.left.fill").font(.title3).foregroundStyle(Palette.teal)
                        .shadow(color: .black.opacity(0.3), radius: 2).offset(x: 8, y: 16).allowsHitTesting(false)
                }
                .onAppear {
                    // UI tests wait for the app to be idle, which a never-ending animation prevents.
                    guard !reduceMotion, !CommandLine.arguments.contains("--preview") else { return }
                    withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true }
                }
        } else {
            content
        }
    }
}
