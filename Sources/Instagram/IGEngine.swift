import Foundation
import WebKit

/// Drives one hidden insta-stories-viewer.com page for one Instagram account: header,
/// stories and posts, read from the page the site renders.
@MainActor
final class IGEngine: ObservableObject, PageBridgeDelegate {
    enum Phase: Equatable {
        case loading
        case ready
        /// The site is showing a captcha; someone has to solve it on the page itself.
        case needsCheck(String)
        case failed(EngineFailure)
    }

    let handle: String
    let headless: Bool
    let pageURL: URL
    let bridge: PageBridge

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var profile: IGProfile? = nil
    @Published private(set) var stories: IGTab? = nil
    @Published private(set) var posts: IGTab? = nil
    @Published private(set) var loadingStories = false
    @Published private(set) var loadingPosts = false
    @Published private(set) var loadingMore = false
    /// Set when asking the site for more posts added nothing.
    @Published private(set) var noMorePosts = false
    @Published var pageVisible = false

    private var loaded = false
    private var generation = 0

    init(handle: String, headless: Bool = false) {
        self.handle = handle
        self.headless = headless
        pageURL = IGLinks.viewer(handle) ?? IGLinks.home
        bridge = PageBridge(WebFactory.shared.makeInstagramPage(pageURL))
        bridge.delegate = self
        DebugLog.shared.add(.web, "Opening Instagram @\(handle)\(headless ? " out of sight" : "")")
    }

    var isCaptcha: Bool {
        if case .needsCheck = phase { return true }
        return false
    }

    /// Why the last read failed, in plain words ("" when it didn't).
    var problem: String {
        switch phase {
        case .failed(let failure): return "\(failure.title). \(failure.detail)"
        case .needsCheck(let message): return "captcha: \(message)"
        default: return ""
        }
    }

    // MARK: Reading

    /// Header, then stories, then posts; only the first time it's asked.
    func loadAll() async {
        guard !loaded else { return }
        loaded = true
        await readEverything()
    }

    /// Reloads the page and reads everything again (pull to refresh).
    func refresh() async {
        generation += 1
        noMorePosts = false
        bridge.reload(fallback: pageURL)
        await readEverything()
    }

    private func readEverything() async {
        guard let header = await readProfile(), !header.isPrivate else { return }
        await readTab(.stories)
        // Posts from the viewer site are a fallback: only when the setting is on, or when there's
        // no Instagram sign-in to read them properly. Otherwise the signed-in archiver handles posts.
        if AppSettings.shared.viewerPosts || !IGCredentials.shared.isSignedIn {
            await readTab(.posts)
        }
    }

    /// Loads the viewer-site posts tab on demand (when the person taps "Show posts from the viewer").
    func loadViewerPosts() async { await readTab(.posts) }

    /// Waits for the page and reads the header. Returns it when the account is readable
    /// (public or private); otherwise sets `phase` to say why not.
    @discardableResult
    func readProfile(timeout: Double = 25) async -> IGProfile? {
        let gen = generation
        if profile == nil { phase = .loading }
        guard await bridge.waitUntilReady(timeout: 30) else {
            guard gen == generation else { return nil }
            fail("The page didn't load", "insta-stories-viewer.com didn't answer. Check your connection, then pull to refresh.")
            return nil
        }
        do {
            let json = try await bridge.call("return JSON.stringify(await window.__ig.profile(t));",
                                             ["t": Int(timeout * 1000)], timeout: timeout + 10)
            guard gen == generation else { return nil }
            let reply = try bridge.decode(IGProfile.self, json)
            if !reply.handle.isEmpty { profile = reply }
            switch reply.status {
            case "ok", "private":
                phase = .ready
                return reply
            case "captcha":
                phase = .needsCheck(reply.message)
                DebugLog.shared.warn(.web, "Instagram @\(handle): the site is asking for a captcha")
            case "notFound":
                fail("Account not found", "There's no public Instagram account called @\(handle), or the site can't see it.")
            default:
                fail("The page didn't finish loading", reply.message.isEmpty ? "Pull to refresh to try again." : reply.message)
            }
            return nil
        } catch {
            guard gen == generation else { return nil }
            fail("Couldn't read the page", error.localizedDescription)
            return nil
        }
    }

    /// Reads one tab (opening it on the page first) and publishes it.
    @discardableResult
    func readTab(_ kind: IGKind, timeout: Double = 25) async -> IGTab? {
        let gen = generation
        setLoading(kind, true)
        defer { setLoading(kind, false) }
        do {
            let json = try await bridge.call("return JSON.stringify(await window.__ig.tab(k, t));",
                                             ["k": kind.rawValue, "t": Int(timeout * 1000)], timeout: timeout + 10)
            guard gen == generation else { return nil }
            let tab = try bridge.decode(IGTab.self, json)
            switch kind {
            case .stories: stories = tab
            case .posts: posts = tab
            }
            if tab.status == "captcha" { phase = .needsCheck(tab.message) }
            DebugLog.shared.add(.web, "Instagram @\(handle) \(kind.rawValue): \(tab.items.count) (\(tab.status))")
            return tab
        } catch {
            guard gen == generation else { return nil }
            DebugLog.shared.warn(.web, "Instagram @\(handle) \(kind.rawValue) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Asks the site for more posts than its first batch.
    func loadMorePosts() async {
        guard !loadingMore, !noMorePosts, let current = posts, current.items.count < current.total else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let json = try await bridge.call("return JSON.stringify(await window.__ig.more('posts', 4));", [:], timeout: 30)
            let tab = try bridge.decode(IGTab.self, json)
            if tab.items.count > current.items.count {
                posts = tab
            } else {
                noMorePosts = true
                DebugLog.shared.add(.web, "Instagram @\(handle): the site didn't list more than \(current.items.count) posts")
            }
        } catch {
            DebugLog.shared.warn(.web, "Instagram @\(handle) more posts failed: \(error.localizedDescription)")
        }
    }

    // MARK: The page itself (for captchas)

    func showPage() { pageVisible = true }

    /// After the page sheet closes (the person may have solved a captcha), read again.
    func pageClosed() {
        bridge.park()
        Task { await readEverything() }
    }

    func teardown() { bridge.teardown() }

    private func setLoading(_ kind: IGKind, _ on: Bool) {
        switch kind {
        case .stories: loadingStories = on
        case .posts: loadingPosts = on
        }
    }

    private func fail(_ title: String, _ detail: String) {
        phase = .failed(EngineFailure(title: title, detail: detail))
        DebugLog.shared.warn(.web, "Instagram @\(handle): \(title). \(detail)")
    }

    // MARK: PageBridgeDelegate

    func bridgeDidReceive(_ event: [String: Any]) {}

    func bridgeLostContent() {
        Task { await refresh() }
    }

    func bridgeFailedToLoad(_ error: Error) {
        fail("The page didn't load", error.localizedDescription)
    }

    func bridgePresent(_ dialog: JSDialog) {
        dialog.complete(false)
    }
}

/// One Instagram engine per profile screen on the navigation stack.
@MainActor
final class IGRegistry {
    static let shared = IGRegistry()
    private var engines: [UUID: IGEngine] = [:]

    var count: Int { engines.count }

    func engine(for route: Route) -> IGEngine {
        if let existing = engines[route.id] { return existing }
        let engine = IGEngine(handle: route.handle ?? route.query)
        engines[route.id] = engine
        return engine
    }

    func prune(keeping ids: Set<UUID>) {
        for (id, engine) in engines where !ids.contains(id) {
            engine.teardown()
            engines[id] = nil
        }
    }
}

extension WebFactory {
    /// A hidden page on the Instagram viewer site: the shared network logger plus the Instagram
    /// engine, cookies in memory only, ads blocked like the TikTok pages.
    func makeInstagramPage(_ url: URL) -> PreparedWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.applicationNameForUserAgent = Self.safariSuffix
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let router = ScriptRouter()
        let content = WKUserContentController()
        content.add(router, name: "nv")
        // The TikTok page styling stays off; only the network logger matters here.
        let page = WebAssets.PageConfig(clean: false, noAds: false, theme: false, nativeProfiles: false, nativeDownloads: false)
        content.addUserScript(WKUserScript(source: WebAssets.documentStartSource(page), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: IGAssets.engineJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if AppSettings.shared.blockAds, let rules = blockRules { content.add(rules) }
        config.userContentController = content

        let frame = EngineDock.hostWindow?.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844)
        let webView = WKWebView(frame: frame, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = Palette.paper
        webView.scrollView.backgroundColor = Palette.paper
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.isInspectable = true
        EngineDock.park(webView)
        webView.load(URLRequest(url: url))
        return PreparedWebView(webView: webView, router: router)
    }
}
