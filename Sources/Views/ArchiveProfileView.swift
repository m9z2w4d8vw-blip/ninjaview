import SwiftUI
import UIKit

/// An archived profile, read entirely from the phone, in the same layout as a live one.
@MainActor
struct ArchiveProfileView: View {
    let handle: String
    @ObservedObject private var store = ProfileStore.archive
    @ObservedObject private var center = CrawlCenter.shared
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var tab: ProfileTab = .videos
    @State private var panel: ProfilePanel? = nil
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let profile = store.profile(handle) {
                content(profile)
            } else {
                ContentUnavailableView("Archive removed", systemImage: "archivebox",
                                       description: Text("This archive was deleted from the phone."))
            }
        }
        .background(Color.nvPaper.ignoresSafeArea())
        .navigationTitle(handle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $panel) { which in
            switch which {
            case .followers:
                UserListSheet(title: "Followers", users: store.loadUsers(handle, .followers), isLoading: false,
                              note: "This list wasn't saved in the archive.", onOpen: { other in openLive(other) })
            case .following:
                UserListSheet(title: "Following", users: store.loadUsers(handle, .following), isLoading: false,
                              note: "This list wasn't saved in the archive.", onOpen: { other in openLive(other) })
            case .analytics:
                AnalyticsSheet(lines: store.profile(handle)?.analytics ?? [], isLoading: false)
            }
        }
        .confirmationDialog("Delete this archive?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete archive", role: .destructive) { center.deleteArchive(handle) }
        } message: {
            Text("Its videos, photos and comments will be removed from this iPhone.")
        }
    }

    private func content(_ profile: StoredProfile) -> some View {
        let header = profile.header ?? ProfileHeader(handle: profile.handle, name: "", bio: "", avatar: "", stats: [])
        let stories = items(profile, .stories)
        let highlights = items(profile, .highlights)
        let crawl = center.find(handle, .archive)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                InstaHeader(header: header, avatarURL: store.avatarURL(handle), hasStories: !stories.isEmpty,
                            onAvatarTap: { open(profile, .stories, 0) },
                            onStatTap: { tapped in panel = tapped == .followers ? ProfilePanel.followers : ProfilePanel.following })
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                buttons(profile, crawl: crawl)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                statusLine(profile, crawl: crawl)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                if !highlights.isEmpty {
                    HighlightsRow(items: highlights) { open(profile, .highlights, $0) }
                        .padding(.top, 16)
                }
                Section {
                    let posts = items(profile, tab)
                    if posts.isEmpty {
                        Text(tab == .stories ? "No stories were saved." : "No posts saved yet.")
                            .font(.footnote)
                            .foregroundStyle(Color.nvMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 44)
                    } else {
                        SquareGrid(items: posts, onTap: { open(profile, tab, $0) })
                    }
                } header: {
                    InstaTabBar(tabs: [.videos, .stories], selected: tab) { tab = $0 }
                        .padding(.top, 14)
                        .background(Color.nvPaper)
                }
            }
        }
    }

    private func buttons(_ profile: StoredProfile, crawl: Crawl?) -> some View {
        HStack(spacing: 6) {
            if let crawl {
                CrawlAware(crawl: crawl) { live in
                    if live.isActive {
                        Button { center.pause(live) } label: { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(InstaButtonStyle())
                    } else {
                        updateButton(profile)
                    }
                }
            } else {
                updateButton(profile)
            }
            Button { showInFiles() } label: { Label("Files", systemImage: "folder") }
                .buttonStyle(InstaButtonStyle())
            Menu {
                Button { Task { await export() } } label: { Label("Export as .zip", systemImage: "doc.zipper") }
                Button { panel = .analytics } label: { Label("Account analytics", systemImage: "chart.bar") }
                    .disabled(profile.analytics.isEmpty)
                Button { openLive(handle) } label: { Label("Open live profile", systemImage: "person.crop.circle") }
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete archive", systemImage: "trash") }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.nvInk)
                    .frame(width: 34, height: 34)
                    .background(Color.nvCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel("More")
        }
    }

    private func updateButton(_ profile: StoredProfile) -> some View {
        Button { center.archive(handle) } label: {
            Label(profile.status == .complete ? "Update archive" : "Resume", systemImage: "arrow.clockwise")
        }
        .buttonStyle(InstaButtonStyle())
    }

    @ViewBuilder private func statusLine(_ profile: StoredProfile, crawl: Crawl?) -> some View {
        if let crawl {
            CrawlAware(crawl: crawl) { live in
                if live.isActive {
                    CrawlStatusLine(crawl: live)
                } else {
                    summary(profile)
                }
            }
        } else {
            summary(profile)
        }
    }

    private func summary(_ profile: StoredProfile) -> some View {
        var parts = ["\(profile.savedPostCount) posts saved"]
        if profile.bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: profile.bytes, countStyle: .file)) }
        var line = parts.joined(separator: ", ") + ". Updated \(profile.updatedAt.formatted(.relative(presentation: .named)))."
        switch profile.status {
        case .paused, .working:
            line += " Paused before it finished."
        case .failed:
            line += profile.note.isEmpty ? " The last update didn't finish." : " The last update stopped: \(profile.note)"
        case .complete:
            break
        }
        return Text(line)
            .font(.caption)
            .foregroundStyle(Color.nvMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Saved grid entries as posts with local cover images, numbered by position.
    private func items(_ profile: StoredProfile, _ tab: ProfileTab) -> [PostItem] {
        profile.entries(tab).enumerated().map { position, entry in
            let item = entry.item.withIndex(position)
            guard let thumb = entry.thumbFile else { return item }
            return item.withThumb(store.postFolder(handle, tab, entry.key).appendingPathComponent(thumb).absoluteString)
        }
    }

    private func open(_ profile: StoredProfile, _ tab: ProfileTab, _ index: Int) {
        let entries = profile.entries(tab)
        guard entries.indices.contains(index) else { return }
        let feed = StoredFeed(handle: handle, store: store, tab: tab, entries: entries)
        app.openPosts(.stored(feed), index: index)
    }

    private func openLive(_ other: String) {
        panel = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            _ = app.open("@" + other)
        }
    }

    /// Opens the Files app at this archive's folder.
    private func showInFiles() {
        let path = store.folder(handle).path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        if let url = URL(string: "shareddocuments://" + encoded) {
            UIApplication.shared.open(url)
        }
    }

    private func export() async {
        downloads.show(.working, "Preparing the .zip…")
        if let zip = await ArchiveExporter.zip(store.folder(handle), name: "NinjaView-\(handle)") {
            downloads.show(.success, "Archive ready")
            ShareSheet.present(zip)
        } else {
            downloads.show(.failure, "Couldn't make the .zip.")
        }
    }
}

/// An archive on the home screen.
struct ArchiveRow: View {
    let profile: StoredProfile
    let avatarURL: URL?
    let crawl: Crawl?

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(avatarURL, maxPixel: 140)
                .frame(width: 42, height: 42)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.nvRule, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.nvInk)
                    .lineLimit(1)
                if let crawl {
                    CrawlAware(crawl: crawl) { live in detailText(live) }
                } else {
                    detailText(nil)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "archivebox")
                .foregroundStyle(Color.nvMuted)
        }
        .contentShape(Rectangle())
    }

    private var title: String {
        if let name = profile.header?.name, !name.isEmpty { return name }
        return "@\(profile.handle)"
    }

    private func detailText(_ crawl: Crawl?) -> some View {
        Text(detail(crawl))
            .font(.footnote)
            .foregroundStyle(Color.nvMuted)
            .lineLimit(1)
    }

    private func detail(_ crawl: Crawl?) -> String {
        if let crawl, crawl.isActive {
            return crawl.postsTotal > 0 ? "Archiving, \(crawl.postsDone) of \(crawl.postsTotal) posts" : "Archiving"
        }
        var parts = ["@\(profile.handle)", "\(profile.savedPostCount) posts"]
        if profile.bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: profile.bytes, countStyle: .file)) }
        switch profile.status {
        case .paused, .working: parts.append("paused")
        case .failed: parts.append("needs an update")
        case .complete: break
        }
        return parts.joined(separator: ", ")
    }
}
