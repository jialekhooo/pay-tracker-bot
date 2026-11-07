import SwiftUI
import UserNotifications
import Combine

@MainActor
final class PushCenter: ObservableObject {
    static let shared = PushCenter()
    @Published var deviceToken: String?
    @Published var registrationError: String?
    var currentAccountID: String?
    @Published var widgetURL: URL?
    /// Set by Siri or Control Center to open Add shift (filled in from a copied job message).
    @Published var addJobRequest: UUID?
    @Published var pendingRoute: [AnyHashable: Any]?
}

final class HowMuchAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in LiveShiftCenter.observeTokens() }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let categories = [("TRAVEL_PREPARE", "Check directions"), ("TRAVEL_LEAVE", "Check directions"), ("TRAVEL_UPDATE", "Check directions"), ("START", "View job"), ("UPCOMING", "View tomorrow’s work"), ("END", "Review hours & claims"), ("PAYMENT_DUE", "Review payment")].map { kind, title in
            UNNotificationCategory(identifier: "HOWMUCH_" + kind, actions: [UNNotificationAction(identifier: "VIEW_JOB", title: title, options: [.foreground])], intentIdentifiers: [])
        }
        center.setNotificationCategories(Set(categories))
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushCenter.shared.deviceToken = token; PushCenter.shared.registrationError = nil }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushCenter.shared.registrationError = "Push registration needs a signed iPhone build with the Push Notifications capability. iPhone reminders remain available." }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let info = notification.request.content.userInfo
            guard let owner = info["account_id"] as? String, owner.lowercased() == PushCenter.shared.currentAccountID?.lowercased() else { completionHandler([]); return }
            completionHandler([.banner, .sound])
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { completionHandler(); return }
        Task { @MainActor in
            PushCenter.shared.pendingRoute = response.notification.request.content.userInfo
            completionHandler()
        }
    }
}
