import SwiftUI

@main
struct HowMuchApp: App {
    @UIApplicationDelegateAdaptor(HowMuchAppDelegate.self) private var appDelegate
    @StateObject private var account = AppleAccountStore.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            AccountRootView().environmentObject(account)
                .onOpenURL { PushCenter.shared.widgetURL = $0 }
                .onAppear { AppLock.shared.scenePhaseChanged(.active) } // a cold launch reports no phase change
                .tint(Palette.teal).preferredColorScheme(.light)
        }
        .onChange(of: scenePhase) { _, phase in AppLock.shared.scenePhaseChanged(phase) }
    }
}
