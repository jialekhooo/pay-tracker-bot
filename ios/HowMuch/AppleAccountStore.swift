import SwiftUI
import AuthenticationServices
import CryptoKit
import UserNotifications
import HowMuchCore

struct AccountConflict: Identifiable {
    let id = UUID()
    let remote: CloudEnvelope
}
struct NotificationJobRoute: Identifiable {
    let id: UUID
    var directions = false
}

@MainActor
final class AppleAccountStore: ObservableObject {
    /// One account store for the app, so Siri and live-card buttons see the same records as the screens.
    static let shared = AppleAccountStore()
    @Published private(set) var account: AccountIdentity?
    @Published private(set) var tracker: TrackerStore?
    @Published private(set) var restoring = true
    @Published private(set) var signingIn = false
    @Published private(set) var challenge: AppleChallenge?
    @Published var error: String?
    @Published var conflict: AccountConflict?
    @Published var notificationJob: NotificationJobRoute?
    @Published private(set) var pushMessage = ""
    @Published private(set) var pushReady = false
    private(set) var isDemo = false
    let api = AccountAPI()
    private var activeChallenge: AppleChallenge?
    private var syncTask: Task<Void, Never>?
    private var syncing = false
    private var restoreStarted = false

    func restore() async {
        guard !restoreStarted else { return }; restoreStarted = true
        SharedWidgetStorage.clear()
        #if DEBUG
        if CommandLine.arguments.contains("--ui-test-signed-out") { restoring = false; return }
        if CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--ui-test-account") {
            isDemo = true
            // Stands in for Share → HowMuch from WhatsApp, which UI tests can't drive.
            if CommandLine.arguments.contains("--ui-test-shared-job") {
                try? SharedJobInbox.save("ni hao! you free for this?\n\nLocation: The Singapore EDITION Hotel\nAddress: 38 Cuscaden Rd, Singapore 249731\n\n12th Nov 1200-2100hrs\n13-14th Nov 0800-2000hrs\n15th Nov 0900-2000hrs")
            }
            // Stands in for Siri or Control Center's "Add a job", with a copied job message or an empty clipboard.
            if CommandLine.arguments.contains("--ui-test-add-job") {
                UIPasteboard.general.string = "Raffles City roadshow\nLocation: Raffles City\n20th Nov 1000-1900hrs\n21st Nov 1000-1900hrs\nPay: $14/hr"
                IntentActions.addJob()
            } else if CommandLine.arguments.contains("--ui-test-add-job-blank") {
                UIPasteboard.general.items = []
                IntentActions.addJob()
            }
            let id = CommandLine.arguments.contains("--ui-test-owner-b") ? "00000000-0000-4000-8000-000000000002" : "00000000-0000-4000-8000-000000000001"
            account = AccountIdentity(id: id, email: nil, displayName: "Preview", appleUserID: "ui-test")
            tracker = TrackerStore(accountID: id, suppressNotifications: true)
            if CommandLine.arguments.contains("--ui-test-widgets") { tracker?.activateWidgets() }
            if (CommandLine.arguments.contains("--ui-test-payments") || CommandLine.arguments.contains("--ui-test-travel") || CommandLine.arguments.contains("--ui-test-receipts")), let account {
                api.setSession(AccountSession(accessToken: "synthetic-ui-test", refreshToken: "unused-ui-test", expiresAt: Date().timeIntervalSince1970 + 86400, account: account))
            }
            PushCenter.shared.currentAccountID = id
            if CommandLine.arguments.contains("--ui-test-travel-notification"), let shift = tracker?.data.shifts.first {
                PushCenter.shared.pendingRoute = ["account_id": id, "shift_id": shift.id.uuidString, "kind": "travel_leave"]
            }
            restoring = false
            return
        }
        #endif
        await revokePendingSession()
        guard let cached = AccountVault.read("session", as: AccountSession.self) else {
            await clearNotifications(); restoring = false; return
        }
        api.setSession(cached)
        do {
            let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: cached.account.appleUserID)
            guard state == .authorized else { await clearSession(revoke: true); restoring = false; return }
            openAccount(cached.account)
            restoring = false
            await synchronize()
            adoptDeviceSettings()
            await registerPushIfAllowed()
        } catch {
            // Never display an unverified account or shared data when credential state cannot be checked.
            self.error = "Apple could not confirm your account. Sign in again to continue."
            restoring = false
        }
    }

    func becomeActive() async {
        guard !restoring, !isDemo, let account else { return }
        do {
            let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: account.appleUserID)
            if state == .revoked || state == .notFound { await clearSession(revoke: true); return }
        } catch { /* A transient check does not discard an existing verified account cache. */ }
        await revokePendingSession()
        await synchronize()
        await registerPushIfAllowed()
    }

    func prepareChallenge() async {
        guard !isDemo, !signingIn else { return }
        do {
            let data = try await api.publicRequest("/v1/auth/challenge", body: Data("{}".utf8))
            challenge = try JSONDecoder().decode(AppleChallenge.self, from: data)
        } catch { self.error = "Couldn’t prepare Apple sign-in. Check your connection and try again." }
    }
    func configure(_ request: ASAuthorizationAppleIDRequest, deleting: Bool = false) {
        guard let challenge else { return }
        activeChallenge = challenge
        signingIn = true
        request.requestedScopes = deleting ? [] : [.fullName, .email]
        request.nonce = SHA256.hash(data: Data(challenge.nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        request.state = challenge.challenge
    }
    func complete(_ result: Result<ASAuthorization, Error>, deleting: Bool = false) async {
        defer { signingIn = false; challenge = nil; activeChallenge = nil }
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let activeChallenge, credential.state == activeChallenge.challenge,
                  let identity = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
                  let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) else {
                throw TrackerError.invalid("Apple did not return a valid sign-in. Please try again.")
            }
            let fullName = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) } ?? ""
            let body = try JSONEncoder().encode(AppleCredentialPayload(challenge: activeChallenge.challenge, identityToken: identity,
                authorizationCode: code, deviceID: AccountVault.deviceID(), displayName: fullName))
            if deleting {
                guard credential.user == account?.appleUserID else { throw TrackerError.invalid("Use the Apple Account that owns this HowMuch account.") }
                let data = try await api.request("/v1/account/delete", method: "POST", body: body)
                let response = try JSONDecoder().decode(DeleteResult.self, from: data)
                let old = tracker
                await clearSession(revoke: false)
                try old?.removeAccountCache()
                if response.appleRevocationPending { error = "Your HowMuch account and records were deleted. Apple authorization cleanup is pending; you can also remove HowMuch under Sign in with Apple in Apple Account settings." }
                return
            }
            let data = try await api.publicRequest("/v1/auth/apple", body: body)
            let session = try JSONDecoder().decode(AccountSession.self, from: data)
            guard UUID(uuidString: session.account.id) != nil, session.account.appleUserID == credential.user,
                  session.revocationToken != nil else { throw TrackerError.invalid("The account response could not be verified.") }
            try AccountVault.save(session, key: "session")
            api.setSession(session)
            openAccount(session.account)
            await synchronize()
            adoptDeviceSettings()
            await registerPushIfAllowed()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // Cancellation does not create a local account or reveal data.
        } catch { self.error = error.localizedDescription }
    }
    private func openAccount(_ value: AccountIdentity) {
        syncTask?.cancel(); conflict = nil
        tracker?.deactivateWidgets()
        account = value
        let store = TrackerStore(accountID: value.id)
        tracker = store
        store.activateWidgets()
        store.onChange = { [weak self] in self?.scheduleSync() }
        PushCenter.shared.currentAccountID = value.id
        if !isDemo { LiveShiftCenter.connect { [weak self] token in await self?.sendLiveToken(token, owner: value.id) } }
    }
    /// Lets the server start and renew the Lock Screen shift card for this account.
    func sendLiveToken(_ token: LiveShiftCenter.Token, owner: String) async {
        guard !isDemo, account?.id == owner else { return }
        let environment = Bundle.main.object(forInfoDictionaryKey: "HowMuchAPNSEnvironment") as? String ?? "sandbox"
        switch token {
        case .start(let value):
            guard let body = try? JSONEncoder().encode(["token": value, "environment": environment]) else { return }
            _ = try? await api.request("/v1/devices/live-start", method: "PUT", body: body)
        case .noStart:
            _ = try? await api.request("/v1/devices/live-start", method: "DELETE")
        case .activity(let shift, let value):
            guard let body = try? JSONEncoder().encode(["token": value, "environment": environment, "shiftID": shift.uuidString]) else { return }
            _ = try? await api.request("/v1/devices/live-activity", method: "PUT", body: body)
        }
    }
    /// Once the account's records are in, older on-phone settings join them (only if the sync succeeded).
    private func adoptDeviceSettings() {
        guard let tracker, tracker.lastSyncedData != nil, conflict == nil else { return }
        tracker.adoptDeviceSettings()
    }
    func scheduleSync() {
        guard !isDemo else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.synchronize()
        }
    }
    func synchronize() async {
        guard !isDemo, !syncing, conflict == nil, let account, let store = tracker else { return }
        syncing = true; store.syncMessage = "Syncing your account…"
        defer { syncing = false }
        do {
            for attempt in 0..<2 {
                let remote = try JSONDecoder().decode(CloudEnvelope.self, from: await api.request("/v1/data"))
                guard self.account?.id == account.id, self.tracker === store else { return }
                try remote.data.validate()
                let current = store.data
                var target: TrackerData
                do { target = try AccountMerge.merge(base: store.lastSyncedData, local: current, remote: remote.data) }
                catch {
                    try store.preserveConflict(remote.data)
                    conflict = AccountConflict(remote: remote)
                    store.syncMessage = "A change needs your review. Both versions are safe."
                    return
                }
                if remote.revision == 0 && target.preferences == nil {
                    var settings = AppPreferences(); settings.displayName = account.displayName
                    settings.notifications = JobNotificationOptions()
                    target.preferences = settings
                }
                if target == remote.data {
                    try store.applySynced(remote, current: target)
                    pushReady = remote.pushReady ?? false
                    await registerPushIfAllowed()
                    return
                }
                do {
                    let body = try JSONEncoder().encode(CloudWrite(baseRevision: remote.revision, timezone: TimeZone.current.identifier, data: target))
                    let uploaded = try JSONDecoder().decode(CloudEnvelope.self, from: await api.request("/v1/data", method: "PUT", body: body))
                    guard self.account?.id == account.id, self.tracker === store else { return }
                    let afterUpload: TrackerData
                    do { afterUpload = try AccountMerge.merge(base: current, local: store.data, remote: uploaded.data) }
                    catch {
                        try store.preserveConflict(uploaded.data)
                        conflict = AccountConflict(remote: uploaded)
                        store.syncMessage = "A change needs your review. Both versions are safe."
                        return
                    }
                    try store.applySynced(uploaded, current: afterUpload)
                    pushReady = uploaded.pushReady ?? false
                    await registerPushIfAllowed()
                    if store.hasPendingChanges { scheduleSync() }
                    return
                } catch let error as AccountHTTPError where error.status == 409 && attempt == 0 { continue }
            }
            store.syncMessage = "Changes are saved on this phone. Try syncing again shortly."
        } catch let error as AccountHTTPError where error.status == 401 {
            guard self.account?.id == account.id, self.tracker === store else { return }
            await clearSession(revoke: true)
            self.error = "Please sign in with Apple again. Your account’s cached records are kept on this phone."
        } catch let error as AccountHTTPError where error.status == 422 || error.status == 413 {
            guard self.account?.id == account.id, self.tracker === store else { return }
            store.syncMessage = "Some records need attention before syncing"
            self.error = error.localizedDescription
        } catch is CancellationError {} catch {
            if self.account?.id == account.id { store.syncMessage = "Saved on this phone · waiting to sync" }
        }
    }
    func resolveConflict(usePhone: Bool) async {
        guard let conflict, let store = tracker, let account else { return }
        do {
            try store.preserveConflict(conflict.remote.data)
            if usePhone {
                let data = try JSONEncoder().encode(CloudWrite(baseRevision: conflict.remote.revision, timezone: TimeZone.current.identifier, data: store.data))
                let result = try JSONDecoder().decode(CloudEnvelope.self, from: await api.request("/v1/data", method: "PUT", body: data))
                guard self.account?.id == account.id, self.tracker === store else { return }
                try store.applySynced(result, current: store.data)
            } else { try store.applySynced(conflict.remote, current: conflict.remote.data) }
            self.conflict = nil
            if store.hasPendingChanges { scheduleSync() }
        } catch { self.error = "Your versions remain safe. \(error.localizedDescription)" }
    }
    func signOut() async { await clearSession(revoke: true) }
    func credentialsRevoked() async { await clearSession(revoke: true) }
    private func clearSession(revoke: Bool) async {
        let token = api.session?.revocationToken
        if revoke, let token { try? AccountVault.save(token, key: "pending-revocation") }
        syncTask?.cancel(); tracker?.onChange = nil
        LiveShiftCenter.connect(nil)
        tracker?.deactivateWidgets(); SharedWidgetStorage.clear()
        let previousStore = tracker
        account = nil; tracker = nil; conflict = nil; notificationJob = nil
        api.setSession(nil); AccountVault.remove("session")
        PushCenter.shared.currentAccountID = nil
        UIApplication.shared.unregisterForRemoteNotifications()
        await previousStore?.stopReminders()
        NativeTransitPlanner.shared.clear()
        await clearNotifications()
        if revoke { await revokePendingSession() }
    }
    private func revokePendingSession() async {
        guard let token = AccountVault.read("pending-revocation", as: String.self) else { return }
        do {
            _ = try await api.publicRequest("/v1/auth/revoke", body: JSONEncoder().encode(["revocationToken": token]))
            AccountVault.remove("pending-revocation")
        } catch { /* Offline sign-out stays local; its scoped revocation is retried on the next launch. */ }
    }
    private func clearNotifications() async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests(); center.removeAllDeliveredNotifications()
    }
    func enableNotifications() async {
        #if DEBUG
        // Opt-in simulator QA can exercise real system presentation with synthetic data.
        // Ordinary previews never request permission or register for remote push.
        if isDemo && CommandLine.arguments.contains("--ui-test-notifications") {
            do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
            catch { pushMessage = error.localizedDescription }
            return
        }
        #endif
        guard !isDemo else { pushMessage = "Notification permission and delivery are available after signing in to a real account."; return }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard allowed else { pushMessage = "Notifications are off in iPhone Settings. You can enable them there at any time."; return }
            UIApplication.shared.registerForRemoteNotifications()
            tracker?.refreshReminders()
        } catch { pushMessage = error.localizedDescription }
    }
    func registerPushIfAllowed() async {
        guard !isDemo, account != nil else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { tracker?.usesRemotePush = false; tracker?.refreshReminders(); return }
        guard (tracker?.data.settings.jobNotifications.enabled == true || tracker?.data.settings.travel?.enabled == true) else {
            _ = try? await api.request("/v1/devices/push", method: "DELETE")
            tracker?.usesRemotePush = false; tracker?.refreshReminders(); return
        }
        UIApplication.shared.registerForRemoteNotifications()
        if let token = PushCenter.shared.deviceToken { await registerDeviceToken(token) }
    }
    func registerDeviceToken(_ token: String) async {
        guard !isDemo, let owner = account?.id, (tracker?.data.settings.jobNotifications.enabled == true || tracker?.data.settings.travel?.enabled == true) else { return }
        do {
            let environment = Bundle.main.object(forInfoDictionaryKey: "HowMuchAPNSEnvironment") as? String ?? "sandbox"
            let body = try JSONEncoder().encode(["token": token, "environment": environment])
            let result = try JSONDecoder().decode(PushRegistrationResult.self, from: await api.request("/v1/devices/push", method: "PUT", body: body))
            guard account?.id == owner else { return }
            pushReady = result.pushReady
            tracker?.usesRemotePush = result.registered && result.pushReady
            tracker?.refreshReminders()
            pushMessage = result.registered && result.pushReady ? "Push notifications are registered for this account." : "iPhone reminders are active. Server push is waiting for Apple configuration."
        } catch { pushMessage = "Couldn’t register push notifications. Your phone’s reminder settings are kept." }
    }
    func openNotification(_ payload: [AnyHashable: Any]) async {
        guard let owner = payload["account_id"] as? String, owner.lowercased() == account?.id.lowercased() else { return }
        await synchronize()
        guard owner.lowercased() == account?.id.lowercased() else { return }
        if let value = payload["shift_id"] as? String, let id = UUID(uuidString: value), tracker?.data.shifts.contains(where: { $0.id == id }) == true { notificationJob = NotificationJobRoute(id: id, directions: (payload["kind"] as? String)?.hasPrefix("travel_") == true) }
    }
}

private struct AppleCredentialPayload: Encodable { let challenge: String; let identityToken: String; let authorizationCode: String; let deviceID: String; let displayName: String }
private struct CloudWrite: Encodable { let baseRevision: Int; let timezone: String; let data: TrackerData }
private struct PushRegistrationResult: Decodable { let registered: Bool; let pushReady: Bool }
private struct DeleteResult: Decodable { let deleted: Bool; let appleRevocationPending: Bool }
