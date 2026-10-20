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
                    }
                }
        }
        .overlay { ToastHost() }
        .onAppear {
            EngineDock.flushWaiting()
            Chrome.apply(settings.appearance)
        }
        .onChange(of: scenePhase) { _, phase in
            CrawlCenter.shared.scenePhaseChanged(phase)
        }
    }
}
