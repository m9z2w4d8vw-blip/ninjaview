import ImageIO
import SwiftUI
import UIKit
import WebKit

/// Sends the engine page's tik.ninja cookies along, in case images are proxied through the site.
@MainActor
enum CookieBridge {
    static func header(for url: URL) async -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let cookies = await WebFactory.shared.cookieSource.httpCookieStore.allCookies()
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }
        guard !matching.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }
}

/// Thumbnails, avatars and photos. In-memory cache only, nothing written to disk,
/// and no shared cookies.
@MainActor
final class ImagePipeline {
    static let shared = ImagePipeline()

    private let cache = NSCache<NSURL, UIImage>()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    init() { cache.countLimit = 500 }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let hit = cached(url) { return hit }
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url), let image = Self.downsample(data, maxPixel: maxPixel) else { return nil }
            cache.setObject(image, forKey: url as NSURL)
            return image
        }
        var request = URLRequest(url: url)
        if url.scheme?.lowercased().hasPrefix("http") == true {
            request.setValue(WebFactory.userAgent, forHTTPHeaderField: "User-Agent")
            if let referer = LinkRules.referer(for: url) { request.setValue(referer, forHTTPHeaderField: "Referer") }
            if LinkRules.isTikNinja(url), let cookie = await CookieBridge.header(for: url) {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        }
        let began = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            var problem: String? = nil
            if let http, !(200..<300).contains(http.statusCode) {
                var line = "Image answered \(http.statusCode) from \(url.host ?? "?")"
                if LinkRules.isTikNinja(url) {
                    line = "Image \(url.host ?? "?")\(url.path) answered \(HTTPDebug.describe(http))"
                    if HTTPDebug.isTextual(http) { line += "\n  body: " + HTTPDebug.snippet(data, limit: 400) }
                }
                problem = line
            }
            NetLedger.shared.record(source: "app images", kind: "native", method: "GET", url: url, status: http?.statusCode,
                                    ms: PageBridge.ms(since: began), retryAfter: HTTPDebug.retryAfter(response), detail: problem)
            if let problem {
                DebugLog.shared.warn(.image, problem)
                return nil
            }
            guard let image = Self.downsample(data, maxPixel: maxPixel) else {
                DebugLog.shared.warn(.image, "Couldn't decode an image from \(url.host ?? "?") (\(data.count) bytes)")
                return nil
            }
            cache.setObject(image, forKey: url as NSURL)
            return image
        } catch {
            // Cells scrolling away cancel their loads; those aren't failures.
            if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                NetLedger.shared.record(source: "app images", kind: "native", method: "GET", url: url, status: 0,
                                        ms: PageBridge.ms(since: began))
                DebugLog.shared.warn(.image, "Image from \(url.host ?? "?") failed: \(error.localizedDescription)")
            }
            return nil
        }
    }

    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return UIImage(data: data) }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return UIImage(data: data) }
        return UIImage(cgImage: cgImage)
    }
}

@MainActor
struct RemoteImage: View {
    let url: URL?
    let maxPixel: CGFloat
    let mode: ContentMode
    let placeholder: Color
    @State private var image: UIImage?
    @State private var failed = false

    init(_ url: URL?, maxPixel: CGFloat = 480, mode: ContentMode = .fill, placeholder: Color = Color.nvRule.opacity(0.35)) {
        self.url = url
        self.maxPixel = maxPixel
        self.mode = mode
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { ImagePipeline.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            placeholder
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: mode)
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(Color.nvMuted)
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let hit = ImagePipeline.shared.cached(url) {
                image = hit
                return
            }
            let loaded = await ImagePipeline.shared.image(for: url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}
