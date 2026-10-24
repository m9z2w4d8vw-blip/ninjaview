import AVFoundation
import Foundation
import SwiftUI

// MARK: - Live grid model

/// A profile's posts read through the signed-in session, and the comments of whichever post is
/// open. One per profile screen. It keeps its hidden instagram.com page for the screen's lifetime,
/// so opening a post doesn't start a new page and sign in again every time.
@MainActor
final class IGLiveGridModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [IGGridItem] = []
    @Published private(set) var total = 0
    /// The display name ("Jayson Wilia"), which the anonymous viewer site doesn't give.
    @Published private(set) var name = ""

    /// Holds the session so `deinit` can close its page (a deinit can't reach main-actor state directly).
    private final class SessionBox { var session: IGSession? }
    private let box = SessionBox()
    /// The page shows one thing at a time: the grid, or one post.
    private let runner = SerialRunner()
    private var postGeneration = 0

    deinit {
        let box = self.box
        Task { @MainActor in
            box.session?.teardown()
            box.session = nil
        }
    }

    private func currentSession() -> IGSession {
        if let s = box.session, !s.bridge.isTornDown { return s }
        let s = IGSession()
        box.session = s
        return s
    }

    func load(_ handle: String) async {
        guard phase == .idle else { return }
        guard IGCredentials.shared.isSignedIn else {
            phase = .failed("Posts come from your Instagram sign-in.")   // the screen adds where to add one
            return
        }
        phase = .loading
        let s = currentSession()
        guard await s.ensureSignedIn() else {
            phase = .failed(Self.signInMessage(s.phase))
            return
        }
        // About 10 seconds without new posts ends the scroll; a first batch usually arrives in 3–5.
        let grid = try? await runner.run { await s.readGrid(handle, maxMinutes: 2, idleRounds: 4) }
        guard let grid else {
            phase = .failed("Couldn't load posts. Try again.")
            return
        }
        items = grid.items
        total = grid.total
        if let found = grid.name, !found.isEmpty { name = found }
        phase = .ready
    }

    /// Pull to refresh: the grid stays on screen while the new one loads.
    func refresh(_ handle: String) async {
        guard IGCredentials.shared.isSignedIn else { return }
        guard phase == .ready else {
            phase = .idle
            await load(handle)
            return
        }
        let s = currentSession()
        guard await s.ensureSignedIn() else { return }
        if let grid = try? await runner.run({ await s.readGrid(handle, maxMinutes: 2, idleRounds: 4) }) {
            items = grid.items
            total = grid.total
            if let found = grid.name, !found.isEmpty { name = found }
        }
    }

    func retry(_ handle: String) async {
        phase = .idle
        items = []
        total = 0
        await load(handle)
    }

    /// One post's comments (and its media, when the grid didn't have them). `expected` is the post's
    /// comment count from the grid; `onProgress` gets the comments read so far while more open. A newer
    /// call, or `cancelPost()`, stops an older one, so switching posts never waits for the last one's comments.
    func loadPost(_ code: String, expected: Int = 0,
                  onProgress: (@MainActor (IGCommentProgress) -> Void)? = nil) async -> IGPostDetail? {
        guard IGCredentials.shared.isSignedIn else { return nil }
        postGeneration += 1
        let mine = postGeneration
        let s = currentSession()
        await s.cancelPost()
        let detail = try? await runner.run { [weak self] () -> IGPostDetail? in
            guard let self, mine == self.postGeneration else { return nil }
            return await s.readPost(code, comments: true, maxMinutes: 4, maxComments: 2000, expected: expected) { [weak self] snap in
                guard let self, mine == self.postGeneration else { return }
                onProgress?(snap)
            }
        }
        guard mine == postGeneration else { return nil }
        return detail
    }

    func cancelPost() {
        postGeneration += 1
        guard let s = box.session else { return }
        Task { await s.cancelPost() }
    }

    private static func signInMessage(_ phase: IGSession.Phase) -> String {
        switch phase {
        case .challenge:
            return "Instagram wants to confirm it's you. Open Settings \u{203A} Instagram sign-in \u{203A} Open Instagram to finish."
        case .loginFailed(let why), .failed(let why):
            return why.isEmpty ? "Couldn't sign in to Instagram." : why
        default:
            return "Couldn't sign in to Instagram."
        }
    }
}

// MARK: - Live post

/// One post the way Instagram shows it: its photos and videos at their real shape (swipe through a
/// carousel), then likes, caption, date, and comments with their replies. Everything except the
/// comments comes from the grid, so the post opens at once; the comments load from its page.
@MainActor
struct IGLivePostSheet: View {
    /// Threads showing every reply; the rest show their first reply and "View All N replies".
    @State private var openThreads: Set<String> = []
    let handle: String
    let item: IGGridItem
    @ObservedObject var model: IGLiveGridModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloads: DownloadCenter
    @StateObject private var player = ClipPlayer()
    @State private var detail: IGPostDetail? = nil
    /// The comments read so far, shown while more are still opening.
    @State private var partial: IGCommentProgress? = nil
    @State private var loadingComments = true
    @State private var page = 0
    @State private var captionExpanded = false

    private var slides: [IGMedia] { item.slides.isEmpty ? (detail?.media ?? []) : item.slides }
    private var caption: String {
        let fromGrid = item.caption ?? ""
        return fromGrid.isEmpty ? (detail?.caption ?? "") : fromGrid
    }
    private var likes: Int { max(item.likes ?? 0, detail?.likes ?? 0) }
    private var date: Date? { item.takenDate ?? IGTime.parse(detail?.date) }
    /// Whichever is longer: the last finished read, or the one still opening (so a retry shows progress too).
    private var comments: [IGComment] {
        let finished = detail?.comments ?? [], soFar = partial?.comments ?? []
        return soFar.count > finished.count ? soFar : finished
    }
    /// Instagram's own count for the post (what its grid shows on hover).
    private var expectedComments: Int { max(item.comments ?? 0, detail?.expected ?? 0, partial?.expected ?? 0) }
    private var current: IGMedia? { slides.indices.contains(page) ? slides[page] : nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    media
                    actions
                    info
                    commentsSection
                }
                .padding(.bottom, 32)
            }
            .background(Color.nvPaper.ignoresSafeArea())
            .navigationTitle("Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await load() }
        .onChange(of: page) { _, _ in syncPlayer() }
        .onDisappear {
            player.stop()
            model.cancelPost()
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(handle: Platform.instagram.key(handle))
                .frame(width: 32, height: 32)
            Text(handle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.nvInk)
            Spacer()
            if item.pinned {
                Label("Pinned", systemImage: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(Color.nvMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Instagram shows a carousel at its first slide's shape. Kept between 9:16 and 1.91:1.
    private var mediaAspect: CGFloat {
        min(1.91, max(9.0 / 16.0, slides.first?.aspect ?? 4.0 / 5.0))
    }

    @ViewBuilder private var media: some View {
        if slides.isEmpty {
            ZStack {
                Color.nvCard
                RemoteImage(item.thumbURL, maxPixel: 1200, mode: .fit, placeholder: .clear)
                ProgressView()
            }
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
        } else {
            TabView(selection: $page) {
                ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                    slideView(slide, index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(mediaAspect, contentMode: .fit)
            .background(Color.black)
            .overlay(alignment: .topTrailing) { counter }
        }
    }

    @ViewBuilder private func slideView(_ slide: IGMedia, index: Int) -> some View {
        ZStack {
            Color.black
            if slide.isVideo {
                RemoteImage(slide.posterURL, maxPixel: 1400, mode: .fit, placeholder: .clear)
                if index == page {
                    PlayerSurface(player: player.player)
                    if !player.isReady { ProgressView().tint(.white) }
                    muteBadge
                }
            } else {
                RemoteImage(slide.mediaURL, maxPixel: 2000, mode: .fit, placeholder: .clear)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if slide.isVideo { player.isMuted.toggle() } }
    }

    @ViewBuilder private var counter: some View {
        if slides.count > 1 {
            Text("\(page + 1)/\(slides.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(10)
                .allowsHitTesting(false)
        }
    }

    private var muteBadge: some View {
        Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Color.black.opacity(0.6), in: Circle())
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(false)
    }

    private var actions: some View {
        HStack(spacing: 20) {
            Spacer(minLength: 0)
            Button { save() } label: { Image(systemName: "arrow.down.to.line") }
                .accessibilityLabel("Save to Photos")
            Button { share() } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
        }
        .font(.system(size: 20))
        .foregroundStyle(Color.nvInk)
        .buttonStyle(.plain)
        .disabled(current?.mediaURL == nil)
        .overlay {
            if slides.count > 1 { PageDots(count: slides.count, index: page) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            if likes > 0 {
                Text(likes == 1 ? "1 like" : "\(likes.formatted()) likes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.nvInk)
            }
            if !caption.isEmpty {
                (Text(handle).fontWeight(.semibold) + Text(" " + caption))
                    .font(.subheadline)
                    .foregroundStyle(Color.nvInk)
                    .lineLimit(captionExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { captionExpanded.toggle() } }
            }
            if let date {
                Text(date.formatted(date: .long, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(Color.nvMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    // MARK: Comments

    private var commentIDs: Set<String> { Set(comments.map(\.id)) }
    /// Top-level comments, plus any reply whose comment isn't in the list (so none go missing).
    private var topLevel: [IGComment] { comments.filter { $0.parent.isEmpty || !commentIDs.contains($0.parent) } }
    private func replies(to id: String) -> [IGComment] { comments.filter { $0.parent == id } }

    @ViewBuilder private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.top, 14)
            HStack(spacing: 6) {
                Text("Comments")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.nvInk)
                if expectedComments > 0 {
                    Text(expectedComments.formatted())
                        .font(.subheadline)
                        .foregroundStyle(Color.nvMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if loadingComments && comments.isEmpty {
                loadingRow
            } else if !loadingComments && detail == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The comments didn't load.")
                        .font(.footnote)
                        .foregroundStyle(Color.nvMuted)
                    Button("Try again") { Task { await loadComments() } }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.nvInk)
                }
                .padding(.horizontal, 14)
            } else if comments.isEmpty {
                Text("No comments.")
                    .font(.footnote)
                    .foregroundStyle(Color.nvMuted)
                    .padding(.horizontal, 14)
            } else {
                ForEach(topLevel, id: \.id) { comment in
                    let thread = replies(to: comment.id)
                    let open = openThreads.contains(comment.id)
                    IGLiveCommentRow(comment: comment, indent: false)
                    ForEach(open ? thread : Array(thread.prefix(1)), id: \.id) { reply in
                        IGLiveCommentRow(comment: reply, indent: true)
                    }
                    if thread.count > 1 {
                        RetroRepliesToggle(title: open ? "Hide replies" : Retro.viewReplies(thread.count),
                                           avatars: open ? [] : thread.prefix(2).map { RetroAvatar.url(URL.remote($0.avatar)) }) {
                            if open { openThreads.remove(comment.id) } else { openThreads.insert(comment.id) }
                        }
                        .padding(.leading, Retro.side + Retro.replyIndent)
                        .padding(.vertical, 6)
                    }
                    RetroHairline(inset: Retro.side + Retro.replyIndent)
                }
                if loadingComments {
                    loadingRow
                } else if let note = shortfallNote {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(Color.nvMuted)
                        Button("Try again") { Task { await loadComments() } }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.nvInk)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                }
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(expectedComments > 0 ? "Loading comments\u{2026} \(comments.count) of \(expectedComments)" : "Loading comments\u{2026}")
                .font(.footnote)
                .foregroundStyle(Color.nvMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Said when fewer comments came back than Instagram counts for the post.
    private var shortfallNote: String? {
        guard let detail, !detail.foundAll, expectedComments > comments.count else { return nil }
        let because = detail.exhausted == true
            ? "Instagram didn't show the rest; some may be hidden or deleted."
            : "Loading stopped before the end."
        return "Showing \(comments.count) of \(expectedComments) comments. " + because
    }

    // MARK: Actions

    private func load() async {
        syncPlayer()
        await loadComments()
    }

    private func loadComments() async {
        loadingComments = true
        partial = nil
        let result = await model.loadPost(item.code, expected: item.comments ?? 0) { snap in partial = snap }
        if let result { detail = result }
        loadingComments = false
        syncPlayer()
    }

    /// Only the slide on screen plays.
    private func syncPlayer() {
        guard let slide = current, slide.isVideo, let url = slide.mediaURL else {
            player.pause()
            return
        }
        player.load(url)
        player.isMuted = false
        player.play()
    }

    private func save() {
        guard let slide = current, let url = slide.mediaURL else { return }
        downloads.fetch(url, kind: slide.isVideo ? .video : .photo, baseName: "instagram-\(handle)-\(item.code)-\(page + 1)")
    }

    private func share() {
        guard let slide = current, let url = slide.mediaURL else { return }
        downloads.share(url, kind: slide.isVideo ? .video : .photo, baseName: "instagram-\(handle)-\(item.code)-\(page + 1)")
    }
}

/// One comment or reply: avatar, name, age, text (or its GIF), and likes.
struct IGLiveCommentRow: View {
    let comment: IGComment
    let indent: Bool

    var body: some View {
        RetroCommentRow(author: comment.author, avatar: .url(URL.remote(comment.avatar)), verified: comment.verified,
                        text: comment.text, age: IGTime.short(comment.time) ?? "", likes: Retro.likes(comment.likes),
                        gif: comment.image.flatMap { URL.remote($0) }, isReply: indent, platform: .instagram)
            .padding(.leading, indent ? Retro.side + Retro.replyIndent : Retro.side)
            .padding(.trailing, Retro.side)
            .padding(.vertical, indent ? 6 : 10)
    }
}

// MARK: - Dates

enum IGTime {
    /// Instagram's timestamps, with or without fractional seconds ("2026-05-26T00:09:05.000Z").
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    /// Instagram's short ages: "now", "5m", "3h", "2d", "20w", "2y".
    static func short(_ string: String) -> String? {
        guard let date = parse(string) else { return nil }
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        case ..<31_536_000: return "\(Int(seconds / 604_800))w"
        default: return "\(Int(seconds / 31_536_000))y"
        }
    }
}
