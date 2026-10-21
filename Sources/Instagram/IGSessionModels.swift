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

/// One square on the profile grid.
struct IGGridItem: Codable, Hashable {
    let code: String
    let kind: String
    let thumb: String
    let pinned: Bool
    let multi: Bool
    let video: Bool
}

/// The whole grid after scrolling to the end.
struct IGGrid: Codable {
    let total: Int
    let items: [IGGridItem]
    /// true when every post the profile reports was collected.
    let ended: Bool
    let rounds: Int
    let reason: String
}

/// One image or video within a post.
struct IGMedia: Codable, Hashable {
    let image: String
    let video: String
    let alt: String

    var isVideo: Bool { !video.isEmpty }
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
}
