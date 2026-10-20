import SwiftUI
import UIKit

struct ViewerRequest: Identifiable {
    let id = UUID()
    let tab: ProfileTab?
    let index: Int
    let single: ItemDetail?
}

/// A native profile: header, analytics, tabs, and grids or account lists, all
/// filled in from the hidden tik.ninja page this screen's engine drives.
@MainActor
struct ProfileScreen: View {
    let route: Route
    @ObservedObject private var engine: ProfileEngine
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var viewer: ViewerRequest? = nil

    init(route: Route) {
        self.route = route
        _engine = ObservedObject(wrappedValue: EngineRegistry.shared.engine(for: route))
    }

    var body: some View {
        content
            .background(Color.nvPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear { engine.start() }
            .onChange(of: engine.linkedPost) { _, post in
                if let post { viewer = ViewerRequest(tab: nil, index: 0, single: post) }
            }
            .fullScreenCover(item: $viewer) { request in
                ItemViewer(engine: engine, request: request)
            }
            .sheet(isPresented: $engine.pageVisible, onDismiss: { engine.pageDismissed() }) {
                WebPageSheet(webView: engine.bridge.webView) { engine.pageVisible = false }
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

    private var dialogShown: Binding<Bool> {
        Binding(get: { engine.dialog != nil }, set: { if !$0 { engine.dialog = nil } })
    }

    @ViewBuilder private var content: some View {
        switch engine.phase {
        case .loading:
            StatusPanel(symbol: nil,
                        title: loadingTitle,
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

    private func profile(_ header: ProfileHeader) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ProfileHeaderView(header: header) { tab in engine.select(tab) }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                AnalyticsSection(engine: engine)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                Section {
                    TabBody(engine: engine,
                            tab: engine.selectedTab,
                            openPost: { index in viewer = ViewerRequest(tab: engine.selectedTab, index: index, single: nil) },
                            openUser: { handle in _ = app.open("@" + handle) })
                } header: {
                    TabStrip(selected: engine.selectedTab) { engine.select($0) }
                }
            }
        }
        .refreshable { await engine.reload() }
    }

    private var linkOnly: some View {
        VStack(spacing: 14) {
            Text("This link opened a single post.")
                .font(.mono(.subheadline, weight: .bold))
                .foregroundStyle(Color.nvInk)
            if let post = engine.linkedPost {
                Button("View post") { viewer = ViewerRequest(tab: nil, index: 0, single: post) }
                    .buttonStyle(InkButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func retry() {
        Task { await engine.reload() }
    }

    private var loadingTitle: String {
        route.handle.map { "Looking up @\($0)" } ?? "Opening link"
    }

    private var titleText: String {
        if let header = engine.header { return header.name.isEmpty ? "@\(header.handle)" : header.name }
        if let handle = route.handle { return "@\(handle)" }
        return "TikTok link"
    }

    private var subtitleText: String? {
        guard let header = engine.header, !header.name.isEmpty else { return nil }
        return "@\(header.handle)"
    }

    private var isSaved: Bool {
        guard let handle = engine.header?.handle ?? route.handle else { return false }
        return app.isSaved(handle)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(titleText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.nvInk)
                    .lineLimit(1)
                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.mono(.caption2))
                        .foregroundStyle(Color.nvSignal)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                guard let header = engine.header else { return }
                app.toggleSaved(header)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: isSaved ? "star.fill" : "star")
                    .foregroundStyle(isSaved ? Color.nvSignal : Color.nvInk)
            }
            .disabled(engine.header == nil)
            .accessibilityLabel(isSaved ? "Remove from saved" : "Save profile")

            Menu {
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
                Button { retry() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                Button { engine.showPage() } label: { Label("Show tik.ninja page", systemImage: "safari") }
                Button { app.popToRoot() } label: { Label("New search", systemImage: "magnifyingglass") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }
}

// MARK: - Header

struct ProfileHeaderView: View {
    let header: ProfileHeader
    let onStat: (ProfileTab) -> Void
    @State private var bioExpanded = false

    var body: some View {
        VStack(spacing: 10) {
            RemoteImage(header.avatarURL, maxPixel: 300)
                .frame(width: 92, height: 92)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.nvRule, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(spacing: 3) {
                if !header.name.isEmpty {
                    Text(header.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.nvInk)
                        .multilineTextAlignment(.center)
                }
                Text("@\(header.handle)")
                    .font(.mono(.subheadline))
                    .foregroundStyle(Color.nvSignal)
                    .textSelection(.enabled)
            }
            if !header.bio.isEmpty {
                Text(header.bio)
                    .font(.subheadline)
                    .foregroundStyle(Color.nvMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(bioExpanded ? nil : 3)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { bioExpanded.toggle() } }
            }
            if !header.stats.isEmpty {
                HStack(spacing: 0) {
                    ForEach(header.stats, id: \.label) { stat in
                        statCell(stat)
                    }
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func statCell(_ stat: Stat) -> some View {
        let figure = VStack(spacing: 2) {
            Text(stat.value)
                .font(.mono(.headline, weight: .bold))
                .foregroundStyle(Color.nvInk)
            Text(stat.label)
                .font(.caption)
                .foregroundStyle(Color.nvMuted)
        }
        .frame(maxWidth: .infinity)
        if let tab = ProfileTab(statLabel: stat.label) {
            Button { onStat(tab) } label: { figure }
                .buttonStyle(.plain)
                .accessibilityHint("Shows \(tab.title.lowercased())")
        } else {
            figure
        }
    }
}

// MARK: - Analytics

struct AnalyticsRow: Identifiable {
    let id: Int
    let label: String
    let value: String?

    /// tik.ninja's analytics panel is plain text; pair each figure with its label,
    /// whichever order the two come in.
    static func pair(_ lines: [String]) -> [AnalyticsRow] {
        var rows: [AnalyticsRow] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let next: String? = i + 1 < lines.count ? lines[i + 1] : nil
            if let next, isFigure(line), !isFigure(next) {
                rows.append(AnalyticsRow(id: rows.count, label: next, value: line))
                i += 2
            } else if let next, !isFigure(line), isFigure(next) {
                rows.append(AnalyticsRow(id: rows.count, label: line, value: next))
                i += 2
            } else {
                rows.append(AnalyticsRow(id: rows.count, label: line, value: nil))
                i += 1
            }
        }
        return rows
    }

    static func isFigure(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        if first.isNumber { return true }
        guard "+-~\u{2248}".contains(first) else { return false }
        return trimmed.dropFirst().first?.isNumber == true
    }
}

@MainActor
struct AnalyticsSection: View {
    @ObservedObject var engine: ProfileEngine
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                if expanded { Task { await engine.loadAnalytics() } }
            } label: {
                HStack {
                    Text("Account analytics")
                        .font(.mono(.footnote, weight: .bold))
                        .foregroundStyle(Color.nvInk)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.nvMuted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                Rectangle().fill(Color.nvRule).frame(height: 1)
                analyticsBody.padding(14)
            }
        }
        .background(Color.nvCard)
        .overlay(Rectangle().strokeBorder(Color.nvRule, lineWidth: 1))
    }

    @ViewBuilder private var analyticsBody: some View {
        if engine.analyticsLoading || engine.analytics == nil {
            ProgressView().frame(maxWidth: .infinity)
        } else if let lines = engine.analytics, !lines.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 14) {
                ForEach(AnalyticsRow.pair(lines)) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        if let value = row.value {
                            Text(value)
                                .font(.mono(.headline, weight: .bold))
                                .foregroundStyle(Color.nvInk)
                        }
                        Text(row.label)
                            .font(.caption)
                            .foregroundStyle(row.value == nil ? Color.nvInk : Color.nvMuted)
                    }
                }
            }
        } else {
            Text("tik.ninja didn't return analytics for this account.")
                .font(.footnote)
                .foregroundStyle(Color.nvMuted)
        }
    }
}

// MARK: - Tabs

struct TabStrip: View {
    let selected: ProfileTab
    let onSelect: (ProfileTab) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(ProfileTab.allCases) { tab in
                        Button { onSelect(tab) } label: {
                            Text(tab.title)
                                .font(.mono(.footnote, weight: tab == selected ? .bold : .regular))
                                .foregroundStyle(tab == selected ? Color.nvInk : Color.nvMuted)
                                .padding(.top, 12)
                                .padding(.bottom, 10)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(tab == selected ? Color.nvInk : Color.clear)
                                        .frame(height: 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .id(tab)
                        .accessibilityAddTraits(tab == selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
            }
            .onChange(of: selected) { _, tab in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(tab, anchor: .center) }
            }
        }
        .background(Color.nvPaper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.nvRule).frame(height: 1)
        }
    }
}

@MainActor
struct TabBody: View {
    @ObservedObject var engine: ProfileEngine
    let tab: ProfileTab
    let openPost: (Int) -> Void
    let openUser: (String) -> Void

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 1.5), count: 3)
    }

    var body: some View {
        let state = engine.tabs[tab] ?? TabState()
        VStack(spacing: 0) {
            if tab.showsUsers {
                LazyVStack(spacing: 0) {
                    ForEach(state.users) { user in
                        Button { openUser(user.handle) } label: { UserRow(user: user) }
                            .buttonStyle(.plain)
                            .onAppear { prefetch(after: user.index, count: state.users.count) }
                    }
                }
            } else {
                LazyVGrid(columns: columns, spacing: 1.5) {
                    ForEach(state.items) { item in
                        Button { openPost(item.index) } label: { PostCell(item: item) }
                            .buttonStyle(.plain)
                            .onAppear { prefetch(after: item.index, count: state.items.count) }
                    }
                }
            }
            TabFooter(state: state, tab: tab) {
                Task { await engine.load(tab) }
            }
        }
        .task(id: tab) {
            if engine.tabs[tab]?.loaded != true { await engine.load(tab) }
        }
    }

    /// Ask tik.ninja for the next page a few cells before the end.
    private func prefetch(after index: Int, count: Int) {
        guard index >= count - 6 else { return }
        Task { await engine.loadMore(tab) }
    }
}

struct PostCell: View {
    let item: PostItem

    var body: some View {
        Color.nvRule.opacity(0.3)
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay { RemoteImage(item.thumbURL, maxPixel: 420) }
            .clipped()
            .overlay(alignment: .topLeading) {
                if !item.date.isEmpty { Chip(text: item.date).padding(5) }
            }
            .overlay(alignment: .topTrailing) {
                if item.isPhotos {
                    Image(systemName: "square.stack.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !item.plays.isEmpty { Chip(text: item.plays, symbol: "play.fill").padding(5) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !item.duration.isEmpty { Chip(text: item.duration).padding(5) }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [item.isPhotos ? "Photo post" : "Video"]
        if !item.title.isEmpty { parts.append(item.title) }
        if !item.date.isEmpty { parts.append(item.date) }
        if !item.plays.isEmpty { parts.append("\(item.plays) plays") }
        return parts.joined(separator: ", ")
    }
}

struct UserRow: View {
    let user: UserCard

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(user.avatarURL, maxPixel: 140)
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.nvRule, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(user.handle)")
                    .font(.mono(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.nvInk)
                    .lineLimit(1)
                if !user.nick.isEmpty {
                    Text(user.nick)
                        .font(.footnote)
                        .foregroundStyle(Color.nvMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !user.stat.isEmpty {
                Text(user.stat)
                    .font(.caption)
                    .foregroundStyle(Color.nvMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.nvRule).frame(height: 1).padding(.leading, 76)
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
                    .font(.mono(.caption))
                    .foregroundStyle(Color.nvMuted)
                    .padding(.vertical, 28)
            } else {
                Color.clear.frame(height: 28)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
