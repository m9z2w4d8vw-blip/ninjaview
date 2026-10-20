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

    /// Runs an async function body in the page. Engine calls always return a JSON string.
    func call(_ body: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 45) async throws -> String {
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
                        DebugLog.shared.add(.js, "Exception: \(message)")
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
            DebugLog.shared.add(.web, "Unexpected reply for \(T.self): \(error.localizedDescription) \(json.prefix(240))")
            throw EngineError.badReply
        }
    }

    func reload() {
        isReady = false
        if webView.url == nil {
            webView.load(URLRequest(url: WebFactory.homeURL))
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
            DebugLog.shared.add(.js, body["message"] as? String ?? "")
        case "net":
            let method = body["method"] as? String ?? "GET"
            let url = body["url"] as? String ?? ""
            let status = (body["status"] as? NSNumber)?.intValue ?? 0
            DebugLog.shared.add(.net, "\(method) \(status) \(url)")
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
        if LinkRules.isTikNinja(url) { return .allow }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLog.shared.add(.web, "Loaded \(webView.url?.absoluteString ?? "page")")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        delegate?.bridgeLostContent()
    }

    private func loadFailed(_ error: Error) {
        let ns = error as NSError
        // -999: replaced by another navigation. 102: became a download. 204: handled by a plug-in.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        DebugLog.shared.add(.web, "Load failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
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
