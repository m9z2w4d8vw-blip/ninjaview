import Foundation

// These mirror the JSON the engine script returns. Every field is always
// present in its replies (the field layout is tested against saved pages).

struct Stat: Codable, Hashable {
    let label: String
    let value: String
}

/// The profile header tik.ninja renders after a lookup.
struct ProfileHeader: Codable, Equatable {
    let handle: String
    let name: String
    let bio: String
    let avatar: String
    let stats: [Stat]

    var key: String { handle.lowercased() }
    var avatarURL: URL? { URL.remote(avatar) }
}

enum ProfileTab: String, CaseIterable, Identifiable {
    case videos, reposts, stories, highlights, followers, following

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var showsUsers: Bool { self == .followers || self == .following }

    var emptyText: String {
        switch self {
        case .videos: return "No public videos."
        case .reposts: return "No public reposts."
        case .stories: return "No stories right now."
        case .highlights: return "No highlights."
        case .followers: return "No followers to show."
        case .following: return "No followed accounts to show."
        }
    }

    init?(statLabel: String) {
        switch statLabel.lowercased() {
        case "followers": self = .followers
        case "following": self = .following
        case "videos", "posts": self = .videos
        default: return nil
        }
    }
}

/// A thumbnail in a video, repost or story grid. `index` is its position in that grid.
struct PostItem: Codable, Identifiable, Hashable {
    let index: Int
    let thumb: String
    let badge: String
    let duration: String
    let date: String
    let plays: String
    let title: String

    var id: Int { index }
    var thumbURL: URL? { URL.remote(thumb) }
    var isPhotos: Bool { badge.lowercased().contains("photo") }
}

struct UserCard: Codable, Identifiable, Hashable {
    let index: Int
    let handle: String
    let nick: String
    let stat: String
    let avatar: String

    var id: String { "\(index)-\(handle)" }
    var avatarURL: URL? { URL.remote(avatar) }
}

/// One opened post: a video, or a photo post with every photo URL collected.
struct ItemDetail: Codable, Equatable {
    let kind: String
    let title: String
    let caption: String
    let stats: [Stat]
    let hasAudio: Bool
    let hasComments: Bool
    let video: String
    let poster: String
    let photos: [String]
    let error: String

    var isVideo: Bool { kind == "video" }
    var videoURL: URL? { URL.remote(video) }
    var posterURL: URL? { URL.remote(poster) }
    var photoURLs: [URL] { photos.compactMap { URL.remote($0) } }

    func stat(_ label: String) -> String? {
        stats.first(where: { $0.label.lowercased() == label.lowercased() })?.value
    }
}

struct CommentItem: Codable, Identifiable, Hashable {
    let index: Int
    let handle: String
    let text: String
    let avatar: String
    let likes: String
    let time: String
    /// "1 reply", "12 replies"; empty when there are none or the thread is open.
    let replyLabel: String
    let repliesOpen: Bool
    let repliesMore: Bool
    let replies: [CommentItem]

    var id: String { "\(index)-\(handle)" }
    var avatarURL: URL? { URL.remote(avatar) }
}

struct CommentsSnapshot: Codable {
    let open: Bool
    let comments: [CommentItem]
    let hasMore: Bool
    let note: String
    let error: String
}

struct AnalyticsSnapshot: Codable {
    let lines: [String]
    let error: String
}

struct AudioReply: Codable {
    let ok: Bool
}

/// A saved or recently viewed profile, kept on device only.
struct SavedProfile: Codable, Identifiable, Hashable {
    var handle: String
    var name: String
    var date: Date
    /// nil for TikTok, which is what every row saved before Instagram support is.
    var platform: Platform? = nil

    var site: Platform { platform ?? .tiktok }
    /// Also the avatar key, so TikTok and Instagram accounts with the same name stay apart.
    var id: String { site.key(handle) }
}

enum TikTokLinks {
    static func profile(_ handle: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.tiktok.com"
        components.path = "/@\(handle)"
        return components.url
    }
}

enum CompactNumber {
    /// "35" -> 35, "1.2K" -> 1200, "2.9M" -> 2_900_000.
    static func parse(_ text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: ",", with: "")
        guard let last = cleaned.last else { return nil }
        let multipliers: [Character: Double] = ["K": 1_000, "M": 1_000_000, "B": 1_000_000_000]
        let multiplier = multipliers[last] ?? 1
        let number = multipliers[last] == nil ? cleaned : String(cleaned.dropLast())
        guard let value = Double(number) else { return nil }
        return Int(value * multiplier)
    }
}

enum Store {
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension URL {
    /// Accepts http(s), data: and file: URLs (downloaded copies); anything else (blob:, empty) is nil.
    static func remote(_ string: String?) -> URL? {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let lower = s.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:") || lower.hasPrefix("file:") else { return nil }
        return URL(string: s)
    }
}

enum EngineError: LocalizedError {
    case timedOut, badReply, torn, page(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: return "tik.ninja took too long to respond."
        case .badReply: return "tik.ninja's page answered in an unexpected way. Check Settings > Debug log."
        case .torn: return "This profile was closed."
        case .page(let code): return EngineError.describe(code)
        }
    }

    var code: String? {
        if case .page(let code) = self { return code }
        return nil
    }

    static func describe(_ code: String) -> String {
        switch code {
        case "missing": return "That post isn't on tik.ninja's page yet."
        case "timeout": return "tik.ninja didn't open this post in time."
        case "unavailable": return "Comments aren't available for this post."
        case "closed": return "The post closed before it finished loading."
        case "noaudio": return "This post has no separate audio to save."
        default: return "tik.ninja reported “\(code)”."
        }
    }
}

struct EngineFailure: Equatable {
    let title: String
    let detail: String
}
