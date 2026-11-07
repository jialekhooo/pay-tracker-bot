import SwiftUI
import AuthenticationServices
import LocalAuthentication
import UserNotifications
import HowMuchCore

struct AccountRootView: View {
    @EnvironmentObject private var auth: AppleAccountStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var push = PushCenter.shared
    /// The intro pages show once on a new install, before signing up.
    @AppStorage("onboarding.seen") private var introSeen = false
    private var showIntro: Bool {
        #if DEBUG
        // UI tests and previews go straight to their screens unless a test is checking the intro.
        let args = CommandLine.arguments
        if args.contains("--ui-test-onboarding") { return !introSeen }
        if args.contains(where: { $0 == "--preview" || $0.hasPrefix("--ui-test") }) { return false }
        #endif
        return !introSeen
    }
    var body: some View {
        Group {
            if auth.restoring {
                ZStack { Palette.canvas.ignoresSafeArea(); ProgressView("Opening your account…").tint(Palette.teal) }
            } else if let store = auth.tracker, auth.account != nil {
                ContentView().environmentObject(store)
                    .alert("Couldn't complete that", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                        Button("OK") { store.error = nil }
                    } message: { Text(store.error ?? "") }
                    .sheet(item: $auth.notificationJob) { route in
                        NavigationStack {
                            Group {
                                if route.directions, let shift = store.data.shifts.first(where: { $0.id == route.id }) {
                                    TravelDepartureView(shift: shift).environmentObject(store)
                                } else { ShiftDetailView(shiftID: route.id).environmentObject(store) }
                            }
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { auth.notificationJob = nil } } }
                        }
                    }
            } else if showIntro {
                IntroPagesView { introSeen = true }
            } else { AppleWelcomeView() }
        }
        .task { await auth.restore(); await openPendingNotification() }
        .onChange(of: scenePhase) { _, value in if value == .active { Task { await auth.becomeActive() } } }
        .onReceive(push.$deviceToken.compactMap { $0 }.removeDuplicates()) { token in Task { await auth.registerDeviceToken(token) } }
        .onChange(of: auth.account?.id) { _, _ in Task { await openPendingNotification() } }
        .onReceive(push.$pendingRoute) { _ in Task { await openPendingNotification() } }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in Task { await auth.credentialsRevoked() } }
        .alert("Your HowMuch account", isPresented: Binding(get: { auth.error != nil }, set: { if !$0 { auth.error = nil } })) { Button("OK") { auth.error = nil } } message: { Text(auth.error ?? "") }
        .sheet(item: $auth.conflict) { value in
            if let store = auth.tracker { AccountConflictView(conflict: value).environmentObject(store) }
        }
    }
    private func openPendingNotification() async {
        guard !auth.restoring, auth.account != nil, let payload = push.pendingRoute else { return }
        push.pendingRoute = nil
        await auth.openNotification(payload)
    }
}

struct AppleWelcomeView: View {
    @EnvironmentObject private var auth: AppleAccountStore
    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            GeometryReader { geometry in
              ScrollView {
               VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 20)
                Image("BrandLogo").resizable().scaledToFit().frame(width: 100, height: 100).clipShape(RoundedRectangle(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 16) {
                    Text("HOWMUCH").font(.caption2.weight(.bold)).tracking(3).foregroundStyle(Palette.teal)
                    Text("Your work.\nYour account.").font(.system(size: 42, weight: .bold, design: .rounded)).tracking(-1.4).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    Text("Your jobs, earnings and reminders, together in one place.").font(.title3).foregroundStyle(Palette.muted)
                }
                VStack(alignment: .leading, spacing: 16) {
                    feature("person.crop.circle.badge.checkmark", "A private account with Sign in with Apple")
                    feature("bell.badge", "Upcoming shifts, start/end and payment alerts")
                    feature("square.and.arrow.down", "Import previous shifts once, if you want")
                }
                Spacer(minLength: 20)
                AppleAccountButton()
                Text("Sign in to create your account or return to your records.")
                    .font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack { Link("Privacy", destination: AccountAPI.base.appending(path: "/privacy")); Spacer(); Text("HowMuch for iPhone").foregroundStyle(Palette.muted) }.font(.caption)
               }.padding(28).padding(.bottom, 12)
                .frame(minHeight: geometry.size.height, alignment: .leading)
              }
            }
        }
    }
    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 13) { Image(systemName: icon).frame(width: 24).foregroundStyle(Palette.teal); Text(text).font(.subheadline).foregroundStyle(Palette.ink) }
    }
}

struct AppleAccountButton: View {
    @EnvironmentObject private var auth: AppleAccountStore
    var deleting = false
    var body: some View {
        VStack(spacing: 12) {
            SignInWithAppleButton(deleting ? .signIn : .continue, onRequest: { auth.configure($0, deleting: deleting) }, onCompletion: { result in
                Task { await auth.complete(result, deleting: deleting); if auth.account == nil || deleting { await auth.prepareChallenge() } }
            }).signInWithAppleButtonStyle(.black).frame(height: 52).clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(auth.challenge == nil || auth.signingIn).accessibilityIdentifier(deleting ? "account.deleteApple" : "account.signInApple")
            if auth.challenge == nil && !auth.signingIn {
                Button("Prepare Apple sign-in", systemImage: "arrow.clockwise") { Task { await auth.prepareChallenge() } }.font(.caption)
            }
            if auth.signingIn { ProgressView("Verifying with Apple…").font(.caption) }
        }
        .task {
            await auth.prepareChallenge()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(240))
                if !Task.isCancelled { await auth.prepareChallenge() }
            }
        }
    }
}

struct AccountSettingsView: View {
    @EnvironmentObject private var auth: AppleAccountStore
    @EnvironmentObject private var store: TrackerStore
    @State private var signOut = false
    @State private var signOutEverywhere = false
    @State private var deleteConfirm = false
    @State private var deleting = false
    var body: some View {
        AppForm {
            Section(styled: "Your account") {
                Label("Signed in with Apple", systemImage: "apple.logo")
                if let email = auth.account?.email { LabeledContent("Email", value: email) }
                LabeledContent("Account", value: auth.account?.id ?? "")
                Text("Each Apple sign-in owns a separate HowMuch account. Your account records sync through the independent iOS service.").font(.caption).foregroundStyle(Palette.muted)
            }
            Section(styled: "Sync") {
                Text(store.syncMessage).font(.subheadline)
                Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { Task { await auth.synchronize() } }.rowAction().disabled(auth.isDemo)
                Text("Offline edits stay in this account’s cache on your phone. Shared edits are kept for review instead of overwriting another device.").font(.caption).foregroundStyle(Palette.muted)
            }
            Section {
                Button("Sign out", role: .destructive) { signOut = true }.rowAction().accessibilityIdentifier("account.signOut")
                Button("Sign out of all devices", role: .destructive) { signOutEverywhere = true }.rowAction().disabled(auth.isDemo).accessibilityIdentifier("account.signOutAll")
                Button("Delete account", role: .destructive) { deleteConfirm = true }.rowAction().disabled(auth.isDemo)
            } footer: { Text("Signing out keeps your account’s cache separate from other users. Deleting your account removes its cloud records, devices and payment connections, and this phone’s account cache.").formFootnote() }
        }.detailStyle("Account & sync")
            .confirmationDialog("Sign out on every iPhone using this account? Use this if a phone was lost or stolen.", isPresented: $signOutEverywhere, titleVisibility: .visible) {
                Button("Sign out everywhere", role: .destructive) { Task { await auth.signOutEverywhere() } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Sign out of this account? Pending edits remain in this account’s cache.", isPresented: $signOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await auth.signOut() } }
            }
            .confirmationDialog("Permanently delete this HowMuch account and its records? Export a backup first if you want to keep a copy.", isPresented: $deleteConfirm, titleVisibility: .visible) {
                Button("Continue to Apple verification", role: .destructive) { deleting = true }
            }
            .sheet(isPresented: $deleting) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Verify account deletion").font(.appTitle).foregroundStyle(Palette.ink)
                        Text("Use the same Apple Account to confirm. This permanently deletes your HowMuch account and cloud records.").foregroundStyle(Palette.muted)
                        AppleAccountButton(deleting: true)
                        Spacer()
                    }.padding(24).background(Palette.canvas)
                        .toolbar { Button("Cancel") { deleting = false } }
                }
            }
    }
}

struct AccountConflictView: View {
    @EnvironmentObject private var auth: AppleAccountStore
    @EnvironmentObject private var store: TrackerStore
    let conflict: AccountConflict
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Review your versions").font(.appTitle).foregroundStyle(Palette.ink)
                    Text("The same records changed in two places. Copies of both versions have been saved in this account’s protected cache.").font(.subheadline).foregroundStyle(Palette.muted)
                    version("This iPhone", store.data)
                    version("Your account", conflict.remote.data)
                    Button("Keep this iPhone’s version") { Task { await auth.resolveConflict(usePhone: true) } }.primaryButton()
                    Button("Use your account’s version") { Task { await auth.resolveConflict(usePhone: false) } }.primaryButton()
                    Button("Review later") { auth.conflict = nil }.rowAction()
                }.padding(24)
            }.background(Palette.canvas).navigationTitle("Sync review").navigationBarTitleDisplayMode(.inline)
        }
    }
    private func version(_ title: String, _ data: TrackerData) -> some View {
        Card {
            Text(title).font(.appHeadline)
            Text("\(counted(data.shifts.count, "shift")) · \(counted(data.claims.count, "claim"))").font(.caption).foregroundStyle(Palette.muted)
            ForEach(Array(Set(data.shifts.map(\.currency))).sorted(), id: \.self) { currency in
                Text(money(data.shifts.filter { $0.currency == currency }.reduce(0) { $0 + $1.total }, currency)).font(.subheadline.bold())
            }
        }
    }
}

// MARK: - Face ID lock

/// Optional lock that asks for Face ID (or the passcode) whenever HowMuch comes back from the background.
/// It is a setting on this iPhone only and never syncs. The lock screen sits in its own window
/// above everything, including sheets and alerts, so nothing shows through it.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    private static let key = "appLock.enabled"
    @Published private(set) var enabled = AppLock.stored
    @Published private(set) var locked = false
    @Published var message: String?
    private var window: UIWindow?
    private weak var previousKey: UIWindow?
    private var unlocking = false
    /// Ask straight away only after launch or a return from the background. The Face ID sheet itself
    /// makes the app briefly inactive, so asking on every activation would loop after a cancel.
    private var promptOnActive: Bool

    /// Preview and UI-test runs keep the setting in memory, so a test never leaves the next launch locked.
    private static var inMemory: Bool {
        #if DEBUG
        return CommandLine.arguments.contains { $0 == "--preview" || $0.hasPrefix("--ui-test") }
        #else
        return false
        #endif
    }
    private static var stored: Bool { inMemory ? false : UserDefaults.standard.bool(forKey: key) }

    private init() {
        let on = AppLock.stored
        locked = on; promptOnActive = on
    }

    /// "Face ID", "Touch ID" or "Passcode", for labels.
    var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    /// Turning the lock on needs a successful unlock first, so nobody is locked out by a lock that can't open.
    func setEnabled(_ on: Bool) async {
        message = nil
        if on {
            guard await authenticate(reason: "Turn on the HowMuch lock") else { return }
        }
        enabled = on
        if !Self.inMemory { UserDefaults.standard.set(on, forKey: Self.key) }
        if !on { locked = false; hide() }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard enabled else { return }
        switch phase {
        case .background: locked = true; promptOnActive = true; show()
        case .inactive: show() // covers the app switcher snapshot
        case .active:
            guard locked else { hide(); return }
            show()
            if promptOnActive { promptOnActive = false; Task { await unlock(automatic: true) } }
        @unknown default: break
        }
    }

    func unlock(automatic: Bool = false) async {
        guard locked, !unlocking else { return }
        #if DEBUG
        // UI tests stand in for the person: the cover stays until the test taps Unlock.
        if automatic, CommandLine.arguments.contains("--ui-test-app-lock") { return }
        #endif
        unlocking = true; defer { unlocking = false }
        if await authenticate(reason: "Unlock HowMuch") { locked = false; hide() }
    }

    private func authenticate(reason: String) async -> Bool {
        #if DEBUG
        if CommandLine.arguments.contains("--ui-test-app-lock") { return true }
        #endif
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "Set a passcode on this iPhone in Settings to use the lock."
            return false
        }
        do { return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch { message = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription; return false }
    }

    private func show() {
        if window != nil { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: AppLockScreen(lock: self))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        // Key, so VoiceOver and the keyboard go to the lock and not the app behind it.
        previousKey = scene.windows.first { $0.isKeyWindow }
        window.makeKeyAndVisible()
        self.window = window
    }

    private func hide() {
        guard !locked else { return }
        window?.isHidden = true; window = nil
        previousKey?.makeKey()
    }
}

private struct AppLockScreen: View {
    @ObservedObject var lock: AppLock
    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: lock.methodName == "Touch ID" ? "touchid" : "faceid").font(.system(size: 54)).foregroundStyle(Palette.teal)
                Text("HowMuch is locked").font(.appHeadline).foregroundStyle(Palette.ink)
                if lock.locked {
                    Button("Unlock with \(lock.methodName)") { Task { await lock.unlock() } }
                        .primaryButton().padding(.horizontal, 40).accessibilityIdentifier("appLock.unlock")
                }
                if let message = lock.message { Text(message).font(.caption).foregroundStyle(Palette.muted).multilineTextAlignment(.center).padding(.horizontal, 32) }
            }
        }
    }
}

struct AppLockToggleRow: View {
    @ObservedObject private var lock = AppLock.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { lock.enabled }, set: { on in Task { await lock.setEnabled(on) } })) {
                HStack(spacing: 12) {
                    Image(systemName: lock.methodName == "Touch ID" ? "touchid" : "faceid").font(.rowIcon).frame(width: 32, height: 32)
                        .foregroundStyle(Palette.teal).background(Palette.mint, in: RoundedRectangle(cornerRadius: 9))
                    Text("Lock with \(lock.methodName)").font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Palette.ink)
                }
            }.tint(Palette.teal).frame(minHeight: 48).accessibilityIdentifier("settings.appLock")
            Text(lock.message ?? "Ask for \(lock.methodName) each time HowMuch is opened. Only on this iPhone.")
                .font(.caption).foregroundStyle(Palette.muted).padding(.leading, 44).padding(.bottom, 8)
        }
    }
}

// MARK: - Intro pages

/// A quick tour for new users: what HowMuch does, then Sign up.
struct IntroPagesView: View {
    let finish: () -> Void
    @State private var page = 0
    private struct Page { let symbol: String?; let eyebrow: String; let title: String; let body: String; let points: [(String, String)] }
    private let pages: [Page] = [
        Page(symbol: nil, eyebrow: "WELCOME TO HOWMUCH", title: "Know what every\nshift is worth.",
             body: "HowMuch keeps your part-time and freelance work in one place, from booking to getting paid.",
             points: []),
        Page(symbol: "doc.on.clipboard", eyebrow: "ADD JOBS FAST", title: "Paste a job post.\nWe fill it in.",
             body: "Copy a job message from WhatsApp or Telegram. HowMuch reads the dates, times, pay and venue for you.",
             points: [("clock", "Hourly or lump-sum pay, overtime and breaks"), ("plus.circle", "Bonuses, allowances and tips"), ("repeat", "Several dates or a repeating shift at once"), ("paperplane", "Or send shifts from Telegram with @paytracker1_bot")]),
        Page(symbol: "banknote", eyebrow: "GET PAID ON TIME", title: "See who owes you,\nand how much.",
             body: "Every finished shift waits for payment until you mark it paid, so nothing slips through.",
             points: [("calendar.badge.clock", "Reminders when payment is due"), ("creditcard", "Spot pay-ins from your bank emails"), ("car", "Track cab, food and other claims")]),
        Page(symbol: "bell.badge", eyebrow: "STAY ON SCHEDULE", title: "Never miss\na shift.",
             body: "Reminders before each job, a nudge when it's time to leave, and your earnings live while you work.",
             points: [("map", "Directions with Apple Maps"), ("rectangle.on.rectangle", "Home Screen and Lock Screen widgets"), ("calendar", "Sync with your calendar")]),
        Page(symbol: nil, eyebrow: "MEET PENNY", title: "Penny grows\nas you work.",
             body: "Every shift and payday earns coins. Hatch Penny, keep a streak going and dress Penny up along the way.",
             points: []),
    ]

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page < pages.count - 1 {
                        Button("Skip") { finish() }.font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
                            .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("intro.skip")
                    }
                }.frame(height: 44).padding(.horizontal, 20)
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in pageView(pages[index], index: index).tag(index) }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule().fill(index == page ? Palette.teal : Palette.line).frame(width: index == page ? 22 : 8, height: 8)
                    }
                }
                .animation(.snappy, value: page)
                .accessibilityElement().accessibilityLabel("Page \(page + 1) of \(pages.count)")
                .padding(.bottom, 20)
                Button(page == pages.count - 1 ? "Sign up" : "Next") {
                    if page == pages.count - 1 { finish() } else { withAnimation { page += 1 } }
                }
                .primaryButton().padding(.horizontal, 28).padding(.bottom, 12)
                .accessibilityIdentifier(page == pages.count - 1 ? "intro.signUp" : "intro.next")
            }
        }
    }

    private func pageView(_ item: Page, index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                art(item, index: index).frame(maxWidth: .infinity).frame(height: 220)
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.eyebrow).font(.caption2.weight(.bold)).tracking(2.5).foregroundStyle(Palette.teal)
                    Text(item.title).font(.system(size: 34, weight: .bold, design: .rounded)).tracking(-1).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.body).font(.body).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                if !item.points.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(item.points, id: \.1) { point in
                            HStack(spacing: 12) {
                                Image(systemName: point.0).font(.body).frame(width: 30, height: 30).foregroundStyle(Palette.teal)
                                    .background(Palette.mint, in: RoundedRectangle(cornerRadius: 8))
                                Text(point.1).font(.subheadline).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }.padding(.horizontal, 28).padding(.top, 8)
        }.scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder private func art(_ item: Page, index: Int) -> some View {
        if index == 0 {
            Image("BrandLogo").resizable().scaledToFit().frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 34)).accessibilityHidden(true)
        } else if let symbol = item.symbol {
            Image(systemName: symbol).font(.system(size: 76, weight: .semibold)).foregroundStyle(Palette.teal)
                .frame(width: 170, height: 170).background(Palette.mint, in: Circle()).accessibilityHidden(true)
        } else {
            ZStack {
                PetScene(item: nil)
                PetSprite(stage: .hatchling, mood: .thriving).frame(width: 150, height: 150).offset(y: 6)
            }.frame(width: 240, height: 210).clipShape(RoundedRectangle(cornerRadius: 28)).accessibilityHidden(true)
        }
    }
}
