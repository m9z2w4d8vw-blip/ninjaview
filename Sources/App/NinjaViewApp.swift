import AVFoundation
import SwiftUI

@main
@MainActor
struct NinjaViewApp: App {
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
        DebugLog.shared.add(.app, "Launched NinjaView \(Bundle.main.versionString) on iOS \(UIDevice.current.systemVersion)")
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
