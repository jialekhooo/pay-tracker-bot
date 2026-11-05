import SwiftUI
import AuthenticationServices
import UserNotifications
import HowMuchCore

struct AccountRootView: View {
    @EnvironmentObject private var auth: AppleAccountStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var push = PushCenter.shared
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
                Text("Sign in to create your account or return to your records. Your Telegram bot and its records remain separate.")
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
    @State private var deleteConfirm = false
    @State private var deleting = false
    var body: some View {
        Form {
            Section("Your account") {
                Label("Signed in with Apple", systemImage: "apple.logo")
                if let email = auth.account?.email { LabeledContent("Email", value: email) }
                LabeledContent("Account", value: auth.account?.id ?? "")
                Text("Each Apple sign-in owns a separate HowMuch account. Your account records sync through the independent iOS service.").font(.caption).foregroundStyle(Palette.muted)
            }
            Section("Sync") {
                Text(store.syncMessage).font(.subheadline)
                Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { Task { await auth.synchronize() } }.rowAction().disabled(auth.isDemo)
                Text("Offline edits stay in this account’s cache on your phone. Shared edits are kept for review instead of overwriting another device.").font(.caption).foregroundStyle(Palette.muted)
            }
            Section {
                Button("Sign out", role: .destructive) { signOut = true }.rowAction().accessibilityIdentifier("account.signOut")
                Button("Delete account", role: .destructive) { deleteConfirm = true }.rowAction().disabled(auth.isDemo)
            } footer: { Text("Signing out keeps your account’s cache separate from other users. Deleting your account removes its cloud records, devices and payment connections, and this phone’s account cache.") }
        }.detailStyle("Account & sync")
            .confirmationDialog("Sign out of this account? Pending edits remain in this account’s cache.", isPresented: $signOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await auth.signOut() } }
            }
            .confirmationDialog("Permanently delete this HowMuch account and its records? Export a backup first if you want to keep a copy.", isPresented: $deleteConfirm, titleVisibility: .visible) {
                Button("Continue to Apple verification", role: .destructive) { deleting = true }
            }
            .sheet(isPresented: $deleting) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Verify account deletion").font(.title.bold()).foregroundStyle(Palette.ink)
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
                    Text("Review your versions").font(.title2.bold()).foregroundStyle(Palette.ink)
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
            Text(title).font(.headline)
            Text("\(counted(data.shifts.count, "shift")) · \(counted(data.claims.count, "claim"))").font(.caption).foregroundStyle(Palette.muted)
            ForEach(Array(Set(data.shifts.map(\.currency))).sorted(), id: \.self) { currency in
                Text(money(data.shifts.filter { $0.currency == currency }.reduce(0) { $0 + $1.pay }, currency)).font(.subheadline.bold())
            }
        }
    }
}
