import SwiftUI

@main
struct HowMuchApp: App {
    @UIApplicationDelegateAdaptor(HowMuchAppDelegate.self) private var appDelegate
    @StateObject private var account = AppleAccountStore.shared
    var body: some Scene {
        WindowGroup {
            AccountRootView().environmentObject(account)
                .onOpenURL { PushCenter.shared.widgetURL = $0 }
                .tint(Palette.teal).preferredColorScheme(.light)
        }
    }
}
