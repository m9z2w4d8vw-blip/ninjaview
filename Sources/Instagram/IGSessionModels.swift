import CoreGraphics
import Foundation

/// Whether instagram.com shows us as signed in, at a login form, or at a checkpoint.
struct IGLoginState: Codable {
    let url: String
    let loggedIn: Bool
    let loginForm: Bool
    /// A "was this you" / 2FA / suspended-account screen that a person must clear on the page.
    let challenge: Bool
    let error: String
}

/// One tile on the profile grid.
struct IGGridItem: Codable, Hashable, Identifiable {
    var id: String { code }
    let code: String
    let kind: String
    let thumb: String
    let pinned: Bool
    let multi: Bool
    let video: Bool
    /// From Instagram's own data when the grid saw it (nil or empty when only the page's tile was seen).
    var media: [IGMedia]? = nil
    var caption: String? = nil
    var likes: Int? = nil
    var comments: Int? = nil
    /// When the post was shared, in seconds since 1970 (0 when unknown).
    var taken: Double? = nil

    var thumbURL: URL? { URL.remote(thumb) }
    var slides: [IGMedia] { media ?? [] }
    var takenDate: Date? { (taken ?? 0) > 0 ? Date(timeIntervalSince1970: taken ?? 0) : nil }
}

/// The whole grid after scrolling to the end.
struct IGGrid: Codable {
    let total: Int
    let items: [IGGridItem]
    /// true when every post the profile reports was collected.
    let ended: Bool
    let rounds: Int
    let reason: String
    /// The profile's display name from Instagram's data ("" or nil when it wasn't there).
    var name: String? = nil
}

/// One image or video within a post.
struct IGMedia: Codable, Hashable {
    let image: String
    let video: String
    let alt: String
    /// The original size, when Instagram said (0 or nil when unknown).
    var width: Int? = nil
    var height: Int? = nil

    var isVideo: Bool { !video.isEmpty }
    /// Width over height, or nil when the size isn't known.
    var aspect: CGFloat? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }
    var mediaURL: URL? { URL.remote(isVideo ? video : image) }
    var posterURL: URL? { image.isEmpty ? nil : URL.remote(image) }
}

/// One comment or reply read from a post.
struct IGComment: Codable, Hashable {
    let id: String
    /// The parent comment's id for a reply, "" for a top-level comment.
    let parent: String
    let author: String
    let verified: Bool
    let text: String
    let time: String
    let likes: Int
    let avatar: String
    /// A GIF or sticker comment's image ("" or nil for text comments).
    var image: String? = nil
}

/// Everything read from one open post.
struct IGPostDetail: Codable {
    let code: String
    let author: String
    let caption: String
    let date: String
    let likes: Int
    let media: [IGMedia]
    /// "network" when taken from Instagram's data, "page" when read from the DOM.
    let mediaFrom: String
    let comments: [IGComment]
    let expandRounds: Int
    /// Instagram's own comment count for the post (what its grid shows on hover); 0 when unknown.
    var expected: Int? = nil
    /// Nothing was left to open: no reply thread, no "Load more comments", and scrolling brought nothing.
    var exhausted: Bool? = nil
    /// Nothing was left to open and at least `expected` comments were read.
    var complete: Bool? = nil
    /// Comments whose text on the page differed from Instagram's own data (Instagram's was used).
    var pageTextDiffers: Int? = nil
    /// The first such comment's markup, without classes or image URLs, for the debug log.
    var markupSample: String? = nil

    var foundAll: Bool { complete == true }
}

/// The comments read so far while a post is still opening more.
struct IGCommentProgress: Codable {
    let comments: [IGComment]
    let expected: Int
    let found: Int
}
