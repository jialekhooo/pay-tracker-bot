import SwiftUI

@main
struct HowMuchApp: App {
    @UIApplicationDelegateAdaptor(HowMuchAppDelegate.self) private var appDelegate
    @StateObject private var account = AppleAccountStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    init() {
        #if DEBUG
        // The intro test starts from a fresh install every time.
        if CommandLine.arguments.contains("--ui-test-onboarding") { UserDefaults.standard.removeObject(forKey: "onboarding.seen") }
        #endif
        OpeningSplash.shared.isReady = { !AppleAccountStore.shared.restoring }
        OpeningSplash.shared.prepareForLaunch()
    }
    var body: some Scene {
        WindowGroup {
            AccountRootView().environmentObject(account)
                .onOpenURL { PushCenter.shared.widgetURL = $0 }
                .onAppear { AppLock.shared.scenePhaseChanged(.active) } // a cold launch reports no phase change
                .tint(Palette.accent).preferredColorScheme(AppAppearance(rawValue: appearance)?.scheme)
        }
        .onChange(of: scenePhase) { _, phase in
            AppLock.shared.scenePhaseChanged(phase)
            OpeningSplash.shared.scenePhaseChanged(phase)
        }
    }
}
