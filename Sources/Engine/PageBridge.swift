import UIKit
import WebKit

/// A JavaScript alert or confirm from the page. WebKit requires its completion
/// handler to run exactly once, so it fires on dismissal or, failing that, on deinit.
final class JSDialog: Identifiable {
    enum Kind { case alert, confirm }

    let id = UUID()
    let kind: Kind
    let message: String
    private var handler: ((Bool) -> Void)?

    init(kind: Kind, message: String, handler: @escaping (Bool) -> Void) {
        self.kind = kind
        self.message = message
        self.handler = handler
    }

    func complete(_ result: Bool) {
        handler?(result)
        handler = nil
    }

    deinit { handler?(false) }
}

/// Resumes a continuation once, whichever of the reply or the timeout comes first.
final class ResumeOnce<T> {
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(returning value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
protocol PageBridgeDelegate: AnyObject {
    func bridgeDidReceive(_ event: [String: Any])
    func bridgeLostContent()
    func bridgeFailedToLoad(_ error: Error)
    func bridgePresent(_ dialog: JSDialog)
}

/// Owns one off-screen tik.ninja page: its web view, script messages, navigation
/// rules, and the async call channel into the engine script.
@MainActor
final class PageBridge: NSObject {
    let webView: WKWebView
    private let router: ScriptRouter
    weak var delegate: PageBridgeDelegate?
    private(set) var isReady = false
    private(set) var isTornDown = false
    /// Set to true for the signed-in Instagram session page so top-level navigations to
    /// instagram.com are allowed. Must be set before the first runloop yield after init().
    var allowsInstagram = false
    private var navigationStart: Date?

    init(_ prepared: PreparedWebView) {
        webView = prepared.webView
        router = prepared.router
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        router.target = self
    }

    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isReady {
            if isTornDown || Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    /// Runs an async function body in the page and logs what it did and how long it took.
    /// Engine calls always return a JSON string.
    /// `redacting` is a set of argument keys whose values are replaced with *** in the debug log.
    func call(_ body: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 45, redacting: Set<String> = []) async throws -> String {
        let name = Self.callName(body)
        let started = Date()
        do {
            let json = try await rawCall(body, arguments, timeout: timeout)
            DebugLog.shared.add(.web, "\(name)(\(Self.describe(arguments, redacting: redacting))) took \(Self.ms(since: started)) ms, \(json.utf8.count) bytes back")
            return json
        } catch {
            DebugLog.shared.error(.web, "\(name)(\(Self.describe(arguments, redacting: redacting))) failed after \(Self.ms(since: started)) ms: \(error.localizedDescription)")
            throw error
        }
    }

    nonisolated static func callName(_ body: String) -> String {
        guard let range = body.range(of: #"__nv\.[A-Za-z]+"#, options: .regularExpression) else { return "script" }
        return String(body[range].dropFirst(5))
    }

    nonisolated static func describe(_ arguments: [String: Any], redacting: Set<String> = []) -> String {
        arguments.keys.sorted().map { key in
            if redacting.contains(key) { return "\(key)=***" }
            let value = String(describing: arguments[key] ?? "")
            return "\(key)=\(value.count > 80 ? String(value.prefix(80)) + "\u{2026}" : value)"
        }.joined(separator: ", ")
    }

    nonisolated static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    private func rawCall(_ body: String, _ arguments: [String: Any], timeout: TimeInterval) async throws -> String {
        guard !isTornDown else { throw EngineError.torn }
        let webView = self.webView
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let once = ResumeOnce(continuation)
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    if let json = value as? String {
                        once.resume(returning: json)
                    } else {
                        once.resume(throwing: EngineError.badReply)
                    }
                case .failure(let error):
                    if let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String {
                        DebugLog.shared.error(.js, "Exception: \(message)")
                    }
                    once.resume(throwing: error)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                once.resume(throwing: EngineError.timedOut)
            }
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            DebugLog.shared.error(.web, "Unexpected reply for \(T.self): \(error.localizedDescription) \(json.prefix(240))")
            throw EngineError.badReply
        }
    }

    /// Loads a new URL into this page and waits (via waitUntilReady) for it to settle.
    func loadURL(_ url: URL) {
        guard !isTornDown else { return }
        isReady = false
        webView.load(URLRequest(url: url))
    }

    func reload(fallback: URL? = nil) {
        isReady = false
        if webView.url == nil {
            webView.load(URLRequest(url: fallback ?? WebFactory.homeURL))
        } else {
            webView.reload()
        }
    }

    /// Back behind the app after being shown in the page sheet.
    func park() { EngineDock.park(webView) }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        isReady = false
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        router.target = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        EngineDock.remove(webView)
        DebugLog.shared.add(.web, "Closed a page")
    }
}

extension PageBridge: ScriptMessageTarget {
    func handleScriptMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            DebugLog.shared.add(.web, "Page ready")
        case "log":
            let level: DebugLog.Level
            switch body["level"] as? String {
            case "error"?: level = .error
            case "info"?, "log"?: level = .info
            default: level = .warning // the engine's own reports are script errors
            }
            DebugLog.shared.add(.js, body["message"] as? String ?? "", level: level)
        case "net":
            let method = body["method"] as? String ?? "GET"
            let url = body["url"] as? String ?? ""
            let status = (body["status"] as? NSNumber)?.intValue ?? 0
            let ms = (body["ms"] as? NSNumber)?.intValue
            let size = (body["size"] as? NSNumber)?.int64Value ?? 0
            var line = "\(method) \(status)"
            if let ms { line += " \(ms) ms" }
            if size > 0 { line += " " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
            line += " " + url
            if let failure = body["error"] as? String { line += " (\(failure))" }
            DebugLog.shared.add(.net, line, level: status == 0 || status >= 400 ? .warning : .info)
        default:
            break
        }
        delegate?.bridgeDidReceive(body)
    }
}

extension PageBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(policy(for: navigationAction))
    }

    private func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .download }
        guard let url = action.request.url else { return .cancel }
        let scheme = (url.scheme ?? "").lowercased()
        if ["about", "blob", "data", "javascript"].contains(scheme) { return .allow }
        guard scheme == "http" || scheme == "https" else {
            if action.navigationType == .linkActivated { UIApplication.shared.open(url) }
            return .cancel
        }
        if let frame = action.targetFrame, !frame.isMainFrame { return .allow }
        return routeTopLevel(url, userInitiated: action.navigationType == .linkActivated)
    }

    fileprivate func routeTopLevel(_ url: URL, userInitiated: Bool) -> WKNavigationActionPolicy {
        if LinkRules.isMediaFile(url) {
            DownloadCenter.shared.fetch(url, kind: .unknown, baseName: "tiktok")
            return .cancel
        }
        if LinkRules.isTikNinja(url) || IGLinks.isViewer(url) { return .allow }
        if allowsInstagram && LinkRules.isInstagram(url) { return .allow }
        if LinkRules.isTikTok(url) {
            AppModel.shared.open(url.absoluteString)
            return .cancel
        }
        if userInitiated {
            DebugLog.shared.add(.nav, "Opening \(url.host ?? url.absoluteString) in Safari")
            UIApplication.shared.open(url)
        } else {
            DebugLog.shared.add(.nav, "Blocked a navigation to \(url.host ?? url.absoluteString)")
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        if let http = response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.contains("attachment") {
            decisionHandler(.download)
            return
        }
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        if navigationResponse.isForMainFrame, let mime = response.mimeType?.lowercased(),
           mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime.hasPrefix("image/") {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadCenter.shared.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadCenter.shared.adopt(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationStart = Date()
        DebugLog.shared.add(.web, "Loading \(webView.url?.absoluteString ?? "page")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let elapsed = navigationStart.map { " in \(Self.ms(since: $0)) ms" } ?? ""
        DebugLog.shared.add(.web, "Loaded \(webView.url?.absoluteString ?? "page")\(elapsed)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        DebugLog.shared.warn(.web, "The page's web process ended (usually memory pressure); reloading it")
        delegate?.bridgeLostContent()
    }

    private func loadFailed(_ error: Error) {
        let ns = error as NSError
        // -999: replaced by another navigation. 102: became a download. 204: handled by a plug-in.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        DebugLog.shared.error(.web, "Load failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        delegate?.bridgeFailedToLoad(error)
    }
}

extension PageBridge: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open never get a second web view.
        if let url = navigationAction.request.url,
           ["http", "https"].contains((url.scheme ?? "").lowercased()),
           routeTopLevel(url, userInitiated: true) == .allow {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let delegate else {
            completionHandler()
            return
        }
        delegate.bridgePresent(JSDialog(kind: .alert, message: message) { _ in completionHandler() })
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let delegate else {
            completionHandler(false)
            return
        }
        delegate.bridgePresent(JSDialog(kind: .confirm, message: message, handler: completionHandler))
    }
}
