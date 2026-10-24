import SwiftUI

/// Parses an ISO 8601 date string, accepting both the plain variant and Instagram's
/// fractional-seconds form (e.g. "2024-01-15T12:34:56.000Z").
private func parseISO8601(_ string: String) -> Date? {
    let f = ISO8601DateFormatter()
    for options: ISO8601DateFormatter.Options in [
        [.withInternetDateTime, .withFractionalSeconds],
        [.withInternetDateTime]
    ] {
        f.formatOptions = options
        if let date = f.date(from: string) { return date }
    }
    return nil
}

/// One archived post, full-screen: swipe through its photos and videos, read the caption, and
/// open its saved comments and replies. Used from an Instagram archive's Posts grid.
@MainActor
struct IGPostDetailView: View {
    let handle: String
    let post: IGArchive.Item
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloads: DownloadCenter
    @StateObject private var player = ClipPlayer()
    @State private var index = 0
    @State private var commentsOpen = false

    private var files: [String] { post.files.isEmpty ? [post.file] : post.files }
    private var currentFile: String { files.indices.contains(index) ? files[index] : post.file }
    /// Decided per slide from its file: a carousel can mix photos and videos.
    private var isVideoAt: Bool {
        let ext = (currentFile as NSString).pathExtension.lowercased()
        return ext == "mp4" || ext == "mov" || (files.count == 1 && post.isVideo)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            media
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if files.count > 1 { PageDotsRow(count: files.count, index: index).padding(.bottom, 8) }
                bottomBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .statusBarHidden()
        .task(id: index) { await loadCurrent() }
        .onDisappear { player.stop() }
        .fullScreenCover(isPresented: $commentsOpen) {
            IGCommentsSheet(handle: handle, post: post)
        }
    }

    @ViewBuilder private var media: some View {
        let url = IGArchive.shared.fileURL(handle, currentFile)
        Group {
            if isVideoAt {
                ZStack {
                    if !player.isReady, let cover = IGArchive.shared.fileURL(handle, post.cover) {
                        RemoteImage(cover, maxPixel: 1400, mode: .fit, placeholder: .black)
                    }
                    PlayerSurface(player: player.player)
                    if !player.isReady { ProgressView().tint(.white) }
                }
            } else {
                RemoteImage(url, maxPixel: 2200, mode: .fit, placeholder: .black)
            }
        }
        // On videos too, so a carousel's video slide can be swiped past.
        .contentShape(Rectangle())
        .highPriorityGesture(dragBetweenImages)
    }

    private var dragBetweenImages: some Gesture {
        DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < -40, index + 1 < files.count { index += 1 }
            else if value.translation.width > 40, index > 0 { index -= 1 }
            else if value.translation.height > 110 { dismiss() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            AvatarView(handle: Platform.instagram.key(handle))
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(handle).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                if !post.takenAt.isEmpty, let when = parseISO8601(post.takenAt) {
                    Text(when.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                }
            }
            Spacer(minLength: 8)
            if files.count > 1 {
                Text("\(index + 1) of \(files.count)").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
        .shadow(color: .black.opacity(0.4), radius: 3)
    }

    private var bottomBar: some View {
        HStack(spacing: 20) {
            if post.likes > 0 {
                Label("\(post.likes)", systemImage: "heart.fill").foregroundStyle(.white)
            }
            Button { commentsOpen = true } label: {
                Label("\(post.comments.count)", systemImage: "bubble.right")
            }
            .disabled(post.comments.isEmpty)
            Spacer(minLength: 0)
            Button { save() } label: { Image(systemName: "arrow.down.to.line") }
                .accessibilityLabel("Save to Photos")
            Button { share() } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
        }
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 3)
        .buttonStyle(.plain)
        .frame(height: 44)
    }

    private func loadCurrent() async {
        guard isVideoAt, let url = IGArchive.shared.fileURL(handle, currentFile) else { player.stop(); return }
        player.load(url)
        player.isMuted = false
        player.play()
    }

    private func save() {
        guard let url = IGArchive.shared.fileURL(handle, currentFile) else { return }
        downloads.fetch(url, kind: isVideoAt ? .video : .photo, baseName: "instagram-\(handle)")
    }

    private func share() {
        guard let url = IGArchive.shared.fileURL(handle, currentFile) else { return }
        downloads.share(url, kind: isVideoAt ? .video : .photo, baseName: "instagram-\(handle)")
    }
}

private struct PageDotsRow: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(Color.white.opacity(i == index ? 1 : 0.4)).frame(width: 6, height: 6)
            }
        }
    }
}

/// An archived post's saved comments, laid out like Instagram's comments screen of 2016–2017: the caption
/// first, then each comment with its first reply and "View All N replies" for the rest.
struct IGCommentsSheet: View {
    let handle: String
    let post: IGArchive.Item
    @Environment(\.dismiss) private var dismiss
    @State private var openThreads: Set<String> = []

    private var topLevel: [IGArchive.StoredComment] { post.comments.filter { $0.parent.isEmpty } }
    private func replies(to id: String) -> [IGArchive.StoredComment] { post.comments.filter { $0.parent == id } }

    var body: some View {
        RetroCommentsScreen(onBack: { dismiss() }) {
            if !post.caption.isEmpty {
                RetroCommentRow(author: handle, avatar: .stored(Platform.instagram.key(handle)), text: post.caption,
                                age: IGTime.short(post.takenAt) ?? "", isCaption: true, platform: .instagram)
                    .padding(.horizontal, Retro.side)
                    .padding(.vertical, 12)
                RetroHairline()
            }
            if post.comments.isEmpty {
                Text("No comments saved.")
                    .font(.footnote)
                    .foregroundStyle(Retro.gray)
                    .frame(maxWidth: .infinity)
                    .padding(32)
            }
            ForEach(topLevel, id: \.id) { comment in
                let thread = replies(to: comment.id)
                let open = openThreads.contains(comment.id)
                VStack(alignment: .leading, spacing: 0) {
                    row(comment, isReply: false)
                    ForEach(open ? thread : Array(thread.prefix(1)), id: \.id) { reply in
                        row(reply, isReply: true)
                            .padding(.leading, Retro.replyIndent)
                            .padding(.top, 14)
                    }
                    if thread.count > 1 {
                        RetroRepliesToggle(title: open ? "Hide replies" : Retro.viewReplies(thread.count),
                                           avatars: open ? [] : thread.prefix(2).map { RetroAvatar.stored(Platform.instagram.key($0.author)) }) {
                            if open { openThreads.remove(comment.id) } else { openThreads.insert(comment.id) }
                        }
                        .padding(.leading, Retro.replyIndent)
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, Retro.side)
                .padding(.vertical, 12)
                RetroHairline(inset: Retro.side + Retro.replyIndent)
            }
        }
    }

    private func row(_ comment: IGArchive.StoredComment, isReply: Bool) -> RetroCommentRow {
        RetroCommentRow(author: comment.author, avatar: .stored(Platform.instagram.key(comment.author)), verified: comment.verified,
                        text: comment.text, age: IGTime.short(comment.time) ?? "", likes: Retro.likes(comment.likes),
                        isReply: isReply, platform: .instagram)
    }
}
