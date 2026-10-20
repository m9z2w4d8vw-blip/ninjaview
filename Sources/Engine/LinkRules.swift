import Foundation

enum LinkRules {
    static func isTikNinja(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "tik.ninja" || host.hasSuffix(".tik.ninja")
    }

    static func isTikTok(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "tiktok.com" || host.hasSuffix(".tiktok.com")
    }

    private static let mediaHosts = ["tiktokcdn", "ibyteimg", "byteoversea", "muscdn", "tiktokv.", "ttwstatic"]
    private static let mediaExtensions: Set<String> = ["mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "jpg", "jpeg", "png", "webp", "heic", "gif"]

    /// A top-level navigation straight to a media file is a download, not a page.
    static func isMediaFile(_ url: URL) -> Bool {
        if let host = url.host?.lowercased(), mediaHosts.contains(where: { host.contains($0) }) { return true }
        return mediaExtensions.contains(url.pathExtension.lowercased())
    }
}
