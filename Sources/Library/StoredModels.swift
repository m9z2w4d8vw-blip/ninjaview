import CryptoKit
import Foundation

/// How far a download goes: generous, but bounded so one huge account can't fill the phone.
enum CrawlLimits {
    static let sessionPostsPerTab = 300
    static let archivePostsPerTab = 5000
    static let commentsPerPost = 400
    /// Reply threads opened per post in an archive.
    static let threadsPerPost = 150
    /// Reply threads opened per post in the temporary copy made when a profile opens.
    static let sessionThreadsPerPost = 60
    /// "View more replies" presses per thread.
    static let replyRounds = 10
    /// Between reply requests, so a post with many threads doesn't trip tik.ninja's rate limit.
    static let replyPause: UInt64 = 700_000_000
    static let usersPerList = 2000
    /// A short pause between posts, to go easy on tik.ninja.
    static let pause: UInt64 = 350_000_000
}

/// One downloaded post: its grid info, details, local files and comments.
struct StoredPost: Codable {
    var key: String
    var tab: String
    var item: PostItem
    var detail: ItemDetail?
    var thumbFile: String?
    var videoFile: String?
    var photoFiles: [String]
    var comments: [CommentItem]
    var commentsNote: String
    var savedAt: Date
    /// Reply threads that wouldn't open when this was saved (nil for posts saved before this was counted).
    var repliesMissing: Int? = nil
    /// Comments the site counts that weren't saved (Instagram archives; nil when none or unknown).
    var commentsMissing: Int? = nil
}

extension StoredPost {
    var replyCount: Int { comments.reduce(0) { $0 + $1.replies.count } }

    /// Comments that say they have replies but have none saved.
    var unopenedThreads: Int { comments.filter { !$0.replyLabel.isEmpty && $0.replies.isEmpty }.count }

    /// Whether an archive update should open this post again for its replies.
    var needsReplies: Bool {
        if let missing = repliesMissing { return missing > 0 }
        return unopenedThreads > 0
    }
}

/// A post's place in a saved grid, in the order the profile showed it.
struct StoredEntry: Codable, Hashable {
    var key: String
    var item: PostItem
    var thumbFile: String?
    var complete: Bool
}

/// A downloaded profile. Each post lives in its own folder; this is the index.
struct StoredProfile: Codable, Identifiable {
    enum Status: String, Codable {
        case working, paused, complete, failed
    }

    var handle: String
    var header: ProfileHeader?
    var avatarFile: String?
    var analytics: [String]
    var tabs: [String: [StoredEntry]]
    var userCounts: [String: Int]
    var status: Status
    var note: String
    var createdAt: Date
    var updatedAt: Date
    var bytes: Int64

    var id: String { handle.lowercased() }

    func entries(_ tab: ProfileTab) -> [StoredEntry] { tabs[tab.rawValue] ?? [] }

    var savedPostCount: Int {
        tabs.values.reduce(0) { total, entries in total + entries.filter(\.complete).count }
    }
}

/// tik.ninja's page gives posts no id, so a post is known by its cover image's path,
/// which stays the same from one visit to the next.
enum StableKey {
    static func keys(for items: [PostItem], tab: ProfileTab) -> [String] {
        var seen: [String: Int] = [:]
        return items.map { item in
            let base = of(item, tab: tab)
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            return n == 1 ? base : "\(base)-\(n)"
        }
    }

    static func of(_ item: PostItem, tab: ProfileTab) -> String {
        var basis = ""
        if let url = item.thumbURL, url.scheme?.lowercased().hasPrefix("http") == true,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            basis = components.path
            // A proxied image (one path for every post) is told apart by its query instead.
            if LinkRules.isTikNinja(url) || components.path.count < 16 { basis += "?" + (components.query ?? "") }
        }
        if basis.isEmpty {
            basis = [item.date, item.duration, item.plays, item.badge, item.title, String(item.index)].joined(separator: "|")
        }
        let digest = SHA256.hash(data: Data((tab.rawValue + basis).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

struct LocalPost {
    let post: StoredPost
    let store: ProfileStore
}

/// Finds downloaded copies of posts: archives first, then this session's cache.
@MainActor
enum LocalLibrary {
    static func find(handle: String, tab: ProfileTab, item: PostItem) -> LocalPost? {
        let key = StableKey.of(item, tab: tab)
        for store in [ProfileStore.archive, ProfileStore.session] {
            if let post = store.loadPost(handle, tab, key), post.detail != nil {
                return LocalPost(post: post, store: store)
            }
        }
        return nil
    }

    /// The saved detail with its media pointed at local files. Live viewing falls back to the
    /// original URLs for anything missing; archive viewing sticks to what's on the phone.
    static func localDetail(_ post: StoredPost, store: ProfileStore, handle: String, live: Bool) -> ItemDetail? {
        guard let detail = post.detail, let tab = ProfileTab(rawValue: post.tab) else { return nil }
        let folder = store.postFolder(handle, tab, post.key)
        func local(_ name: String) -> String { folder.appendingPathComponent(name).absoluteString }
        let video = post.videoFile.map(local) ?? (live ? detail.video : "")
        let photos = post.photoFiles.isEmpty ? (live ? detail.photos : []) : post.photoFiles.map(local)
        let poster = post.thumbFile.map(local) ?? (live ? detail.poster : "")
        let hasComments = live ? (detail.hasComments || !post.comments.isEmpty) : !post.comments.isEmpty
        return ItemDetail(kind: detail.kind, title: detail.title, caption: detail.caption, stats: detail.stats,
                          hasAudio: live && detail.hasAudio, hasComments: hasComments,
                          video: video, poster: poster, photos: photos, error: "")
    }
}

extension PostItem {
    func withThumb(_ thumb: String) -> PostItem {
        PostItem(index: index, thumb: thumb, badge: badge, duration: duration, date: date, plays: plays, title: title)
    }

    func withIndex(_ index: Int) -> PostItem {
        PostItem(index: index, thumb: thumb, badge: badge, duration: duration, date: date, plays: plays, title: title)
    }
}
