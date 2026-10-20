import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack(path: $app.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    ProfileScreen(route: route)
                }
        }
        .overlay { ToastHost() }
        .onAppear {
            EngineDock.flushWaiting()
            Chrome.apply(settings.appearance)
        }
    }
}
