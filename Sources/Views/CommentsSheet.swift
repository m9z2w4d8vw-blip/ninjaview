import SwiftUI

/// Comments for one post, read from tik.ninja's comments panel.
@MainActor
final class CommentsModel: ObservableObject {
    private let feed: FeedModel
    let index: Int
    /// The post's comment count as tik.ninja shows it ("35", "1.2K").
    let countLabel: String?
    private let expectedTotal: Int?
    /// Comments come from a downloaded copy instead of tik.ninja's page.
    let offline: Bool

    @Published private(set) var comments: [CommentItem] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isLoadingMore = false
    @Published private(set) var note = ""
    /// Under a saved post's comments when some reply threads didn't load.
    @Published private(set) var footnote = ""
    @Published private(set) var error: String? = nil
    @Published private(set) var expanded: Set<Int> = []
    @Published private(set) var loadingReplies: Set<Int> = []
    private var exhausted = false
    private var started = false
    /// "1 reply" labels, remembered because tik.ninja swaps them for "Hide replies" once opened.
    private var replyLabels: [Int: String] = [:]

    init(feed: FeedModel, index: Int) {
        self.feed = feed
        self.index = index
        let label = feed.details[index]?.stat("comments")
        countLabel = label
        expectedTotal = label.flatMap { CompactNumber.parse($0) }
        let saved = feed.savedPost(at: index)
        let useSaved = saved.map { !$0.comments.isEmpty || feed.engine == nil } ?? (feed.engine == nil)
        offline = useSaved
        if useSaved {
            comments = saved?.comments ?? []
            note = saved?.commentsNote ?? ""
            if let missing = saved?.repliesMissing, missing > 0 {
                footnote = "Replies to \(missing) \(missing == 1 ? "comment" : "comments") didn't load when this was saved. Updating the archive tries them again."
            } else if let missing = saved?.commentsMissing, missing > 0 {
                footnote = "\(missing) \(missing == 1 ? "comment" : "comments") didn't load when this was saved. Updating the archive tries again."
            }
            isLoading = false
            exhausted = true
            started = true
        }
    }

    /// The post's caption and who posted it, shown first the way Instagram did.
    var caption: String? { feed.details[index]?.caption }
    var author: String { feed.handle }
    var authorAvatar: URL? { feed.avatarURL }
    var platform: Platform { feed.platform }
    var postAge: String { feed.item(at: index)?.date ?? "" }

    func start() async {
        guard !started else { return }
        started = true
        isLoading = true
        error = nil
        do {
            guard let engine = feed.engine else { throw EngineError.page("closed") }
            try await feed.ensureOpen(index)
            apply(try await engine.openComments(), previous: nil)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func retry() async {
        started = false
        await start()
    }

    func loadMoreIfNeeded(after comment: CommentItem) async {
        guard comment.index >= comments.count - 3, !exhausted, !isLoadingMore, !isLoading,
              let engine = feed.engine else { return }
        isLoadingMore = true
        let before = comments.count
        do {
            apply(try await engine.moreComments(), previous: before)
        } catch {
            exhausted = true
        }
        isLoadingMore = false
    }

    private func apply(_ snap: CommentsSnapshot, previous: Int?) {
        for comment in snap.comments where !comment.replyLabel.isEmpty {
            replyLabels[comment.index] = comment.replyLabel
        }
        comments = snap.comments
        note = ProfileEngine.tidy(snap.note)
        for comment in snap.comments where comment.repliesOpen && !comment.replies.isEmpty {
            expanded.insert(comment.index)
        }
        let count = snap.comments.count
        if count == 0 {
            exhausted = true
        } else if let previous, count <= previous, !snap.hasMore {
            exhausted = true
        } else if let expectedTotal, loadedCount >= expectedTotal, !snap.hasMore {
            exhausted = true
        }
    }

    private var loadedCount: Int {
        comments.reduce(comments.count) { $0 + $1.replies.count }
    }

    func replyLabel(for comment: CommentItem) -> String? {
        if offline {
            guard !comment.replies.isEmpty else { return nil }
            return comment.replies.count == 1 ? "1 reply" : "\(comment.replies.count) replies"
        }
        let label = comment.replyLabel.isEmpty ? (replyLabels[comment.index] ?? "") : comment.replyLabel
        if !label.isEmpty { return label }
        if comment.replies.isEmpty { return nil }
        return comment.replies.count == 1 ? "1 reply" : "\(comment.replies.count) replies"
    }

    func toggleReplies(_ comment: CommentItem) async {
        if expanded.contains(comment.index) {
            expanded.remove(comment.index)
            return
        }
        if !comment.replies.isEmpty || offline {
            expanded.insert(comment.index)
            return
        }
        guard let engine = feed.engine else { return }
        loadingReplies.insert(comment.index)
        defer { loadingReplies.remove(comment.index) }
        do {
            replace(try await engine.replies(comment.index))
            expanded.insert(comment.index)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func moreReplies(_ comment: CommentItem) async {
        guard !offline, let engine = feed.engine else { return }
        loadingReplies.insert(comment.index)
        defer { loadingReplies.remove(comment.index) }
        do {
            replace(try await engine.moreReplies(comment.index))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func replace(_ updated: CommentItem) {
        guard let i = comments.firstIndex(where: { $0.index == updated.index }) else { return }
        comments[i] = updated
    }
}

/// A post's comments, laid out like Instagram's comments screen of 2016–2017 (see RetroComments).
@MainActor
struct CommentsSheet: View {
    @StateObject private var model: CommentsModel
    private let onOpenProfile: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(feed: FeedModel, index: Int, onOpenProfile: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: CommentsModel(feed: feed, index: index))
        self.onOpenProfile = onOpenProfile
    }

    var body: some View {
        RetroCommentsScreen(onBack: { dismiss() }) {
            if let caption = model.caption, !caption.isEmpty {
                RetroCommentRow(author: model.author, avatar: .url(model.authorAvatar), text: caption, age: model.postAge,
                                isCaption: true, platform: model.platform, onOpenProfile: onOpenProfile)
                    .padding(.horizontal, Retro.side)
                    .padding(.vertical, 12)
                RetroHairline()
            }
            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if model.comments.isEmpty {
                VStack(spacing: 12) {
                    Text(model.error ?? (model.note.isEmpty ? "No comments yet." : model.note))
                        .font(.footnote)
                        .foregroundStyle(Retro.gray)
                        .multilineTextAlignment(.center)
                    if model.error != nil {
                        Button("Try again") { Task { await model.retry() } }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(32)
            } else {
                ForEach(model.comments) { comment in
                    CommentThread(comment: comment, model: model, onOpenProfile: onOpenProfile)
                        .onAppear { Task { await model.loadMoreIfNeeded(after: comment) } }
                    RetroHairline(inset: Retro.side + Retro.replyIndent)
                }
                if model.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                if let error = model.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Retro.gray)
                        .padding(.horizontal, Retro.side)
                        .padding(.vertical, 8)
                }
                if !model.footnote.isEmpty {
                    Text(model.footnote)
                        .font(.footnote)
                        .foregroundStyle(Retro.gray)
                        .padding(.horizontal, Retro.side)
                        .padding(.vertical, 12)
                }
            }
        }
        .task { await model.start() }
    }
}

/// One comment and its replies. tik.ninja sends replies only when asked, so "View All N replies"
/// comes right under the comment, and the replies appear above it once opened.
@MainActor
struct CommentThread: View {
    let comment: CommentItem
    @ObservedObject var model: CommentsModel
    let onOpenProfile: (String) -> Void

    var body: some View {
        let open = model.expanded.contains(comment.index)
        VStack(alignment: .leading, spacing: 0) {
            RetroCommentRow(author: comment.handle, avatar: .url(comment.avatarURL), text: comment.text, age: comment.time,
                            likes: Retro.likes(comment.likes), platform: model.platform, onOpenProfile: onOpenProfile)
            if open {
                ForEach(comment.replies) { reply in
                    RetroCommentRow(author: reply.handle, avatar: .url(reply.avatarURL), text: reply.text, age: reply.time,
                                    likes: Retro.likes(reply.likes), isReply: true, platform: model.platform, onOpenProfile: onOpenProfile)
                        .padding(.leading, Retro.replyIndent)
                        .padding(.top, 14)
                }
            }
            if let label = model.replyLabel(for: comment) {
                RetroRepliesToggle(title: open ? "Hide replies" : Retro.viewReplies(label),
                                   avatars: open ? [] : comment.replies.prefix(2).map { RetroAvatar.url($0.avatarURL) },
                                   loading: model.loadingReplies.contains(comment.index)) {
                    Task { await model.toggleReplies(comment) }
                }
                .padding(.leading, Retro.replyIndent)
                .padding(.top, 12)
            }
            if open && comment.repliesMore {
                RetroRepliesToggle(title: "View more replies", loading: model.loadingReplies.contains(comment.index)) {
                    Task { await model.moreReplies(comment) }
                }
                .padding(.leading, Retro.replyIndent)
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, Retro.side)
        .padding(.vertical, 12)
    }
}
