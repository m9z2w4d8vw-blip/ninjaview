import AVFoundation
import SwiftUI
import UIKit

/// Registers the notification delegate and both background tasks at launch (background-task
/// registration has to happen before launch finishes), then hands off to WatchCenter.
final class NinjaViewAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationManager.shared.configure()
        BackgroundScheduler.register()
        WatchCenter.shared.didFinishLaunching()
        return true
    }
}

@main
@MainActor
struct NinjaViewApp: App {
    @UIApplicationDelegateAdaptor(NinjaViewAppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var downloads = DownloadCenter.shared
    @StateObject private var log = DebugLog.shared
    @StateObject private var avatars = AvatarStore.shared

    init() {
        Chrome.configure()
        do {
            // Videos play with sound even when the ring/silent switch is on silent.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            print("Audio session: \(error)")
        }
        DebugLog.shared.add(.app, "Launched NinjaView \(Bundle.main.versionString) on \(Diagnostics.modelIdentifier), iOS \(UIDevice.current.systemVersion)")
        _ = ProfileStore.session // creating it erases the previous session's downloads
        _ = ProfileStore.archive
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ProfileStore.session.wipe() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let inUse = Diagnostics.memoryFootprint.map { String(format: "%.0f MB", $0) } ?? "unknown"
                DebugLog.shared.warn(.app, "Memory warning (in use: \(inUse))")
            }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                DebugLog.shared.add(.app, "Thermal state is now \(Diagnostics.thermal(ProcessInfo.processInfo.thermalState))")
            }
        }
        WebFactory.shared.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(settings)
                .environmentObject(downloads)
                .environmentObject(log)
                .environmentObject(avatars)
                .tint(Color.nvInk)
                .onOpenURL { app.handleDeepLink($0) }
        }
    }
}
