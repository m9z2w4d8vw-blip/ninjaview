import SwiftUI
import UIKit

/// A live Instagram profile: header, stories and posts, with saving, archiving and notifications.
@MainActor
struct IGProfileScreen: View {
    let route: Route
    @ObservedObject private var engine: IGEngine
    @ObservedObject private var archive = IGArchive.shared
    @ObservedObject private var watch = WatchCenter.shared
    @ObservedObject private var postArchiver = IGPostArchiver.shared
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var viewer: IGViewerRequest? = nil
    @State private var notifyOpen = false

    init(route: Route) {
        self.route = route
        _engine = ObservedObject(wrappedValue: IGRegistry.shared.engine(for: route))
    }

    private var handle: String { engine.profile?.handle ?? engine.handle }

    var body: some View {
        content
            .background(Color.nvPaper.ignoresSafeArea())
            .navigationTitle(handle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { menuItems } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("More")
                }
            }
            .task { await engine.loadAll() }
            .onChange(of: engine.profile) { _, profile in
                if let profile, profile.status == "ok" || profile.isPrivate {
                    app.didLoad(profile.header, platform: .instagram)
                }
            }
            .fullScreenCover(item: $viewer) { request in
                IGViewer(request: request)
                    .environmentObject(AvatarStore.shared)
                    .environmentObject(DownloadCenter.shared)
            }
            .sheet(isPresented: $notifyOpen) {
                NotifySheet(handle: handle, name: "", platform: .instagram)
                    .environmentObject(AvatarStore.shared)
            }
            .sheet(isPresented: $engine.pageVisible, onDismiss: { engine.pageClosed() }) {
                WebPageSheet(webView: engine.bridge.webView) { engine.pageVisible = false }
            }
    }

    @ViewBuilder private var content: some View {
        if let profile = engine.profile, profile.status == "ok" || profile.isPrivate {
            loaded(profile)
        } else {
            switch engine.phase {
            case .loading, .ready:
                ProgressView("Opening @\(engine.handle)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsCheck:
                checkView
            case .failed(let failure):
                ContentUnavailableView {
                    Label(failure.title, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure.detail)
                } actions: {
                    Button("Try again") { Task { await engine.refresh() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.nvInk)
                }
            }
        }
    }

    private var checkView: some View {
        ContentUnavailableView {
            Label("Check needed", systemImage: "checkmark.shield")
        } description: {
            Text("insta-stories-viewer.com wants to confirm you're a person before it shows @\(engine.handle). Open the page, finish the check, then close it.")
        } actions: {
            Button("Open the page") { engine.showPage() }
                .buttonStyle(.borderedProminent)
                .tint(Color.nvInk)
        }
    }

    private func loaded(_ profile: IGProfile) -> some View {
        let stories = engine.stories?.items ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InstaHeader(header: profile.header, avatarURL: profile.avatarURL, hasStories: !stories.isEmpty,
                            onAvatarTap: { openStories(at: 0) }, onStatTap: { _ in })
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                buttons(profile)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                statusLines(profile)
                    .padding(.horizontal, 16)
                if engine.isCaptcha {
                    checkBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
                if profile.isPrivate {
                    Label("This account is private, so its stories and posts can't be shown.", systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(Color.nvMuted)
                        .padding(.horizontal, 16)
                        .padding(.top, 28)
                } else {
                    storiesSection
                    postsSection
                }
            }
            .padding(.bottom, 24)
        }
        .refreshable { await engine.refresh() }
    }

    // MARK: Buttons and status

    private func buttons(_ profile: IGProfile) -> some View {
        let saved = app.isSaved(profile.handle, platform: .instagram)
        let watching = watch.isWatched(profile.handle, platform: .instagram)
        return HStack(spacing: 6) {
            Button {
                app.toggleSaved(profile.header, platform: .instagram)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Label(saved ? "Saved" : "Save", systemImage: saved ? "star.fill" : "star")
            }
            .buttonStyle(InstaButtonStyle())
            archiveButton(profile)
            Button { notifyOpen = true } label: {
                Image(systemName: watching ? "bell.fill" : "bell")
                    .foregroundStyle(watching ? Color.nvSignal : Color.nvInk)
            }
            .buttonStyle(InstaButtonStyle())
            .frame(width: 40)
            .accessibilityLabel("Notifications")
            .accessibilityValue(watching ? "On" : "Off")
        }
    }

    @ViewBuilder private func archiveButton(_ profile: IGProfile) -> some View {
        if IGPostArchiver.shared.isRunning(profile.handle) {
            Button {} label: { Label(IGPostArchiver.shared.status.isEmpty ? "Archiving" : IGPostArchiver.shared.status, systemImage: "arrow.down.circle") }
                .buttonStyle(InstaButtonStyle())
                .disabled(true)
        } else if let status = archive.progress[profile.handle.lowercased()] {
            Button {} label: { Label(status, systemImage: "arrow.down.circle") }
                .buttonStyle(InstaButtonStyle())
                .disabled(true)
        } else {
            Menu {
                Button { archiveNow(profile) } label: { Label(archive.has(profile.handle) ? "Update stories + visible posts" : "Archive stories + visible posts", systemImage: "archivebox") }
                if IGCredentials.shared.isSignedIn {
                    Button { archiveAllPosts(profile.handle) } label: { Label("Archive all posts + comments (signed in)", systemImage: "square.grid.3x3") }
                }
            } label: {
                Label(archive.has(profile.handle) ? "Update" : "Archive", systemImage: "archivebox")
            }
            .buttonStyle(InstaButtonStyle())
            .disabled(profile.isPrivate)
        }
    }

    private func archiveAllPosts(_ handle: String) {
        Task {
            let summary = await IGPostArchiver.shared.run(handle)
            downloads.show(summary.hasPrefix("Couldn't") || summary.hasPrefix("Add") || summary.contains("wants") ? .failure : .success, summary)
        }
    }

    @ViewBuilder private func statusLines(_ profile: IGProfile) -> some View {
        WatchStatusLine(handle: profile.handle, platform: .instagram) { notifyOpen = true }
        if let account = archive.account(profile.handle) {
            Button { app.openInstagramArchive(profile.handle) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "archivebox.fill")
                        .foregroundStyle(Color.nvInk)
                    Text("Archive: \(plural(account.stories.count, "story", "stories")) and \(plural(account.posts.count, "post", "posts"))")
                        .foregroundStyle(Color.nvInk)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.nvMuted)
                }
                .font(.footnote)
                .padding(.top, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var checkBanner: some View {
        Button { engine.showPage() } label: {
            Label("The site wants a quick check before it shows more. Tap to open it.", systemImage: "checkmark.shield")
                .font(.footnote)
                .foregroundStyle(Color.nvInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.nvCard)
        }
        .buttonStyle(.plain)
    }

    // MARK: Stories and posts

    private var storiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Stories", count: engine.stories?.items.count ?? 0)
            if let tab = engine.stories, !tab.items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tab.items) { item in
                            Button { openStories(at: item.index) } label: {
                                StoryThumb(thumb: item.thumbURL, isVideo: item.isVideo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else if engine.loadingStories || engine.stories == nil {
                ProgressView()
                    .padding(.horizontal, 16)
            } else if let tab = engine.stories {
                tabNote(tab, kind: .stories)
            }
        }
        .padding(.top, 22)
    }

    private var postsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Posts", count: engine.posts?.total ?? 0)
            if let tab = engine.posts, !tab.items.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(tab.items) { item in
                        Button { openPosts(at: item.index) } label: {
                            IGCell(thumb: item.thumbURL, isVideo: item.isVideo)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if tab.items.count < tab.total {
                    morePosts(tab)
                }
            } else if engine.loadingPosts || engine.posts == nil {
                ProgressView()
                    .padding(.horizontal, 16)
            } else if let tab = engine.posts {
                tabNote(tab, kind: .posts)
            }
        }
        .padding(.top, 24)
    }

    @ViewBuilder private func morePosts(_ tab: IGTab) -> some View {
        if engine.loadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        } else if engine.noMorePosts {
            Text("The site lists the newest \(tab.items.count) of \(tab.total) posts.")
                .font(.footnote)
                .foregroundStyle(Color.nvMuted)
                .padding(.horizontal, 16)
                .padding(.top, 10)
        } else {
            Button("Show more posts") { Task { await engine.loadMorePosts() } }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.nvInk)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.nvInk)
            if count > 0 {
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundStyle(Color.nvMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func tabNote(_ tab: IGTab, kind: IGKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(noteText(tab, kind: kind))
                .font(.footnote)
                .foregroundStyle(Color.nvMuted)
            if tab.status == "timeout" || tab.status == "retry" {
                Button("Try again") { Task { await engine.readTab(kind) } }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.nvInk)
            }
        }
        .padding(.horizontal, 16)
    }

    private func noteText(_ tab: IGTab, kind: IGKind) -> String {
        switch tab.status {
        case "empty": return kind == .stories ? "No stories right now." : "No posts yet."
        case "private": return "This account is private."
        case "captcha": return "The site wants a quick check first. Use the banner above."
        case "timeout": return "The site didn't finish loading these."
        case "retry": return "The site couldn't load these right now."
        default: return tab.message.isEmpty ? "Nothing to show." : tab.message
        }
    }

    @ViewBuilder private var menuItems: some View {
        if let link = IGLinks.instagram(handle) {
            Link(destination: link) { Label("Open in Instagram", systemImage: "arrow.up.right.square") }
            ShareLink(item: link) { Label("Share profile link", systemImage: "square.and.arrow.up") }
        }
        if archive.has(handle) {
            Button { app.openInstagramArchive(handle) } label: { Label("View archive", systemImage: "archivebox") }
        }
        Button { engine.showPage() } label: { Label("Show the site's page", systemImage: "safari") }
        Button { Task { await engine.refresh() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
    }

    // MARK: Actions

    private func openStories(at index: Int) {
        guard let items = engine.stories?.items, !items.isEmpty else { return }
        viewer = IGViewerRequest.live(items, handle: handle, stories: true, start: index)
    }

    private func openPosts(at index: Int) {
        guard let items = engine.posts?.items, !items.isEmpty else { return }
        viewer = IGViewerRequest.live(items, handle: handle, stories: false, start: index)
    }

    private func archiveNow(_ profile: IGProfile) {
        Task {
            if engine.posts == nil { await engine.readTab(.posts) }
            let stories = engine.stories?.items ?? []
            let posts = engine.posts?.items ?? []
            if stories.isEmpty && posts.isEmpty {
                downloads.show(.failure, "Nothing to save yet. Pull to refresh, then try again.")
                return
            }
            let saved = await archive.absorb(profile, stories: stories, posts: posts)
            downloads.show(.success, saved > 0 ? "Saved \(saved) to @\(profile.handle)'s archive" : "@\(profile.handle)'s archive is up to date")
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }
}

/// An Instagram archive on this iPhone: every saved post and story, viewable offline.
@MainActor
struct IGArchiveScreen: View {
    let handle: String
    @ObservedObject private var archive = IGArchive.shared
    @ObservedObject private var postArchiver = IGPostArchiver.shared
    @ObservedObject private var creds = IGCredentials.shared
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var viewer: IGViewerRequest? = nil
    @State private var postDetail: IGArchive.Item? = nil
    @State private var showStories = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let account = archive.account(handle) {
                archived(account)
            } else {
                ContentUnavailableView("No archive", systemImage: "archivebox",
                                       description: Text("Open @\(handle) and tap Archive to save its stories and posts."))
            }
        }
        .background(Color.nvPaper.ignoresSafeArea())
        .navigationTitle(handle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { app.openInstagram(handle) } label: { Label("Open live profile", systemImage: "person.crop.circle") }
                    if archive.has(handle) {
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete archive", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .fullScreenCover(item: $viewer) { request in
            IGViewer(request: request)
                .environmentObject(AvatarStore.shared)
                .environmentObject(DownloadCenter.shared)
        }
        .fullScreenCover(item: $postDetail) { item in
            IGPostDetailView(handle: handle, post: item)
                .environmentObject(AvatarStore.shared)
                .environmentObject(DownloadCenter.shared)
        }
        .confirmationDialog("Delete this archive?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete @\(handle)", role: .destructive) { archive.delete(handle) }
        } message: {
            Text("Its saved stories and posts will be removed from this iPhone.")
        }
    }

    private func archived(_ account: IGArchive.Account) -> some View {
        let items = showStories ? account.stories : account.posts
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InstaHeader(header: ProfileHeader(handle: account.handle, name: "", bio: account.bio, avatar: "", stats: account.stats),
                            avatarURL: archive.avatarURL(handle), hasStories: false, onAvatarTap: {}, onStatTap: { _ in })
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                HStack(spacing: 6) {
                    Button { update() } label: {
                        Label(archive.isWorking(handle) ? "Updating stories" : "Update stories", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(InstaButtonStyle())
                    .disabled(archive.isWorking(handle) || postArchiver.isRunning(handle))
                    archivePostsButton
                    Button { app.openInstagram(handle) } label: {
                        Label("Live", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(InstaButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                if postArchiver.isRunning(handle) {
                    archiveProgress
                } else if let status = archive.progress[account.id] {
                    statusText(status)
                } else if !account.note.isEmpty {
                    statusText(account.note)
                }
                if !creds.isSignedIn {
                    Text("Sign in to Instagram in Settings to archive this account's full post history and comments. Stories stay anonymous either way.")
                        .font(.caption)
                        .foregroundStyle(Color.nvMuted)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                } else if account.signedIn {
                    Text("Posts and comments archived while signed in.")
                        .font(.caption)
                        .foregroundStyle(Color.nvMuted)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
                Picker("Show", selection: $showStories) {
                    Text("Posts (\(account.posts.count))").tag(false)
                    Text("Stories (\(account.stories.count))").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)
                if items.isEmpty {
                    Text(showStories ? "No stories saved yet. New ones are added every time this archive updates, so they stay after Instagram removes them."
                                     : "No posts saved yet.")
                        .font(.footnote)
                        .foregroundStyle(Color.nvMuted)
                        .padding(16)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                            Button { showStories ? open(items, at: offset) : (postDetail = item) } label: {
                                IGCell(thumb: thumb(item), isVideo: item.isVideo,
                                       label: showStories ? item.savedAt.formatted(.dateTime.month(.abbreviated).day()) : (item.comments.isEmpty ? "" : "\(item.comments.count) \u{1F4AC}"))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder private var archivePostsButton: some View {
        if postArchiver.isRunning(handle) {
            Button { postArchiver.cancel() } label: { Label("Stop", systemImage: "stop.circle") }
                .buttonStyle(InstaButtonStyle())
        } else {
            Button { archiveAllPosts() } label: {
                Label(creds.isSignedIn ? "Archive posts" : "Posts (sign in)", systemImage: "square.grid.3x3")
            }
            .buttonStyle(InstaButtonStyle())
            .disabled(!creds.isSignedIn || archive.isWorking(handle))
        }
    }

    private var archiveProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(postArchiver.status)
                .font(.footnote)
                .foregroundStyle(Color.nvInk)
            if postArchiver.total > 0 {
                ProgressView(value: Double(postArchiver.done), total: Double(postArchiver.total))
                    .tint(Color.nvSignal)
            } else {
                ProgressView().tint(Color.nvSignal)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func archiveAllPosts() {
        Task {
            let summary = await postArchiver.run(handle)
            downloads.show(summary.hasPrefix("Couldn't") || summary.hasPrefix("Add") || summary.contains("wants") ? .failure : .success, summary)
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.nvMuted)
            .padding(.horizontal, 16)
            .padding(.top, 12)
    }

    private func thumb(_ item: IGArchive.Item) -> URL? {
        item.isVideo ? archive.fileURL(handle, item.cover) : archive.fileURL(handle, item.file)
    }

    private func open(_ items: [IGArchive.Item], at index: Int) {
        viewer = IGViewerRequest.archived(items, handle: handle, stories: showStories, start: index)
    }

    private func update() {
        Task {
            let summary = await archive.update(handle)
            downloads.show(summary.hasPrefix("Couldn't") ? .failure : .success, summary)
        }
    }
}

/// A story thumbnail in a profile's story row.
struct StoryThumb: View {
    let thumb: URL?
    let isVideo: Bool

    var body: some View {
        Color.nvRule.opacity(0.3)
            .frame(width: 86, height: 150)
            .overlay { RemoteImage(thumb, maxPixel: 360) }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.nvSignal, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel(isVideo ? "Video story" : "Photo story")
    }
}

/// A square in an Instagram grid.
struct IGCell: View {
    let thumb: URL?
    let isVideo: Bool
    var label: String = ""

    var body: some View {
        Color.nvRule.opacity(0.3)
            .aspectRatio(1, contentMode: .fit)
            .overlay { RemoteImage(thumb, maxPixel: 400) }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(7)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !label.isEmpty {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isVideo ? "Video" : "Photo")
    }
}

/// An Instagram archive in the home screen's Archived list.
struct IGArchiveRow: View {
    let account: IGArchive.Account
    @ObservedObject private var archive = IGArchive.shared

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(archive.avatarURL(account.handle), maxPixel: 140)
                .frame(width: 42, height: 42)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.nvRule, lineWidth: 1))
                .accessibilityHidden(true)
                .overlay(alignment: .bottomTrailing) {
                    WatchBadge(handle: account.handle, platform: .instagram)
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(account.handle)")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.nvInk)
                    .lineLimit(1)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.nvMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "archivebox")
                .foregroundStyle(Color.nvMuted)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        if let status = archive.progress[account.id] { return status }
        return "Instagram, \(account.stories.count) stories, \(account.posts.count) posts"
    }
}
