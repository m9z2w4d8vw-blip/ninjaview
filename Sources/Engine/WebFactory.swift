import UIKit
import WebKit

struct PreparedWebView {
    let webView: WKWebView
    let router: ScriptRouter
    /// The page's name in the debug log ("P3"), given when it's made; PageBridge assigns one if empty.
    var tag: String = ""
    /// When the page was made and began loading, so a preloaded page left waiting too long can be thrown away.
    var madeAt = Date()
}

/// Builds engine pages and keeps one preloaded on tik.ninja so opening a profile skips the cold page load.
///
/// Every tik.ninja page gets its own in-memory website data store, so its own cookies and its own
/// tik.ninja session: one page loading tik.ninja can't replace the session another page is using,
/// which is what caused most "Forbidden" refusals while they all shared one. Cloudflare's own cookies
/// (cf_clearance) are carried into each new page so it doesn't have to pass Cloudflare's check again.
/// Instagram viewer pages share `dataStore`.
@MainActor
final class WebFactory: NSObject {
    static let shared = WebFactory()
    static let homeURL = URL(string: "https://tik.ninja/")!
    /// Appended to WebKit's user agent so tik.ninja sees ordinary Mobile Safari.
    static let safariSuffix = "Version/17.0 Mobile/15E148 Safari/604.1"
    /// A preloaded page left waiting longer than this is thrown away; tik.ninja may have ended its session.
    static let spareLifetime: TimeInterval = 10 * 60

    static var userAgent: String {
        let os = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariSuffix)"
    }

    /// The store Instagram viewer pages share. Cookies and site storage live in memory only and vanish when the app quits.
    private(set) var dataStore: WKWebsiteDataStore = .nonPersistent()
    /// Cloudflare's cookies for tik.ninja, by name, carried into every new tik.ninja page. Never tik.ninja's own session cookie.
    private var cloudflareCookies: [String: HTTPCookie] = [:]
    /// The newest tik.ninja page's store, for the app's own requests that carry tik.ninja cookies.
    private weak var newestTikStore: WKWebsiteDataStore?
    private var ruleList: WKContentRuleList?
    /// The compiled ad block list, for pages built outside this file (Instagram).
    var blockRules: WKContentRuleList? { ruleList }
    private var compileTask: Task<Void, Never>?
    private var spare: PreparedWebView?
    private var spareTask: Task<Void, Never>?
    /// The preloaded page's name in the debug log, while nobody has claimed it.
    var spareTag: String? { spare?.tag }

    /// Where the app's own tik.ninja requests (thumbnails, saved media) take their cookies from.
    var cookieSource: WKWebsiteDataStore { newestTikStore ?? dataStore }

    /// The Cloudflare cookies new pages get, for reports ("cf_clearance", or "none yet").
    var clearanceSummary: String {
        let names = carriedCookies.map(\.name).sorted()
        return names.isEmpty ? "none yet" : names.joined(separator: ", ")
    }

    private var carriedCookies: [HTTPCookie] {
        cloudflareCookies.values.filter { ($0.expiresDate ?? .distantFuture) > Date() }
    }

    func warmUp() {
        compileBlockListIfNeeded()
        scheduleSpare(after: 0.2)
    }

    func dequeue() -> PreparedWebView {
        if let waiting = spare, Date().timeIntervalSince(waiting.madeAt) > Self.spareLifetime {
            DebugLog.shared.add(.web, "[\(waiting.tag) spare] Threw away the preloaded page after it waited \(PageBridge.ago(waiting.madeAt)); tik.ninja may have ended its session")
            discardSpare()
        }
        let prepared = spare ?? make()
        spare = nil
        scheduleSpare(after: 3)
        return prepared
    }

    func settingsChanged() {
        discardSpare()
        scheduleSpare(after: 0.5)
    }

    func clearBrowsingData() async {
        discardSpare()
        cloudflareCookies.removeAll()
        let old = dataStore
        dataStore = .nonPersistent()
        await old.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        var cleared = 0
        for page in PageBridge.openPages {
            let store = page.webView.configuration.websiteDataStore
            guard store !== old, store !== Self.instagramSessionStore else { continue }
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            cleared += 1
        }
        DebugLog.shared.add(.web, "Cleared site data: \(cleared) open pages' own sessions, the Instagram viewer pages' store, and the Cloudflare cookies new pages would get")
        scheduleSpare(after: 0.5)
    }

    // MARK: Sessions

    /// Remembers Cloudflare's cookies from a tik.ninja page that got through, for the pages made after it.
    func harvestCloudflareCookies(from store: WKWebsiteDataStore) {
        Task { @MainActor in
            let cookies = await store.httpCookieStore.allCookies()
            var learned: [String] = []
            for cookie in cookies where Self.isCloudflare(cookie) {
                if cloudflareCookies[cookie.name]?.value != cookie.value { learned.append(cookie.name) }
                cloudflareCookies[cookie.name] = cookie
            }
            if !learned.isEmpty {
                DebugLog.shared.add(.web, "New tik.ninja pages will carry Cloudflare's \(learned.sorted().joined(separator: ", "))")
            }
        }
    }

    /// Clears a page's own cookies except Cloudflare's, so its next load starts a brand-new tik.ninja
    /// session. Returns how many cookies went.
    func clearSession(of webView: WKWebView) async -> Int {
        let store = webView.configuration.websiteDataStore
        guard store !== dataStore, store !== Self.instagramSessionStore else { return 0 }
        let cookies = await store.httpCookieStore.allCookies()
        let kept = cookies.filter { Self.isCloudflare($0) }
        await store.removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
        for cookie in kept { await Self.set(cookie, in: store) }
        return cookies.count - kept.count
    }

    /// cf_clearance, __cf_bm, _cfuvid and the like: Cloudflare's cookies, not tik.ninja's session.
    nonisolated static func isCloudflare(_ cookie: HTTPCookie) -> Bool {
        let name = cookie.name.lowercased()
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (name.hasPrefix("cf_") || name.hasPrefix("__cf") || name.hasPrefix("_cf")) && NetLedger.isTikNinja(domain)
    }

    private static func set(_ cookie: HTTPCookie, in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.setCookie(cookie) { done.resume() }
        }
    }

    private func discardSpare() {
        spareTask?.cancel()
        spareTask = nil
        if let spare {
            spare.webView.stopLoading()
            EngineDock.remove(spare.webView)
        }
        spare = nil
    }
    private func scheduleSpare(after delay: TimeInterval) {
        guard spare == nil, spareTask == nil else { return }
        spareTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.compileTask?.value
            guard !Task.isCancelled else { return }
            if self.spare == nil { self.spare = self.make() }
            self.spareTask = nil
        }
    }
    private func compileBlockListIfNeeded() {
        guard ruleList == nil, compileTask == nil else { return }
        let json = WebAssets.blockListJSON
        compileTask = Task { [weak self] in
            let list = await Self.compile(json)
            self?.ruleList = list
            DebugLog.shared.add(.web, list == nil ? "Ad block list unavailable" : "Ad block list ready")
        }
    }
    private static func compile(_ json: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            let store: WKContentRuleListStore? = WKContentRuleListStore.default()
            guard let store else {
                continuation.resume(returning: nil)
                return
            }
            store.compileContentRuleList(forIdentifier: "ninjaview-blocklist-1", encodedContentRuleList: json) { list, error in
                if let error { print("Block list: \(error)") }
                continuation.resume(returning: list)
            }
        }
    }

    private func make() -> PreparedWebView {
        let settings = AppSettings.shared
        let store = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        // Nobody watches the engine page directly, so it never autoplays anything.
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.applicationNameForUserAgent = Self.safariSuffix
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        // The engine clicks tik.ninja's audio button itself; let that open a window (we intercept it).
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let router = ScriptRouter()
        let content = WKUserContentController()
        content.add(router, name: "nv")
        let page = WebAssets.PageConfig(clean: settings.cleanLayout, noAds: settings.blockAds, theme: settings.cleanLayout,
                                        nativeProfiles: true, nativeDownloads: true, verboseNet: settings.verboseNetLog)
        content.addUserScript(WKUserScript(source: WebAssets.documentStartSource(page), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: WebAssets.engineJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if settings.blockAds, let ruleList { content.add(ruleList) }
        config.userContentController = content

        let frame = EngineDock.hostWindow?.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844)
        let webView = WKWebView(frame: frame, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = Palette.paper
        webView.scrollView.backgroundColor = Palette.paper
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.isInspectable = true
        webView.navigationDelegate = self
        EngineDock.park(webView)
        newestTikStore = store
        let tag = PageTags.next()
        let carried = carriedCookies
        var note = "its own session, ad blocking \(settings.blockAds && ruleList != nil ? "on" : "off")"
        note += carried.isEmpty ? ", no Cloudflare cookies to carry yet" : ", carrying Cloudflare's \(carried.map(\.name).sorted().joined(separator: ", "))"
        if settings.verboseNetLog { note += ", verbose network log" }
        DebugLog.shared.add(.web, "[\(tag) spare] Preloading tik.ninja (\(note))")
        let request = URLRequest(url: Self.homeURL)
        if carried.isEmpty {
            webView.load(request)
        } else {
            // It loads once Cloudflare's cookies are in its jar, so its very first request carries them.
            Task { @MainActor in
                for cookie in carried { await Self.set(cookie, in: store) }
                webView.load(request)
            }
        }
        return PreparedWebView(webView: webView, router: router, tag: tag)
    }
}

/// Navigation rules for a preloaded page nobody has claimed yet.
extension WebFactory: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let subframe = navigationAction.targetFrame.map { !$0.isMainFrame } ?? false
        decisionHandler(subframe || url.scheme == "about" || LinkRules.isTikNinja(url) ? .allow : .cancel)
    }

    /// The preloaded page's own answer: a refusal here (Cloudflare turning it away) is otherwise invisible.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            var source = "spare page"
            if let spare, spare.webView === webView { source = "\(spare.tag) spare" }
            NetLedger.shared.record(source: source, kind: "page", method: "GET", url: http.url, status: http.statusCode, ms: nil,
                                    retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            if http.statusCode >= 400 {
                DebugLog.shared.warn(.web, "[\(source)] Preloading tik.ninja answered \(HTTPDebug.describe(http))")
            }
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let spare, spare.webView === webView else { return }
        EngineDock.remove(webView)
        self.spare = nil
        scheduleSpare(after: 1)
    }
}
