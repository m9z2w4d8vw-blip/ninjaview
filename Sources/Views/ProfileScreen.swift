import SwiftUI
import UIKit

/// A live profile laid out like Instagram's, filled in from the hidden tik.ninja page this
/// screen's engine drives. Opening it also starts this session's background download;
/// Archive keeps a copy on the phone.
@MainActor
struct ProfileScreen: View {
    let route: Route
    @ObservedObject private var engine: ProfileEngine
    @ObservedObject private var center = CrawlCenter.shared
    @ObservedObject private var archives = ProfileStore.archive
    @ObservedObject private var watch = WatchCenter.shared
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var panel: ProfilePanel? = nil
    @State private var notifyOpen = false

    private let gridTabs: [ProfileTab] = [.videos, .reposts, .stories]

    init(route: Route) {
        self.route = route
        _engine = ObservedObject(wrappedValue: EngineRegistry.shared.engine(for: route))
    }

    var body: some View {
        content
            .background(Color.nvPaper.ignoresSafeArea())
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { menuItems } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("More")
                }
            }
            .onAppear { engine.start() }
            .task(id: engine.header?.key) { await profileDidLoad() }
            .onChange(of: engine.linkedPost) { _, post in
                if let post { app.openPosts(.linked(engine, post), index: 0) }
            }
            .sheet(item: $panel) { which in
                switch which {
                case .followers: followSheet(.followers)
                case .following: followSheet(.following)
                case .analytics: AnalyticsSheet(lines: engine.analytics, isLoading: engine.analyticsLoading)
                }
            }
            .sheet(isPresented: $engine.pageVisible, onDismiss: { engine.pageDismissed() }) {
                WebPageSheet(webView: engine.bridge.webView) { engine.pageVisible = false }
            }
            .sheet(isPresented: $notifyOpen) {
                if let header = engine.header {
                    NotifySheet(handle: header.handle, name: header.name)
                        .environmentObject(AvatarStore.shared)
                }
            }
            .alert("tik.ninja", isPresented: dialogShown, presenting: engine.dialog) { dialog in
                if dialog.kind == .confirm {
                    Button("Cancel", role: .cancel) { dialog.complete(false) }
                    Button("OK") { dialog.complete(true) }
                } else {
                    Button("OK") { dialog.complete(true) }
                }
            } message: { dialog in
                Text(dialog.message)
            }
    }

    private var navTitle: String {
        engine.header?.handle ?? route.handle ?? "TikTok link"
    }

    private var dialogShown: Binding<Bool> {
        Binding(get: { engine.dialog != nil }, set: { if !$0 { engine.dialog = nil } })
    }

    @ViewBuilder private var content: some View {
        switch engine.phase {
        case .loading:
            StatusPanel(symbol: nil,
                        title: route.handle.map { "Looking up @\($0)" } ?? "Opening link",
                        detail: engine.isSlow ? "tik.ninja is taking longer than usual." : (engine.liveStatus.isEmpty ? nil : engine.liveStatus),
                        showsActions: engine.isSlow,
                        onRetry: retry,
                        onShowPage: { engine.showPage() })
        case .failed(let failure):
            StatusPanel(symbol: "exclamationmark.triangle",
                        title: failure.title,
                        detail: failure.detail,
                        showsActions: true,
                        onRetry: retry,
                        onShowPage: { engine.showPage() })
        case .ready:
            if let header = engine.header {
                profile(header)
            } else {
                linkOnly
            }
        }
    }

    private var gridTab: ProfileTab {
        gridTabs.contains(engine.selectedTab) ? engine.selectedTab : .videos
    }

    private func profile(_ header: ProfileHeader) -> some View {
        let stories = engine.tabs[.stories]?.items ?? []
        let highlights = engine.tabs[.highlights]?.items ?? []
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                InstaHeader(header: header, avatarURL: header.avatarURL, hasStories: !stories.isEmpty,
                            onAvatarTap: { app.openPosts(.live(engine, .stories), index: 0) },
                            onStatTap: { tapped in panel = tapped == .followers ? ProfilePanel.followers : ProfilePanel.following })
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                actionButtons(header)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                statusLines(header)
                    .padding(.horizontal, 16)
                if !highlights.isEmpty {
                    HighlightsRow(items: highlights) { index in
                        app.openPosts(.live(engine, .highlights), index: index)
                    }
                    .padding(.top, 16)
                }
                Section {
                    LiveTabBody(engine: engine, tab: gridTab) { index in
                        app.openPosts(.live(engine, gridTab), index: index)
                    }
                } header: {
                    InstaTabBar(tabs: gridTabs, selected: gridTab) { engine.select($0) }
                        .padding(.top, 14)
                        .background(Color.nvPaper)
                }
            }
        }
        .refreshable {
            await engine.reload()
            await profileDidLoad()
        }
    }

    private var linkOnly: some View {
        VStack(spacing: 14) {
            Text("This link opened a single post.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.nvInk)
            if let post = engine.linkedPost {
                Button("View post") { app.openPosts(.linked(engine, post), index: 0) }
                    .buttonStyle(InkButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Buttons and status

    private func actionButtons(_ header: ProfileHeader) -> some View {
        let saved = app.isSaved(header.handle)
        return HStack(spacing: 6) {
            Button {
                app.toggleSaved(header)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Label(saved ? "Saved" : "Save", systemImage: saved ? "star.fill" : "star")
            }
            .buttonStyle(InstaButtonStyle())
            archiveButton(header)
            Button { notifyOpen = true } label: {
                Image(systemName: watch.isWatched(header.handle) ? "bell.fill" : "bell")
                    .foregroundStyle(watch.isWatched(header.handle) ? Color.nvSignal : Color.nvInk)
            }
            .buttonStyle(InstaButtonStyle())
            .frame(width: 40)
            .accessibilityLabel("Notifications")
            .accessibilityValue(watch.isWatched(header.handle) ? "On" : "Off")
            Button { openAnalytics() } label: { Image(systemName: "chart.bar") }
                .buttonStyle(InstaButtonStyle())
                .frame(width: 40)
                .accessibilityLabel("Account analytics")
        }
    }

    @ViewBuilder private func archiveButton(_ header: ProfileHeader) -> some View {
        let stored = archives.profile(header.handle)
        if let crawl = center.find(header.handle, .archive) {
            CrawlAware(crawl: crawl) { live in
                if live.isActive {
                    Button { center.pause(live) } label: {
                        Label(live.postsTotal > 0 ? "Archiving \(Int(live.fraction * 100))%" : "Archiving", systemImage: "pause.fill")
                    }
                    .buttonStyle(InstaButtonStyle())
                    .accessibilityHint("Pauses the archive")
                } else {
                    archiveIdleButton(header, stored: stored)
                }
            }
        } else {
            archiveIdleButton(header, stored: stored)
        }
    }

    private func archiveIdleButton(_ header: ProfileHeader, stored: StoredProfile?) -> some View {
        Button {
            if stored?.status == .complete {
                app.openArchive(header.handle)
            } else {
                center.archive(header.handle)
            }
        } label: {
            switch stored?.status {
            case .complete?:
                Label("Archived", systemImage: "checkmark")
            case .paused?, .working?, .failed?:
                Label("Resume archive", systemImage: "arrow.clockwise")
            case nil:
                Label("Archive", systemImage: "archivebox")
            }
        }
        .buttonStyle(InstaButtonStyle())
    }

    @ViewBuilder private func statusLines(_ header: ProfileHeader) -> some View {
        WatchStatusLine(handle: header.handle) { notifyOpen = true }
        if let crawl = center.find(header.handle, .session) {
            CrawlStatusLine(crawl: crawl, topPadding: 12)
        }
        if let crawl = center.find(header.handle, .archive) {
            CrawlStatusLine(crawl: crawl, topPadding: 12)
        }
    }

    @ViewBuilder private var menuItems: some View {
        if let handle = engine.header?.handle ?? route.handle, let link = TikTokLinks.profile(handle) {
            Button {
                UIPasteboard.general.string = link.absoluteString
                downloads.show(.success, "Link copied")
            } label: {
                Label("Copy TikTok link", systemImage: "link")
            }
            ShareLink(item: link) {
                Label("Share profile", systemImage: "square.and.arrow.up")
            }
        }
        if let handle = engine.header?.handle, archives.profile(handle) != nil {
            Button { app.openArchive(handle) } label: { Label("Open archive", systemImage: "archivebox") }
        }
        Button { retry() } label: { Label("Reload", systemImage: "arrow.clockwise") }
        Button { engine.showPage() } label: { Label("Show tik.ninja page", systemImage: "safari") }
        Button { app.popToRoot() } label: { Label("New search", systemImage: "magnifyingglass") }
    }

    // MARK: Lists and actions

    private func followSheet(_ tab: ProfileTab) -> some View {
        let state = engine.tabs[tab] ?? TabState()
        return UserListSheet(title: tab.title,
                             users: state.users,
                             isLoading: state.isLoading || (!state.loaded && state.error == nil),
                             note: state.error ?? state.message,
                             onNearEnd: { Task { await engine.loadMore(tab) } },
                             onOpen: { handle in openFromSheet(handle) })
            .task { if engine.tabs[tab]?.loaded != true { await engine.load(tab) } }
    }

    /// Once the header is in: start this session's download, and load stories and
    /// highlights for the avatar ring and the highlights row.
    private func profileDidLoad() async {
        guard let header = engine.header else { return }
        CrawlCenter.shared.prefetch(header.handle)
        await engine.load(.stories)
        await engine.load(.highlights)
    }

    private func openAnalytics() {
        panel = .analytics
        Task { await engine.loadAnalytics() }
    }

    private func openFromSheet(_ handle: String) {
        panel = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            _ = app.open("@" + handle)
        }
    }

    private func retry() {
        Task {
            await engine.reload()
            await profileDidLoad()
        }
    }
}

@MainActor
struct LiveTabBody: View {
    @ObservedObject var engine: ProfileEngine
    let tab: ProfileTab
    let openPost: (Int) -> Void

    var body: some View {
        let state = engine.tabs[tab] ?? TabState()
        VStack(spacing: 0) {
            SquareGrid(items: state.items, onTap: openPost, onNearEnd: { position in
                // Ask tik.ninja for the next page a couple of rows before the end.
                guard position >= state.items.count - 6 else { return }
                Task { await engine.loadMore(tab) }
            })
            TabFooter(state: state, tab: tab) {
                Task { await engine.load(tab) }
            }
        }
        .task(id: tab) {
            if engine.tabs[tab]?.loaded != true { await engine.load(tab) }
        }
    }
}

struct TabFooter: View {
    let state: TabState
    let tab: ProfileTab
    let retry: () -> Void

    var body: some View {
        Group {
            if state.isLoading || (!state.loaded && state.error == nil) {
                ProgressView().padding(.vertical, 32)
            } else if let error = state.error {
                VStack(spacing: 12) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color.nvMuted)
                        .multilineTextAlignment(.center)
                    Button("Try again", action: retry).buttonStyle(OutlineButtonStyle())
                }
                .padding(32)
            } else if state.isEmpty {
                Text(state.message.isEmpty ? tab.emptyText : state.message)
                    .font(.footnote)
                    .foregroundStyle(Color.nvMuted)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 44)
                    .padding(.horizontal, 24)
            } else if state.exhausted {
                Text(state.endText.isEmpty ? "That's everything." : state.endText)
                    .font(.caption)
                    .foregroundStyle(Color.nvMuted)
                    .padding(.vertical, 28)
            } else {
                Color.clear.frame(height: 28)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
