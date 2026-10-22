import AVFoundation
import Combine
import SwiftUI
import UIKit

// Posts in the old Instagram style: a scrolling list where each post shows its media at
// full width inside the post, with its actions, caption and comments link below.
// Nothing opens full screen.

struct CommentsRequest: Identifiable {
    let id = UUID()
    let index: Int
}

/// Posts read back from disk: an archive, or this session's downloads.
struct StoredFeed {
    let handle: String
    let store: ProfileStore
    let tab: ProfileTab
    let entries: [StoredEntry]
}

enum FeedSource {
    /// A tab on a live profile, driven through its tik.ninja page.
    case live(ProfileEngine, ProfileTab)
    /// The single post a pasted post link opened.
    case linked(ProfileEngine, ItemDetail)
    /// Saved posts, played from local files.
    case stored(StoredFeed)
    /// An Instagram archive's stories or posts, in the same list.
    case instagram(IGArchiveFeed)
}

/// Post lists pushed onto the navigation stack, closed when their screen leaves it.
@MainActor
final class FeedRegistry {
    static let shared = FeedRegistry()
    private var feeds: [UUID: FeedModel] = [:]
    /// Closed lists, kept briefly so a screen still animating away has something to show.
    private var retired: [UUID: FeedModel] = [:]

    var count: Int { feeds.count }

    func register(_ feed: FeedModel, for id: UUID) { feeds[id] = feed }

    func feed(for id: UUID) -> FeedModel? { feeds[id] ?? retired[id] }

    func prune(keeping ids: Set<UUID>) {
        for (id, feed) in Array(feeds) where !ids.contains(id) {
            feed.close()
            feeds[id] = nil
            retired[id] = feed
        }
        if retired.count > 12 { retired.removeAll() }
    }
}

/// One list of posts: which are loaded, which one tik.ninja's own viewer has open, and the
/// shared video player. Posts already downloaded (this session or archived) play from the phone.
@MainActor
final class FeedModel: ObservableObject {
    /// Videos start muted, as in Instagram's feed; turning sound on carries over to the next list.
    static var prefersMuted = true

    let source: FeedSource
    let start: Int
    let player = ClipPlayer()

    @Published private(set) var details: [Int: ItemDetail] = [:]
    @Published private(set) var failures: [Int: String] = [:]
    @Published private(set) var loading: Int? = nil
    private(set) var current: Int
    private var wanted: Int? = nil
    private var missingRetries: [Int: Int] = [:]
    private var pausedByUser = false
    private var screenHidden = false
    /// Which post tik.ninja's own viewer shows right now; comments and audio need it.
    private var openInPage: Int? = nil
    private var savedPosts: [Int: StoredPost] = [:]
    private var engineWatch: AnyCancellable?

    init(source: FeedSource, start: Int) {
        self.source = source
        let first: Int
        if case .linked = source { first = 0 } else { first = max(0, start) }
        self.start = first
        current = first
        if case .linked(_, let detail) = source {
            details[0] = detail
            openInPage = 0
        }
        player.isMuted = Self.prefersMuted
        // Grids grow as the page loads more; pass the engine's changes along.
        if let engine {
            engineWatch = engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    var engine: ProfileEngine? {
        switch source {
        case .live(let engine, _), .linked(let engine, _): return engine
        case .stored, .instagram: return nil
        }
    }

    /// Which site the posts are from: @mentions and tapped names open profiles there.
    var platform: Platform {
        if case .instagram = source { return .instagram }
        return .tiktok
    }

    var tab: ProfileTab? {
        switch source {
        case .live(_, let tab): return tab
        case .linked: return nil
        case .stored(let feed): return feed.tab
        case .instagram(let feed): return feed.tab
        }
    }

    var handle: String {
        switch source {
        case .live(let engine, _), .linked(let engine, _):
            return engine.header?.handle ?? engine.route.handle ?? "tiktok"
        case .stored(let feed):
            return feed.handle
        case .instagram(let feed):
            return feed.handle
        }
    }

    var title: String {
        switch source {
        case .linked: return "Post"
        case .live(_, let tab): return Self.title(for: tab)
        case .stored(let feed): return Self.title(for: feed.tab)
        case .instagram(let feed): return Self.title(for: feed.tab)
        }
    }

    private static func title(for tab: ProfileTab) -> String {
        switch tab {
        case .reposts: return "Reposts"
        case .stories: return "Stories"
        case .highlights: return "Highlights"
        default: return "Posts"
        }
    }

    /// Shown under the handle on each post.
    var subtitle: String? {
        switch tab {
        case .reposts?: return "Repost"
        case .stories?: return "Story"
        case .highlights?: return "Highlight"
        default: return nil
        }
    }

    var avatarURL: URL? {
        switch source {
        case .live(let engine, _), .linked(let engine, _): return engine.header?.avatarURL
        case .stored(let feed): return feed.store.avatarURL(feed.handle)
        case .instagram(let feed): return IGArchive.shared.avatarURL(feed.handle)
        }
    }

    var count: Int {
        switch source {
        case .live(let engine, let tab): return engine.tabs[tab]?.items.count ?? 0
        case .linked: return 1
        case .stored(let feed): return feed.entries.count
        case .instagram(let feed): return feed.items.count
        }
    }

    func item(at index: Int) -> PostItem? {
        switch source {
        case .live(let engine, let tab):
            guard let items = engine.tabs[tab]?.items, items.indices.contains(index) else { return nil }
            return items[index]
        case .linked:
            return nil
        case .stored(let feed):
            guard feed.entries.indices.contains(index) else { return nil }
            let entry = feed.entries[index]
            guard let thumb = entry.thumbFile else { return entry.item }
            return entry.item.withThumb(feed.store.postFolder(feed.handle, feed.tab, entry.key).appendingPathComponent(thumb).absoluteString)
        case .instagram(let feed):
            return feed.postItem(at: index)
        }
    }

    func baseName(for index: Int) -> String { "\(handle)_\(tab?.rawValue ?? "post")_\(index + 1)" }

    /// The post in the middle of the screen changed.
    func focus(_ index: Int) {
        if index != current { pausedByUser = false }
        current = index
        wanted = index
        syncPlayer()
        pump()
        if case .live(let engine, let tab) = source, index >= count - 3 {
            Task { await engine.loadMore(tab) }
        }
    }

    func retry(_ index: Int) {
        failures[index] = nil
        missingRetries[index] = 0
        wanted = index
        pump()
    }

    func toggleMute() {
        player.isMuted.toggle()
        Self.prefersMuted = player.isMuted
    }

    func togglePlayback() {
        if player.isPlaying {
            player.pause()
            pausedByUser = true
        } else {
            pausedByUser = false
            syncPlayer()
        }
    }

    /// Another screen covered this one (a profile was opened from a comment, say).
    func pausePlayback() {
        screenHidden = true
        player.pause()
    }

    func resumePlayback() {
        screenHidden = false
        syncPlayer()
    }

    /// The carousel slide on screen in each post. Instagram carousels can mix photos and videos.
    private var slides: [Int: Int] = [:]

    func showSlide(_ slide: Int, of index: Int) {
        slides[index] = slide
        if index == current { syncPlayer() }
    }

    /// What plays for the post in the middle: its video, or its carousel slide on screen when that is a video.
    private var playable: URL? {
        guard let detail = details[current] else { return nil }
        if detail.isVideo { return detail.videoURL }
        let urls = detail.photoURLs, slide = slides[current] ?? 0
        guard urls.indices.contains(slide), MediaFiles.isVideoFile(urls[slide]) else { return nil }
        return urls[slide]
    }

    func syncPlayer() {
        guard let url = playable else {
            player.pause()
            return
        }
        player.load(url)
        if screenHidden || pausedByUser { player.pause() } else { player.play() }
    }

    /// The post being looked at first, then the next two, so scrolling down finds them ready.
    private func nextTarget() -> Int? {
        let candidates = [wanted, current + 1, current + 2].compactMap { $0 }
        return candidates.first { $0 >= 0 && $0 < count && details[$0] == nil && failures[$0] == nil }
    }

    private func pump() {
        guard loading == nil, let target = nextTarget() else { return }
        switch source {
        case .linked:
            return
        case .stored(let feed):
            let entry = feed.entries[target]
            if let post = feed.store.loadPost(feed.handle, feed.tab, entry.key),
               let detail = LocalLibrary.localDetail(post, store: feed.store, handle: feed.handle, live: false) {
                savedPosts[target] = post
                details[target] = detail
            } else {
                failures[target] = "This post wasn't saved completely. Update the archive to fetch it again."
            }
            if target == current { syncPlayer() }
            pump()
        case .instagram(let feed):
            if let detail = feed.detail(at: target) {
                details[target] = detail
                savedPosts[target] = feed.storedPost(at: target)
            } else {
                failures[target] = "This post's files aren't on the phone. Update the archive to fetch it again."
            }
            if target == current { syncPlayer() }
            pump()
        case .live(let engine, let tab):
            if let item = item(at: target), let saved = LocalLibrary.find(handle: handle, tab: tab, item: item),
               let detail = LocalLibrary.localDetail(saved.post, store: saved.store, handle: handle, live: true) {
                savedPosts[target] = saved.post
                details[target] = detail
                DebugLog.shared.add(.player, "Post \(target + 1) plays from the saved copy")
                if target == current { syncPlayer() }
                pump()
                return
            }
            loading = target
            Task {
                do {
                    let detail = try await engine.openItem(tab, target)
                    details[target] = detail
                    openInPage = target
                } catch let error as EngineError where error.code == "missing" && (missingRetries[target] ?? 0) < 2 {
                    // Not on tik.ninja's page yet: ask it for more posts, then try again.
                    missingRetries[target, default: 0] += 1
                    await engine.loadMore(tab)
                    loading = nil
                    pump()
                    return
                } catch {
                    failures[target] = error.localizedDescription
                    DebugLog.shared.error(.player, "Post \(target + 1) of @\(handle) didn't load: \(error.localizedDescription)")
                }
                loading = nil
                if target == current { syncPlayer() }
                pump()
            }
        }
    }

    /// The downloaded copy of a post, if there is one (its comments work offline).
    func savedPost(at index: Int) -> StoredPost? {
        if let hit = savedPosts[index] { return hit }
        switch source {
        case .stored(let feed):
            guard feed.entries.indices.contains(index) else { return nil }
            return feed.store.loadPost(feed.handle, feed.tab, feed.entries[index].key)
        case .live(_, let tab):
            guard let item = item(at: index) else { return nil }
            return LocalLibrary.find(handle: handle, tab: tab, item: item)?.post
        case .linked:
            return nil
        case .instagram(let feed):
            return feed.storedPost(at: index)
        }
    }

    /// Makes sure tik.ninja's viewer shows this post before asking it for comments or audio.
    func ensureOpen(_ index: Int) async throws {
        if openInPage == index { return }
        guard case .live(let engine, let tab) = source else { throw EngineError.page("closed") }
        _ = try await engine.openItem(tab, index)
        openInPage = index
    }

    func close() {
        player.stop()
        if let engine { Task { await engine.closeItem() } }
    }
}

/// The pushed list of posts. The post nearest the middle of the screen is the one that plays.
@MainActor
struct PostFeedScreen: View {
    @ObservedObject var feed: FeedModel
    @State private var position: Int? = nil
    @State private var comments: CommentsRequest? = nil
    @State private var didAppear = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<max(feed.count, feed.start + 1), id: \.self) { index in
                        PostCard(feed: feed,
                                 index: index,
                                 isCurrent: (position ?? feed.start) == index,
                                 onComments: { comments = CommentsRequest(index: index) })
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $position, anchor: .center)
            .onAppear {
                if didAppear {
                    feed.resumePlayback()
                    return
                }
                didAppear = true
                position = feed.start
                feed.focus(feed.start)
                Task { @MainActor in proxy.scrollTo(feed.start, anchor: .top) }
            }
        }
        .background(Color.nvPaper.ignoresSafeArea())
        .navigationTitle(feed.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: position) { _, new in
            if let new, new != feed.current { feed.focus(new) }
        }
        .onDisappear { feed.pausePlayback() }
        .sheet(item: $comments) { request in
            CommentsSheet(feed: feed, index: request.index) { handle in openProfile(handle) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func openProfile(_ handle: String) {
        comments = nil
        let platform = feed.platform
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if platform == .instagram {
                AppModel.shared.openInstagram(handle)
            } else {
                _ = AppModel.shared.open("@" + handle)
            }
        }
    }
}

/// One post: header, media at full width, actions, then views, caption and comments.
@MainActor
struct PostCard: View {
    @ObservedObject var feed: FeedModel
    let index: Int
    let isCurrent: Bool
    let onComments: () -> Void
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var photoIndex = 0
    @State private var captionExpanded = false

    var body: some View {
        let detail = feed.details[index]
        let item = feed.item(at: index)
        VStack(alignment: .leading, spacing: 0) {
            header(detail)
            media(detail, item: item)
            if let detail {
                actions(detail)
                info(detail, item: item)
            } else {
                placeholderInfo(item)
            }
        }
        .padding(.bottom, 20)
    }

    private func header(_ detail: ItemDetail?) -> some View {
        HStack(spacing: 10) {
            RemoteImage(feed.avatarURL, maxPixel: 120)
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.nvRule, lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(feed.handle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.nvInk)
                if let subtitle = feed.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.nvMuted)
                }
            }
            Spacer()
            Menu { menuItems(detail) } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.nvInk)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(detail == nil && feed.failures[index] == nil)
            .accessibilityLabel("Post options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func media(_ detail: ItemDetail?, item: PostItem?) -> some View {
        let poster = detail?.posterURL ?? item?.thumbURL
        ZStack {
            if let detail, detail.isVideo {
                Color.black
                if isCurrent {
                    InlineVideo(player: feed.player,
                                poster: poster,
                                fallbackDuration: item?.duration ?? "",
                                onTap: { feed.toggleMute() },
                                onPlayPause: { feed.togglePlayback() })
                } else {
                    RemoteImage(poster, maxPixel: 900, mode: .fit, placeholder: .clear)
                    Image(systemName: "play.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                }
            } else if let detail, !detail.photoURLs.isEmpty {
                Color.nvCard
                PhotoCarousel(urls: detail.photoURLs, selection: $photoIndex, feed: feed, isCurrent: isCurrent)
                if detail.photoURLs.count > 1 {
                    Text("\(photoIndex + 1)/\(detail.photoURLs.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .allowsHitTesting(false)
                }
            } else {
                Color.nvCard
                RemoteImage(poster, maxPixel: 900, mode: .fit, placeholder: .clear)
                pending
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4.0 / 5.0, contentMode: .fit)
        .clipped()
        .onChange(of: photoIndex) { _, slide in feed.showSlide(slide, of: index) }
    }

    @ViewBuilder private var pending: some View {
        if let failure = feed.failures[index] {
            VStack(spacing: 10) {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Color.nvMuted)
                    .multilineTextAlignment(.center)
                Button("Try again") { feed.retry(index) }
                    .buttonStyle(OutlineButtonStyle())
            }
            .padding(20)
            .background(Color.nvPaper.opacity(0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(24)
        } else {
            ProgressView().controlSize(.large)
        }
    }

    private func actions(_ detail: ItemDetail) -> some View {
        HStack(spacing: 18) {
            if detail.hasComments {
                Button(action: onComments) { Image(systemName: "bubble.right") }
                    .accessibilityLabel("Comments")
            }
            Button { share(detail) } label: { Image(systemName: "paperplane") }
                .accessibilityLabel("Share")
            if detail.hasAudio && feed.engine != nil {
                Button { requestAudio() } label: { Image(systemName: "music.note") }
                    .accessibilityLabel("Save audio")
            }
            Spacer()
            Button { save(detail) } label: { Image(systemName: "arrow.down.to.line") }
                .accessibilityLabel(detail.isVideo ? "Save video to Photos" : "Save photos to Photos")
        }
        .font(.system(size: 22))
        .foregroundStyle(Color.nvInk)
        .buttonStyle(.plain)
        .overlay {
            if detail.photoURLs.count > 1 {
                PageDots(count: detail.photoURLs.count, index: photoIndex)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func info(_ detail: ItemDetail, item: PostItem?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let line = statsLine(detail) {
                Text(line)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.nvInk)
            }
            if !detail.caption.isEmpty {
                CaptionText(handle: feed.handle, caption: detail.caption, expanded: $captionExpanded, platform: feed.platform)
            }
            if detail.hasComments {
                Button(action: onComments) {
                    Text(commentsLink(detail))
                        .font(.subheadline)
                        .foregroundStyle(Color.nvMuted)
                }
                .buttonStyle(.plain)
            }
            ForEach(previewComments) { comment in
                (Text(comment.handle).fontWeight(.semibold) + Text(" " + comment.text))
                    .font(.subheadline)
                    .foregroundStyle(Color.nvInk)
                    .lineLimit(2)
            }
            if let date = item?.date, !date.isEmpty {
                Text(date)
                    .font(.caption)
                    .foregroundStyle(Color.nvMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func placeholderInfo(_ item: PostItem?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plays = item?.plays, !plays.isEmpty {
                Text("\(plays) views")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.nvInk)
            }
            if let date = item?.date, !date.isEmpty {
                Text(date)
                    .font(.caption)
                    .foregroundStyle(Color.nvMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    /// The first two comments, when a downloaded copy has them.
    private var previewComments: [CommentItem] {
        Array((feed.savedPost(at: index)?.comments ?? []).prefix(2))
    }

    private func statsLine(_ detail: ItemDetail) -> String? {
        var parts: [String] = []
        if let plays = detail.stat("plays"), !plays.isEmpty { parts.append("\(plays) views") }
        if let likes = detail.stat("likes"), !likes.isEmpty { parts.append("\(likes) likes") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private func commentsLink(_ detail: ItemDetail) -> String {
        guard let count = detail.stat("comments"), !count.isEmpty, count != "0" else { return "View comments" }
        return count == "1" ? "View 1 comment" : "View all \(count) comments"
    }

    @ViewBuilder private func menuItems(_ detail: ItemDetail?) -> some View {
        if let detail {
            if detail.isVideo, let url = detail.videoURL {
                Button { downloads.fetch(url, kind: .video, baseName: feed.baseName(for: index)) } label: {
                    Label("Save video to Photos", systemImage: "arrow.down.to.line")
                }
            }
            if !detail.photoURLs.isEmpty {
                Button { savePhoto(detail) } label: { Label("Save this photo", systemImage: "photo") }
                if detail.photoURLs.count > 1 {
                    Button { downloads.fetchAll(detail.photoURLs, kind: .photo, baseName: feed.baseName(for: index)) } label: {
                        Label("Save all \(detail.photoURLs.count) photos", systemImage: "photo.stack")
                    }
                }
            }
            Button { share(detail) } label: { Label("Share", systemImage: "square.and.arrow.up") }
            if detail.hasAudio && feed.engine != nil {
                Button { requestAudio() } label: { Label("Save audio", systemImage: "music.note") }
            }
            if !detail.caption.isEmpty {
                Button {
                    UIPasteboard.general.string = detail.caption
                    downloads.show(.success, "Caption copied")
                } label: {
                    Label("Copy caption", systemImage: "doc.on.doc")
                }
            }
        } else if feed.failures[index] != nil {
            Button { feed.retry(index) } label: { Label("Try again", systemImage: "arrow.clockwise") }
        }
    }

    private func currentPhoto(_ detail: ItemDetail) -> URL? {
        let urls = detail.photoURLs
        guard !urls.isEmpty else { return nil }
        return urls[min(max(photoIndex, 0), urls.count - 1)]
    }

    private func save(_ detail: ItemDetail) {
        if detail.isVideo, let url = detail.videoURL {
            downloads.fetch(url, kind: .video, baseName: feed.baseName(for: index))
        } else if detail.photoURLs.count > 1 {
            downloads.fetchAll(detail.photoURLs, kind: .photo, baseName: feed.baseName(for: index))
        } else if let url = detail.photoURLs.first {
            downloads.fetch(url, kind: .photo, baseName: feed.baseName(for: index))
        }
    }

    private func savePhoto(_ detail: ItemDetail) {
        guard let url = currentPhoto(detail) else { return }
        downloads.fetch(url, kind: .photo, baseName: "\(feed.baseName(for: index))_\(photoIndex + 1)")
    }

    private func share(_ detail: ItemDetail) {
        let url = detail.isVideo ? detail.videoURL : currentPhoto(detail)
        guard let url else { return }
        downloads.share(url, kind: detail.isVideo ? .video : .photo, baseName: feed.baseName(for: index))
    }

    private func requestAudio() {
        guard let engine = feed.engine else { return }
        let asking = "Asking tik.ninja for the audio…"
        Task {
            downloads.show(.working, asking)
            do {
                try await feed.ensureOpen(index)
                try await engine.requestAudio()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if downloads.toast?.text == asking {
                    downloads.show(.failure, "tik.ninja didn't send the audio. Try again in a moment.")
                }
            } catch {
                downloads.show(.failure, error.localizedDescription)
            }
        }
    }
}

/// The playing video inside a post: tap for sound, with the time left, a mute badge,
/// a pause button and a thin progress line.
@MainActor
struct InlineVideo: View {
    @ObservedObject var player: ClipPlayer
    let poster: URL?
    let fallbackDuration: String
    let onTap: () -> Void
    let onPlayPause: () -> Void

    var body: some View {
        ZStack {
            if !player.isReady {
                RemoteImage(poster, maxPixel: 900, mode: .fit, placeholder: .clear)
            }
            PlayerSurface(player: player.player)
            if let failure = player.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .overlay(alignment: .topTrailing) {
            let label = player.remainingText ?? fallbackDuration
            if !label.isEmpty {
                Text(label)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.black.opacity(0.6), in: Circle())
                .padding(10)
                .allowsHitTesting(false)
                .accessibilityLabel(player.isMuted ? "Muted. Tap the video for sound." : "Sound on")
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: onPlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.black.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        }
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: geo.size.width * player.progress, height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
        }
    }
}

struct PhotoCarousel: View {
    let urls: [URL]
    @Binding var selection: Int
    /// For carousels with video slides (Instagram): the slide on screen in the current post plays.
    var feed: FeedModel? = nil
    var isCurrent = false

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Array(urls.enumerated()), id: \.offset) { offset, url in
                slide(url, offset: offset)
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    @ViewBuilder private func slide(_ url: URL, offset: Int) -> some View {
        if MediaFiles.isVideoFile(url), let feed {
            ZStack {
                Color.black
                if isCurrent && selection == offset {
                    InlineVideo(player: feed.player, poster: nil, fallbackDuration: "",
                                onTap: { feed.toggleMute() }, onPlayPause: { feed.togglePlayback() })
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                }
            }
        } else {
            RemoteImage(url, maxPixel: 1600, mode: .fit, placeholder: .clear)
        }
    }
}

/// Instagram's carousel dots, centred in the action row.
struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(count, 10), id: \.self) { dot in
                Circle()
                    .fill(dot == index ? Color.nvLink : Color.nvRule)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Photo \(index + 1) of \(count)")
    }
}

/// "handle caption", with hashtags and mentions coloured; tapping a mention opens that profile.
struct CaptionText: View {
    let handle: String
    let caption: String
    @Binding var expanded: Bool
    var platform: Platform = .tiktok

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text(handle + " ").fontWeight(.semibold) + Text(Self.attributed(caption, platform: platform)))
                .font(.subheadline)
                .foregroundStyle(Color.nvInk)
                .tint(Color.nvLink)
                .lineLimit(expanded ? nil : 3)
                .environment(\.openURL, OpenURLAction { url in
                    Task { @MainActor in AppModel.shared.handleDeepLink(url) }
                    return .handled
                })
            if !expanded && Self.isLong(caption) {
                Button("more") { withAnimation(.easeOut(duration: 0.2)) { expanded = true } }
                    .font(.subheadline)
                    .foregroundStyle(Color.nvMuted)
                    .buttonStyle(.plain)
            }
        }
    }

    static func attributed(_ caption: String, platform: Platform = .tiktok) -> AttributedString {
        var body = AttributedString(caption)
        let pattern = try? NSRegularExpression(pattern: "[#@][\\p{L}\\p{N}_.]+")
        let whole = NSRange(location: 0, length: (caption as NSString).length)
        for match in pattern?.matches(in: caption, range: whole) ?? [] {
            guard let stringRange = Range(match.range, in: caption),
                  let range = Range(stringRange, in: body) else { continue }
            body[range].foregroundColor = Color.nvLink
            let token = String(caption[stringRange])
            let name = String(token.dropFirst())
            let link = platform == .instagram ? "ninjaview://instagram/" + name : "ninjaview://" + token
            if token.hasPrefix("@"), TikTokTarget.isHandle(name), let url = URL(string: link) {
                body[range].link = url
            }
        }
        return body
    }

    static func isLong(_ caption: String) -> Bool {
        caption.count > 140 || caption.filter { $0 == "\n" }.count >= 3
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10, weight: .bold))
            configuration.title
        }
    }
}
