import AVFoundation
import Combine
import SwiftUI
import UIKit

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
}

struct ViewerRequest: Identifiable {
    let id = UUID()
    let source: FeedSource
    let index: Int
}

/// State for the full-screen post viewer: which posts are loaded, which one tik.ninja's
/// own viewer has open, and the shared video player. Posts already downloaded (this
/// session or in an archive) play from the phone.
@MainActor
final class FeedModel: ObservableObject {
    let source: FeedSource
    let player = ClipPlayer()

    @Published private(set) var details: [Int: ItemDetail] = [:]
    @Published private(set) var failures: [Int: String] = [:]
    @Published private(set) var loading: Int? = nil
    private(set) var current: Int
    private var wanted: Int? = nil
    private var missingRetries: [Int: Int] = [:]
    private var pausedByUser = false
    /// Which post tik.ninja's own viewer shows right now; comments and audio need it.
    private var openInPage: Int? = nil
    private var savedPosts: [Int: StoredPost] = [:]
    private var engineWatch: AnyCancellable?

    init(request: ViewerRequest) {
        source = request.source
        if case .linked = request.source { current = 0 } else { current = request.index }
        if case .linked(_, let detail) = request.source {
            details[0] = detail
            openInPage = 0
        }
        // Grids grow as the page loads more; pass the engine's changes along.
        if let engine {
            engineWatch = engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    var engine: ProfileEngine? {
        switch source {
        case .live(let engine, _), .linked(let engine, _): return engine
        case .stored: return nil
        }
    }

    var tab: ProfileTab? {
        switch source {
        case .live(_, let tab): return tab
        case .linked: return nil
        case .stored(let feed): return feed.tab
        }
    }

    var handle: String {
        switch source {
        case .live(let engine, _), .linked(let engine, _):
            return engine.header?.handle ?? engine.route.handle ?? "tiktok"
        case .stored(let feed):
            return feed.handle
        }
    }

    var count: Int {
        switch source {
        case .live(let engine, let tab): return engine.tabs[tab]?.items.count ?? 0
        case .linked: return 1
        case .stored(let feed): return feed.entries.count
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
        }
    }

    var baseName: String { "\(handle)_\(tab?.rawValue ?? "post")_\(current + 1)" }

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

    func togglePlayback() {
        if player.isPlaying {
            player.pause()
            pausedByUser = true
        } else {
            player.play()
            pausedByUser = false
        }
    }

    /// Loads the post the user is looking at; if they've moved on meanwhile, loads that one next.
    private func pump() {
        guard loading == nil, let target = wanted, details[target] == nil, failures[target] == nil else { return }
        switch source {
        case .linked:
            return
        case .stored(let feed):
            guard feed.entries.indices.contains(target) else { return }
            let entry = feed.entries[target]
            if let post = feed.store.loadPost(feed.handle, feed.tab, entry.key),
               let detail = LocalLibrary.localDetail(post, store: feed.store, handle: feed.handle, live: false) {
                savedPosts[target] = post
                details[target] = detail
            } else {
                failures[target] = "This post wasn't saved completely. Update the archive to fetch it again."
            }
            syncPlayer()
        case .live(let engine, let tab):
            if let item = item(at: target), let saved = LocalLibrary.find(handle: handle, tab: tab, item: item),
               let detail = LocalLibrary.localDetail(saved.post, store: saved.store, handle: handle, live: true) {
                savedPosts[target] = saved.post
                details[target] = detail
                syncPlayer()
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
                }
                loading = nil
                syncPlayer()
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
        }
    }

    func syncPlayer() {
        guard let detail = details[current], detail.isVideo, let url = detail.videoURL else {
            player.pause()
            return
        }
        player.load(url)
        if !pausedByUser { player.play() }
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

/// Full-screen, vertically paged posts, like TikTok's own player.
@MainActor
struct ItemViewer: View {
    @StateObject private var feed: FeedModel
    @Environment(\.dismiss) private var dismiss
    @State private var position: Int? = nil
    @State private var comments: CommentsRequest? = nil
    @State private var showingPlayer = false
    @State private var didAppear = false
    private let start: Int

    init(request: ViewerRequest) {
        _feed = StateObject(wrappedValue: FeedModel(request: request))
        if case .linked = request.source { start = 0 } else { start = request.index }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<max(feed.count, start + 1), id: \.self) { index in
                            FeedPage(feed: feed,
                                     index: index,
                                     isCurrent: (position ?? start) == index,
                                     onComments: { comments = CommentsRequest(index: index) },
                                     onPlayer: { showingPlayer = true })
                                .frame(width: geo.size.width, height: geo.size.height)
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $position)
                .scrollIndicators(.hidden)
                .onAppear {
                    guard !didAppear else { return }
                    didAppear = true
                    position = start
                    feed.focus(start)
                    Task { @MainActor in proxy.scrollTo(start, anchor: .top) }
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topLeading) { closeButton }
        .overlay { ToastHost() }
        .onChange(of: position) { _, new in
            if let new, new != feed.current { feed.focus(new) }
        }
        .sheet(item: $comments) { request in
            CommentsSheet(feed: feed, index: request.index) { handle in openProfile(handle) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            SystemPlayerScreen(player: feed.player.player)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    private var closeButton: some View {
        Button {
            feed.close()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.4), in: Circle())
        }
        .padding(.leading, 14)
        .padding(.top, 6)
        .accessibilityLabel("Close")
    }

    private func openProfile(_ handle: String) {
        comments = nil
        feed.close()
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            AppModel.shared.open("@" + handle)
        }
    }
}

@MainActor
struct FeedPage: View {
    @ObservedObject var feed: FeedModel
    let index: Int
    let isCurrent: Bool
    let onComments: () -> Void
    let onPlayer: () -> Void
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var photoIndex = 0
    @State private var captionExpanded = false

    var body: some View {
        let detail = feed.details[index]
        ZStack {
            Color.black
            media(detail)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            if let detail {
                infoLayer(detail)
            } else {
                pending
            }
        }
        .clipped()
    }

    private var thumb: URL? { feed.item(at: index)?.thumbURL }

    @ViewBuilder private func media(_ detail: ItemDetail?) -> some View {
        if let detail, detail.isVideo {
            if isCurrent {
                VideoStage(player: feed.player, poster: detail.posterURL ?? thumb, onTap: { feed.togglePlayback() }, onPlayer: onPlayer)
            } else {
                RemoteImage(detail.posterURL ?? thumb, maxPixel: 900, mode: .fit, placeholder: .clear)
            }
        } else if let detail, !detail.photoURLs.isEmpty {
            PhotoCarousel(urls: detail.photoURLs, selection: $photoIndex)
        } else {
            RemoteImage(thumb, maxPixel: 900, mode: .fit, placeholder: .clear)
        }
    }

    @ViewBuilder private var pending: some View {
        if let failure = feed.failures[index] {
            VStack(spacing: 12) {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Button("Try again") { feed.retry(index) }
                    .font(.mono(.footnote, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
            }
            .padding(32)
        } else {
            ProgressView()
                .tint(.white)
                .controlSize(.large)
        }
    }

    private func infoLayer(_ detail: ItemDetail) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    if !detail.caption.isEmpty {
                        Text(detail.caption)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .lineLimit(captionExpanded ? nil : 3)
                            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { captionExpanded.toggle() } }
                    }
                    StatLine(detail: detail)
                    if detail.photoURLs.count > 1 {
                        Text("\(photoIndex + 1) of \(detail.photoURLs.count)")
                            .font(.mono(.caption))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actionRail(detail)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, detail.isVideo ? 62 : 44)
        }
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
    }

    private func actionRail(_ detail: ItemDetail) -> some View {
        VStack(spacing: 16) {
            if detail.hasComments {
                Button(action: onComments) {
                    RailButton(symbol: "bubble.right.fill", label: detail.stat("comments") ?? "")
                }
                .accessibilityLabel("Comments")
            }
            if detail.isVideo, let url = detail.videoURL {
                Button {
                    downloads.fetch(url, kind: .video, baseName: feed.baseName)
                } label: {
                    RailButton(symbol: "arrow.down.to.line", label: "Save")
                }
                .accessibilityLabel("Save video to Photos")
            } else if !detail.photoURLs.isEmpty {
                Menu {
                    Button { savePhoto(detail) } label: { Label("Save this photo", systemImage: "photo") }
                    if detail.photoURLs.count > 1 {
                        Button {
                            downloads.fetchAll(detail.photoURLs, kind: .photo, baseName: feed.baseName)
                        } label: {
                            Label("Save all \(detail.photoURLs.count) photos", systemImage: "photo.stack")
                        }
                    }
                } label: {
                    RailButton(symbol: "arrow.down.to.line", label: "Save")
                }
                .accessibilityLabel("Save photos")
            }
            if detail.hasAudio && feed.engine != nil {
                Button { requestAudio() } label: { RailButton(symbol: "music.note", label: "Audio") }
                    .accessibilityLabel("Save audio")
            }
            if detail.isVideo {
                MuteButton(player: feed.player)
                Button(action: onPlayer) {
                    RailButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Player")
                }
                .accessibilityLabel("Open in the full player")
            }
        }
        .buttonStyle(.plain)
    }

    private func savePhoto(_ detail: ItemDetail) {
        let urls = detail.photoURLs
        guard !urls.isEmpty else { return }
        let i = min(max(photoIndex, 0), urls.count - 1)
        downloads.fetch(urls[i], kind: .photo, baseName: "\(feed.baseName)_\(i + 1)")
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

@MainActor
struct VideoStage: View {
    @ObservedObject var player: ClipPlayer
    let poster: URL?
    let onTap: () -> Void
    let onPlayer: () -> Void

    var body: some View {
        ZStack {
            if !player.isReady {
                RemoteImage(poster, maxPixel: 900, mode: .fit, placeholder: .clear)
            }
            PlayerSurface(player: player.player)
            if let failure = player.failure {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.title2)
                    Text(failure)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Try the full player", action: onPlayer)
                        .font(.mono(.footnote, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(32)
            } else if !player.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 6)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .overlay(alignment: .bottom) {
            ScrubBar(player: player)
                .padding(.horizontal, 12)
                .padding(.bottom, 26)
        }
    }
}

struct ScrubBar: View {
    @ObservedObject var player: ClipPlayer
    @State private var dragFraction: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let fraction = dragFraction ?? player.progress
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white).frame(width: max(0, geo.size.width * fraction))
            }
            .frame(height: dragFraction == nil ? 3 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = min(1, max(0, value.location.x / max(geo.size.width, 1)))
                    }
                    .onEnded { _ in
                        if let fraction = dragFraction { player.seek(to: fraction) }
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(player.progress * 100)) percent")
    }
}

struct PhotoCarousel: View {
    let urls: [URL]
    @Binding var selection: Int

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Array(urls.enumerated()), id: \.offset) { offset, url in
                RemoteImage(url, maxPixel: 1600, mode: .fit, placeholder: .clear)
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .automatic : .never))
    }
}

struct MuteButton: View {
    @ObservedObject var player: ClipPlayer

    var body: some View {
        Button { player.isMuted.toggle() } label: {
            RailButton(symbol: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       label: player.isMuted ? "Muted" : "Sound")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
    }
}

struct RailButton: View {
    let symbol: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 46, height: 38)
            if !label.isEmpty {
                Text(label)
                    .font(.mono(.caption2, weight: .bold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
    }
}

struct StatKind: Hashable {
    let label: String
    let symbol: String
}

struct StatLine: View {
    let detail: ItemDetail

    private static let shown = [
        StatKind(label: "plays", symbol: "play.fill"),
        StatKind(label: "likes", symbol: "heart.fill"),
        StatKind(label: "shares", symbol: "arrowshape.turn.up.right.fill"),
        StatKind(label: "saved", symbol: "bookmark.fill")
    ]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Self.shown, id: \.self) { kind in
                if let value = detail.stat(kind.label), !value.isEmpty {
                    Label(value, systemImage: kind.symbol)
                }
            }
        }
        .font(.mono(.caption, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .labelStyle(CompactLabelStyle())
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
