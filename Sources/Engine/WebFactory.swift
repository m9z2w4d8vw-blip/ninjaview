import UIKit
import WebKit

struct PreparedWebView {
    let webView: WKWebView
    let router: ScriptRouter
    /// The page's name in the debug log ("P3"), given when it's made; PageBridge assigns one if empty.
    var tag: String = ""
}

/// Builds engine pages that share one in-memory website data store, and keeps
/// one preloaded on tik.ninja so opening a profile skips the cold page load.
@MainActor
final class WebFactory: NSObject {
    static let shared = WebFactory()
    static let homeURL = URL(string: "https://tik.ninja/")!
    /// Appended to WebKit's user agent so tik.ninja sees ordinary Mobile Safari.
    static let safariSuffix = "Version/17.0 Mobile/15E148 Safari/604.1"

    static var userAgent: String {
        let os = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariSuffix)"
    }

    /// Cookies and site storage live in memory only and vanish when the app quits.
    private(set) var dataStore: WKWebsiteDataStore = .nonPersistent()
    private var ruleList: WKContentRuleList?
    /// The compiled ad block list, for pages built outside this file (Instagram).
    var blockRules: WKContentRuleList? { ruleList }
    private var compileTask: Task<Void, Never>?
    private var spare: PreparedWebView?
    private var spareTask: Task<Void, Never>?
    /// The preloaded page's name in the debug log, while nobody has claimed it.
    var spareTag: String? { spare?.tag }

    func warmUp() {
        compileBlockListIfNeeded()
        scheduleSpare(after: 0.2)
    }

    func dequeue() -> PreparedWebView {
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
        let old = dataStore
        dataStore = .nonPersistent()
        await old.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        DebugLog.shared.add(.web, "Cleared site data")
        scheduleSpare(after: 0.5)
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
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
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
        webView.load(URLRequest(url: Self.homeURL))
        let tag = PageTags.next()
        DebugLog.shared.add(.web, "[\(tag) spare] Preloading tik.ninja (ad blocking \(settings.blockAds && ruleList != nil ? "on" : "off")\(settings.verboseNetLog ? ", verbose network log" : ""))")
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
