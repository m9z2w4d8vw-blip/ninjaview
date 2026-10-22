import Foundation

/// An Instagram archive's stories or posts, shown in the same post list and comments sheet as a TikTok
/// archive. Each saved item becomes the post, grid tile and saved comments those screens already draw.
struct IGArchiveFeed {
    let handle: String
    let stories: Bool
    let items: [IGArchive.Item]

    var tab: ProfileTab { stories ? .stories : .videos }

    @MainActor private func url(_ name: String) -> URL? { IGArchive.shared.fileURL(handle, name) }

    /// A carousel, or anything that isn't a lone video, shows the photo-post badge on the grid.
    private func showsAsPhotos(_ item: IGArchive.Item) -> Bool {
        item.files.count > 1 || !(item.isVideo || MediaFiles.isVideoFile(name: item.file))
    }

    @MainActor func postItem(at index: Int) -> PostItem? {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        let still = item.cover.isEmpty ? item.file : (MediaFiles.isVideoFile(name: item.file) ? item.cover : item.file)
        return PostItem(index: index, thumb: url(still)?.absoluteString ?? "", badge: showsAsPhotos(item) ? "Photo" : "",
                        duration: "", date: Self.dateLine(item, story: stories), plays: "", title: "")
    }

    @MainActor func postItems() -> [PostItem] { items.indices.compactMap { postItem(at: $0) } }

    /// The post as the list shows it: a lone video plays; anything else is a swipeable carousel, whose
    /// video slides play when they're on screen.
    @MainActor func detail(at index: Int) -> ItemDetail? {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        let files = item.files.isEmpty ? [item.file] : item.files
        let urls = files.compactMap { url($0) }
        guard !urls.isEmpty else { return nil }
        var stats: [Stat] = []
        if item.likes > 0 { stats.append(Stat(label: "likes", value: item.likes.formatted())) }
        let commentTotal = max(item.commentCount, item.comments.count)
        if commentTotal > 0 { stats.append(Stat(label: "comments", value: commentTotal.formatted())) }
        let loneVideo = urls.count == 1 && (item.isVideo || MediaFiles.isVideoFile(urls[0]))
        return ItemDetail(kind: loneVideo ? "video" : "photos", title: "", caption: item.caption, stats: stats,
                          hasAudio: false, hasComments: !item.comments.isEmpty,
                          video: loneVideo ? urls[0].absoluteString : "",
                          poster: url(item.cover)?.absoluteString ?? "",
                          photos: loneVideo ? [] : urls.map(\.absoluteString), error: "")
    }

    /// The saved comments, threaded the way the comments sheet expects, plus how many Instagram counts
    /// that aren't saved (shown under the comments).
    @MainActor func storedPost(at index: Int) -> StoredPost? {
        guard let detail = detail(at: index), let post = postItem(at: index) else { return nil }
        let item = items[index]
        let missing = item.commentsComplete ? 0 : item.commentsMissing
        return StoredPost(key: item.key, tab: tab.rawValue, item: post, detail: detail, thumbFile: nil, videoFile: nil,
                          photoFiles: [], comments: Self.commentItems(item.comments), commentsNote: "", savedAt: item.savedAt,
                          repliesMissing: nil, commentsMissing: missing > 0 ? missing : nil)
    }

    static func commentItems(_ saved: [IGArchive.StoredComment]) -> [CommentItem] {
        let ids = Set(saved.map(\.id))
        // Replies sit under their comment; a reply whose comment wasn't saved shows on its own.
        let tops = saved.filter { $0.parent.isEmpty || !ids.contains($0.parent) }
        return tops.enumerated().map { offset, comment in
            let replies = saved.filter { $0.parent == comment.id }.enumerated().map { i, reply in
                commentItem(reply, index: i, replies: [])
            }
            return commentItem(comment, index: offset, replies: replies)
        }
    }

    private static func commentItem(_ c: IGArchive.StoredComment, index: Int, replies: [CommentItem]) -> CommentItem {
        let label = replies.isEmpty ? "" : (replies.count == 1 ? "1 reply" : "\(replies.count) replies")
        return CommentItem(index: index, handle: c.author, text: c.text.isEmpty ? "GIF" : c.text, avatar: "",
                           likes: c.likes > 0 ? c.likes.formatted() : "", time: IGTime.ago(c.time),
                           replyLabel: label, repliesOpen: false, repliesMore: false, replies: replies)
    }

    /// The line under a post: when it was shared, or for a story when it was saved (within one check of
    /// when it went up).
    private static func dateLine(_ item: IGArchive.Item, story: Bool) -> String {
        let when = story ? item.savedAt : (IGTime.parse(item.takenAt) ?? item.savedAt)
        return IGTime.relative(when)
    }
}

extension IGTime {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()

    /// "18 hours ago", "1 day ago", "3 weeks ago".
    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// A comment's age the way the comments sheet shows it: "10h ago".
    static func ago(_ iso: String) -> String {
        guard let age = short(iso) else { return "" }
        return age == "now" ? "now" : age + " ago"
    }
}
