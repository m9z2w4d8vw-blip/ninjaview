import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $app.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    switch route.kind {
                    case .live:
                        ProfileScreen(route: route)
                    case .archive:
                        ArchiveProfileView(handle: route.handle ?? route.query)
                    case .posts:
                        if let feed = FeedRegistry.shared.feed(for: route.id) {
                            PostFeedScreen(feed: feed)
                        } else {
                            ContentUnavailableView("This list was closed", systemImage: "square.stack")
                        }
                    }
                }
        }
        .overlay { ToastHost() }
        .onAppear {
            EngineDock.flushWaiting()
            Chrome.apply(settings.appearance)
        }
        .onChange(of: scenePhase) { _, phase in
            DebugLog.shared.add(.app, "App is \(String(describing: phase))")
            CrawlCenter.shared.scenePhaseChanged(phase)
            switch phase {
            case .active: WatchCenter.shared.runForegroundCheck()
            case .background: WatchCenter.shared.schedule()
            default: break
            }
        }
    }
}
