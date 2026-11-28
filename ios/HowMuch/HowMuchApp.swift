import SwiftUI
import MetricKit

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
        ProStore.shared.start()
        CrashReporter.shared.start()
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

/// In-house crash and hang reports: Apple's MetricKit hands the app its own diagnostics (at most once a
/// day, on real devices), and they go to HowMuch's server without the account, so they can't be tied to
/// anyone. Only the failure, the app version, the device model and the top of the call stack are sent.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()
    func start() {
        #if DEBUG
        if CommandLine.arguments.contains("--preview") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        #endif
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var items: [[String: String]] = []
        func add(_ kind: String, _ summary: String, _ stack: MXCallStackTree?) {
            let detail = stack.map { String(decoding: $0.jsonRepresentation(), as: UTF8.self) } ?? ""
            items.append(["kind": kind, "summary": String(summary.prefix(300)), "detail": String(detail.prefix(4000))])
        }
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let parts = [crash.exceptionType.map { "exception \($0)" }, crash.signal.map { "signal \($0)" }, crash.terminationReason].compactMap { $0 }
                add("crash", parts.isEmpty ? "Crash" : parts.joined(separator: ", "), crash.callStackTree)
            }
            for hang in payload.hangDiagnostics ?? [] {
                add("hang", "Main thread hung \(hang.hangDuration.formatted())", hang.callStackTree)
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                add("cpu", "Too much CPU: \(cpu.totalCPUTime.formatted())", cpu.callStackTree)
            }
            for disk in payload.diskWriteExceptionDiagnostics ?? [] {
                add("disk", "Too many disk writes: \(disk.totalWritesCaused.formatted())", disk.callStackTree)
            }
            if #available(iOS 16.0, *) {
                for launch in payload.appLaunchDiagnostics ?? [] {
                    add("launch", "Slow launch: \(launch.launchDuration.formatted())", launch.callStackTree)
                }
            }
        }
        guard !items.isEmpty else { return }
        send(items)
    }

    private func send(_ items: [[String: String]]) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        var system = utsname(); uname(&system)
        let device = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let body: [String: Any] = ["version": version, "device": device, "items": Array(items.prefix(20))]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: AccountAPI.base.appending(path: "v1/diagnostics"))
        request.httpMethod = "POST"; request.httpBody = data; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request).resume()  // best effort: MetricKit delivers again tomorrow if this fails
    }
}
