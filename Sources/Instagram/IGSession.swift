import Foundation
import WebKit

/// Drives a signed-in instagram.com page to read posts and comments. Never used for stories or
/// highlights: the injected guard refuses those, and this class never asks for them.
///
/// The page is the real Instagram, so it only runs while the app is open. A full history of a
/// large account is a one-time wait, and Instagram may rate-limit partway; the archiver resumes
/// on the next run.
@MainActor
final class IGSession: ObservableObject, PageBridgeDelegate {
    enum Phase: Equatable {
        case idle
        case loading
        case signedIn
        /// Instagram wants a person: a checkpoint, 2FA, or a suspicious-login screen.
        case challenge
        case loginFailed(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var pageVisible = false

    let bridge: PageBridge
    private var started = false

    /// Story and highlight requests the guard refused, for the debug log.
    private(set) var blockedCount = 0

    init() {
        bridge = PageBridge(WebFactory.shared.makeInstagramSessionPage(IGLinks.instagramHome))
        // Must be set before the main runloop yields so the first navigation decision sees it.
        bridge.allowsInstagram = true
        bridge.delegate = self
    }

    /// Prepares the hidden page to be shown in the verify sheet: makes sure it's loaded and signed
    /// in (so the person lands on whatever check Instagram wants), and re-enables touches.
    func prepareForDisplay() async {
        ensureStarted()
        await ensureSignedIn(timeout: 15)
        bridge.webView.isUserInteractionEnabled = true
        bridge.webView.accessibilityElementsHidden = false
    }

    /// Returns the webview to the off-screen dock and turns touches back off.
    func parkAfterDisplay() {
        bridge.webView.isUserInteractionEnabled = false
        bridge.webView.accessibilityElementsHidden = true
        bridge.park()
    }

    private func ensureStarted() {
        guard !started else { return }
        started = true
        phase = .loading
    }

    // MARK: Sign in

    /// Makes sure we're signed in, signing in with the stored credentials if needed.
    /// Returns true when the page is signed in and ready to read.
    @discardableResult
    func ensureSignedIn(timeout: Double = 40) async -> Bool {
        ensureStarted()
        guard await bridge.waitUntilReady(timeout: 30) else {
            fail("Instagram didn't load. Check your connection and try again.")
            return false
        }
        if let state = await readState() {
            if state.loggedIn { phase = .signedIn; return true }
            if state.challenge { phase = .challenge; return false }
        }
        guard let username = IGCredentials.shared.username, let password = IGCredentials.shared.password() else {
            phase = .loginFailed("Add your Instagram sign-in in Settings first.")
            return false
        }
        // Make sure we're on the login form before typing.
        if await readState()?.loginForm != true {
            bridge.loadURL(URL(string: "https://www.instagram.com/accounts/login/")!)
            _ = await bridge.waitUntilReady(timeout: 30)
        }
        phase = .loading
        DebugLog.shared.add(.web, "Signing in to Instagram as @\(username)")
        do {
            let json = try await bridge.call("return JSON.stringify(await window.__igl.login(u, p, t));",
                                             ["u": username, "p": password, "t": Int(timeout * 1000)],
                                             timeout: timeout + 10,
                                             redacting: ["p"])
            let state = try bridge.decode(IGLoginState.self, json)
            if state.loggedIn { phase = .signedIn; DebugLog.shared.add(.web, "Signed in to Instagram"); return true }
            if state.challenge {
                phase = .challenge
                DebugLog.shared.warn(.web, "Instagram wants a check before signing in")
                return false
            }
            let why = state.error.isEmpty ? "Instagram didn't accept the sign-in. Check the username and password in Settings." : state.error
            phase = .loginFailed(why)
            DebugLog.shared.warn(.web, "Instagram sign-in failed: \(why)")
            return false
        } catch {
            fail("Couldn't sign in: \(error.localizedDescription)")
            return false
        }
    }

    func readState() async -> IGLoginState? {
        guard let json = try? await bridge.call("return JSON.stringify(window.__igl.state());", [:], timeout: 15) else { return nil }
        return try? bridge.decode(IGLoginState.self, json)
    }

    // MARK: Reading

    /// Scrolls the profile grid to the end and returns every post code.
    /// - Parameters:
    ///   - maxMinutes: Total time budget for the grid JS.
    ///   - idleRounds: Rounds of `waitMs` with no new posts before giving up (default 8 = 20 s idle).
    ///     Pass 4 for a live-view load (10 s idle) to return the first API batch faster.
    func readGrid(_ handle: String, maxMinutes: Double = 15, idleRounds: Int = 8) async -> IGGrid? {
        guard await goToProfile(handle) else { return nil }
        do {
            let json = try await bridge.call(
                "return JSON.stringify(await window.__igl.grid({maxMs: m, idleRounds: r, waitMs: 2500}));",
                ["m": Int(maxMinutes * 60_000), "r": idleRounds], timeout: maxMinutes * 60 + 30)
            let grid = try bridge.decode(IGGrid.self, json)
            noteBlocked()
            DebugLog.shared.add(.web, "Instagram @\(handle) grid: \(grid.items.count) of \(grid.total) (\(grid.reason))")
            return grid
        } catch {
            DebugLog.shared.warn(.web, "Instagram @\(handle) grid failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Opens one post by code and reads its media and full comment threads.
    func readPost(_ code: String, comments: Bool = true, maxMinutes: Double = 5, maxComments: Int = 4000, expectedComments: Int = 0) async -> IGPostDetail? {
        guard let url = URL(string: "https://www.instagram.com/p/\(code)/") else { return nil }
        bridge.loadURL(url)
        guard await bridge.waitUntilReady(timeout: 30), !Task.isCancelled else { return nil }
        guard await confirmSignedIn(), !Task.isCancelled else { return nil }
        // A sign-in along the way ends on Instagram's home page; open the post again.
        if !(bridge.webView.url?.path.contains("/\(code)") ?? false) {
            bridge.loadURL(url)
            guard await bridge.waitUntilReady(timeout: 30), !Task.isCancelled else { return nil }
        }
        do {
            let json = try await bridge.call(
                "return JSON.stringify(await window.__igl.post({comments: c, maxComments: n, maxMs: m, expectedComments: e, waitMs: 4500, slideMs: 700, maxRounds: 500}));",
                ["c": comments, "n": maxComments, "m": Int(maxMinutes * 60_000), "e": expectedComments], timeout: maxMinutes * 60 + 30)
            let detail = try bridge.decode(IGPostDetail.self, json)
            noteBlocked()
            return detail
        } catch {
            DebugLog.shared.warn(.web, "Instagram post \(code) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func goToProfile(_ handle: String) async -> Bool {
        guard let url = IGLinks.instagram(handle) else { return false }
        bridge.loadURL(url)
        guard await bridge.waitUntilReady(timeout: 30) else { fail("The profile didn't load."); return false }
        guard await confirmSignedIn() else { return false }
        // A sign-in redirects to instagram.com/ (home), not back to the profile.
        // If we're no longer on the profile page, reload it before running the grid JS.
        let profilePath = "/\(handle.lowercased())"
        if !(bridge.webView.url?.path.lowercased().hasPrefix(profilePath) ?? false) {
            bridge.loadURL(url)
            guard await bridge.waitUntilReady(timeout: 30) else { fail("Profile didn't reload after sign-in."); return false }
        }
        return true
    }

    private func confirmSignedIn() async -> Bool {
        if let state = await readState() {
            if state.loggedIn { phase = .signedIn; return true }
            if state.challenge { phase = .challenge; return false }
        }
        return await ensureSignedIn()
    }

    /// Stops a post read that is still opening comments, so the next one can start right away.
    func cancelPost() async {
        _ = try? await bridge.call("if (window.__igl) window.__igl.cancel(); return 'ok';", [:], timeout: 5)
    }

    func showPage() { pageVisible = true }

    func pageClosed() { bridge.park() }

    func teardown() { bridge.teardown() }

    private func noteBlocked() {
        Task {
            if let count = try? await bridge.call("return String(window.__igl.blocked().length);", [:], timeout: 10),
               let n = Int(count), n != blockedCount {
                blockedCount = n
                DebugLog.shared.add(.web, "Instagram story/highlight guard refused \(n) request(s) this session")
            }
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        DebugLog.shared.warn(.web, "Instagram session: \(message)")
    }

    // MARK: PageBridgeDelegate

    func bridgeDidReceive(_ event: [String: Any]) {
        if (event["type"] as? String) == "blocked", let what = event["what"] as? String {
            DebugLog.shared.add(.web, "Instagram guard blocked: \(what)")
        }
    }

    func bridgeLostContent() {}

    func bridgeFailedToLoad(_ error: Error) {
        fail("Instagram didn't load: \(error.localizedDescription)")
    }

    func bridgePresent(_ dialog: JSDialog) { dialog.complete(false) }
}

extension WebFactory {
    /// The signed-in page asks for Instagram's desktop site: there a post opens with its comments
    /// beside it, and that is the layout the engine reads. The phone site lists a post's comments
    /// on a separate page, so comments never loaded.
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
    /// Wide enough for Instagram's two-column post view. The page sits behind the app, so its size never shows.
    static let desktopPageSize = CGSize(width: 1280, height: 960)

    /// A hidden instagram.com page with the signed-in engine injected at document start, so its
    /// story guard is active before Instagram's own scripts run. Cookies persist (unlike the
    /// anonymous pages) so the sign-in lasts between launches.
    func makeInstagramSessionPage(_ url: URL) -> PreparedWebView {
        let config = WKWebViewConfiguration()
        // A persistent, app-private store: keeps the Instagram session, separate from Safari.
        config.websiteDataStore = Self.instagramSessionStore
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.defaultWebpagePreferences.preferredContentMode = .desktop

        let router = ScriptRouter()
        let content = WKUserContentController()
        content.add(router, name: "igl")
        content.addUserScript(WKUserScript(source: IGSessionAssets.engineJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = content

        let webView = WKWebView(frame: CGRect(origin: .zero, size: Self.desktopPageSize), configuration: config)
        webView.customUserAgent = Self.desktopUserAgent
        webView.isOpaque = false
        webView.backgroundColor = Palette.paper
        webView.scrollView.backgroundColor = Palette.paper
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.isInspectable = true
        EngineDock.park(webView, size: Self.desktopPageSize)
        webView.load(URLRequest(url: url))
        return PreparedWebView(webView: webView, router: router)
    }

    /// One shared persistent store for the Instagram session, created once.
    static let instagramSessionStore: WKWebsiteDataStore = {
        let store = WKWebsiteDataStore.default()
        return store
    }()

    /// Erases all instagram.com cookies and storage from the app-private persistent store.
    /// Call this on sign-out so a later sign-in as a different account starts clean.
    func clearInstagramData() async {
        await Self.instagramSessionStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        DebugLog.shared.add(.web, "Cleared Instagram session data")
    }
}
