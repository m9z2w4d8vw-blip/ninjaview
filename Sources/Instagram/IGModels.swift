import Foundation

/// Which site a profile comes from.
enum Platform: String, Codable, CaseIterable, Identifiable {
    case tiktok, instagram

    var id: String { rawValue }
    var title: String { self == .tiktok ? "TikTok" : "Instagram" }

    /// Storage key for a handle. Instagram keys get a prefix (a character neither site allows in
    /// usernames), so a TikTok and an Instagram account with the same name never share avatars,
    /// saved rows or watch entries. TikTok keys stay exactly as they were.
    func key(_ handle: String) -> String {
        let bare = handle.lowercased()
        return self == .instagram ? "ig~" + bare : bare
    }
}

/// Which tab of an Instagram profile.
enum IGKind: String {
    case stories, posts
}

/// The header the engine reads from insta-stories-viewer.com.
struct IGProfile: Codable, Equatable {
    let handle: String
    let bio: String
    let avatar: String
    let verified: Bool
    let stats: [Stat]
    let storiesCount: Int
    let status: String
    let message: String

    var avatarURL: URL? { URL.remote(avatar) }
    var isPrivate: Bool { status == "private" }
    /// The shared header model, so the Instagram screen can reuse the profile header view.
    var header: ProfileHeader { ProfileHeader(handle: handle, name: "", bio: bio, avatar: avatar, stats: stats) }
}

/// One story or post as the engine reports it.
struct IGItem: Codable, Hashable, Identifiable {
    /// Stable across page loads: the Instagram media id for stories, the file name for posts.
    let key: String
    let kind: String
    let index: Int
    let media: String
    let url: String
    let thumb: String
    let filename: String
    /// The site's own id for the item (changes between loads for posts).
    let siteID: String

    var id: String { key }
    var isVideo: Bool { media == "video" }
    var isStory: Bool { kind == "story" }
    var mediaURL: URL? { URL.remote(url) }
    var thumbURL: URL? { URL.remote(thumb) }

    private enum CodingKeys: String, CodingKey {
        case key, kind, index, media, url, thumb, filename, siteID = "id"
    }
}

/// A tab's contents plus why it's empty, when it is.
struct IGTab: Codable {
    let kind: String
    /// ok, empty, private, notFound, retry, captcha, timeout or missing.
    let status: String
    let items: [IGItem]
    let message: String
    /// For posts: how many the account has in total (the site lists the newest ones).
    let total: Int

    /// Only these results can be compared with what was seen before.
    var isClean: Bool { status == "ok" || status == "empty" }
}

enum IGTarget {
    /// A bare username, @username, or an instagram.com profile or story link. The viewer site
    /// works by username, so links to single posts and reels return nil.
    static func parse(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if isInstagramLink(text), let url = URL(string: text.contains("://") ? text : "https://" + text) {
            let parts = url.path.split(separator: "/").map(String.init)
            guard let first = parts.first?.lowercased() else { return nil }
            let reserved: Set<String> = ["p", "reel", "reels", "tv", "explore", "accounts", "direct", "about", "developer", "legal", "web"]
            if first == "stories", parts.count > 1 {
                text = parts[1]
            } else if reserved.contains(first) {
                return nil
            } else {
                text = parts[0]
            }
        }
        if text.hasPrefix("@") { text.removeFirst() }
        text = text.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._")
        guard (1...30).contains(text.count), text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return text
    }

    static func isInstagramLink(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return false }
        // Reject lookalikes such as instagram.com.attacker.example.
        return host == "instagram.com" || host.hasSuffix(".instagram.com") ||
               host == "instagr.am" || host.hasSuffix(".instagr.am")
    }
}

enum IGLinks {
    static let home = URL(string: "https://insta-stories-viewer.com/")!

    static func viewer(_ handle: String) -> URL? { URL(string: "https://insta-stories-viewer.com/\(handle.lowercased())/") }
    static func instagram(_ handle: String) -> URL? { URL(string: "https://www.instagram.com/\(handle.lowercased())/") }
    static let instagramHome = URL(string: "https://www.instagram.com/")!
    static func isViewer(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "insta-stories-viewer.com" || host.hasSuffix(".insta-stories-viewer.com")
    }
}

extension LinkRules {
    /// The viewer site's media server answers requests that come from the site's own pages.
    static func referer(for url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        return host.contains("iqsaved") || host.hasSuffix("insta-stories-viewer.com") ? "https://insta-stories-viewer.com/" : nil
    }
}
