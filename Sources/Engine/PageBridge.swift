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

/// Short names for hidden pages ("P3"), given out in the order the pages are made, so every
/// debug-log line and every request in the tally can say which page it came from.
@MainActor
enum PageTags {
    private static var counter = 0

    static func next() -> String {
        counter += 1
        return "P\(counter)"
    }
}

/// Lets the list of open pages hold them without keeping them alive.
private final class WeakPage {
    weak var page: PageBridge?
    init(_ page: PageBridge) { self.page = page }
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

    /// "P3": which hidden page a log line or a request came from.
    let tag: String
    /// What the page is for, set by its owner: "screen @name", "session copy @name", "watch check @name".
    var owner = "page"
    /// "P3 screen @name": the prefix on this page's log lines and its name in the request tally.
    var label: String { "\(tag) \(owner)" }
    let created = Date()
    private(set) var loads = 0
    private(set) var lastLoaded: Date?
    /// The HTTP status of the latest page load itself (not of the requests the page makes).
    private(set) var lastPageStatus: Int?

    private static var registry: [WeakPage] = []

    /// Every page that hasn't been closed, oldest first.
    static var openPages: [PageBridge] {
        registry.compactMap { $0.page }.filter { !$0.isTornDown }
    }

    init(_ prepared: PreparedWebView) {
        webView = prepared.webView
        router = prepared.router
        tag = prepared.tag.isEmpty ? PageTags.next() : prepared.tag
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        router.target = self
        PageBridge.registry.removeAll { $0.page == nil || $0.page?.isTornDown == true }
        PageBridge.registry.append(WeakPage(self))
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
    /// `quiet` leaves the call out of the debug log (for polls that run every second or two).
    func call(_ body: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 45, redacting: Set<String> = [],
              quiet: Bool = false) async throws -> String {
        let name = Self.callName(body)
        let started = Date()
        do {
            let json = try await rawCall(body, arguments, timeout: timeout)
            if !quiet {
                DebugLog.shared.add(.web, "[\(label)] \(name)(\(Self.describe(arguments, redacting: redacting))) took \(Self.ms(since: started)) ms, \(json.utf8.count) bytes back")
            }
            return json
        } catch {
            if !quiet {
                DebugLog.shared.error(.web, "[\(label)] \(name)(\(Self.describe(arguments, redacting: redacting))) failed after \(Self.ms(since: started)) ms: \(error.localizedDescription)")
            }
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

    /// "4.1 s", "35 s", "12 min"
    nonisolated static func ago(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        if seconds < 120 { return "\(Int(seconds)) s" }
        if seconds < 7200 { return "\(Int(seconds / 60)) min" }
        return String(format: "%.1f h", seconds / 3600)
    }

    /// A number from a script message (JavaScript numbers arrive as NSNumber).
    nonisolated static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return nil
    }

    /// "content-type: application/json; retry-after: 60"
    nonisolated static func flatten(_ dictionary: [String: Any], separator: String = "; ") -> String {
        dictionary.keys.sorted().map { key -> String in
            let value = String(describing: dictionary[key] ?? "")
            return "\(key): \(value.count > 200 ? String(value.prefix(200)) + "\u{2026}" : value)"
        }.joined(separator: separator)
    }

    /// "https://tik.ninja/ · ready · HTTP 200 · loaded 2 times, last 4.1 s ago · made 12 s ago"
    var stateSummary: String {
        var parts = [webView.url?.absoluteString ?? "nothing loaded"]
        parts.append(isTornDown ? "closed" : (isReady ? "ready" : "not ready"))
        if let lastPageStatus { parts.append("HTTP \(lastPageStatus)") }
        if let lastLoaded {
            parts.append("loaded \(loads) \(loads == 1 ? "time" : "times"), last \(Self.ago(lastLoaded)) ago")
        } else {
            parts.append("hasn't finished loading")
        }
        parts.append("made \(Self.ago(created)) ago")
        return parts.joined(separator: " \u{00B7} ")
    }

    private func rawCall(_ body: String, _ arguments: [String: Any], timeout: TimeInterval) async throws -> String {
        guard !isTornDown else { throw EngineError.torn }
        let webView = self.webView
        let pageLabel = label
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
                        DebugLog.shared.error(.js, "[\(pageLabel)] Exception: \(message)")
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
            DebugLog.shared.error(.web, "[\(label)] Unexpected reply for \(T.self): \(error.localizedDescription) \(json.prefix(240))")
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
        DebugLog.shared.add(.web, "[\(label)] Closed the page after \(Self.ago(created))")
    }
}

extension PageBridge: ScriptMessageTarget {
    func handleScriptMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            DebugLog.shared.add(.web, "[\(label)] Page ready: \(body["url"] as? String ?? webView.url?.absoluteString ?? "?")")
        case "log":
            let level: DebugLog.Level
            switch body["level"] as? String {
            case "error"?: level = .error
            case "info"?, "log"?: level = .info
            default: level = .warning // the engine's own reports are script errors
            }
            DebugLog.shared.add(.js, "[\(label)] " + (body["message"] as? String ?? ""), level: level)
        case "net":
            logRequest(body)
        case "res":
            logResources(body)
        case "stream":
            logStream(body)
        default:
            break
        }
        delegate?.bridgeDidReceive(body)
    }

    /// One request the page made, from the logger injected at document start. Every request gets
    /// a line; a refused or failed one also gets what was sent and what came back.
    private func logRequest(_ body: [String: Any]) {
        let method = (body["method"] as? String ?? "GET").uppercased()
        let url = body["url"] as? String ?? ""
        let status = Self.number(body["status"]) ?? 0
        let ms = Self.number(body["ms"])
        let size = Int64(Self.number(body["size"]) ?? 0)
        let opaque = (body["rtype"] as? String) == "opaque"
        let response = body["resHeaders"] as? [String: Any] ?? [:]
        let failure = body["error"] as? String ?? ""
        let problem = status >= 400 || (status == 0 && !opaque)

        var line = "[\(label)]"
        if let seq = Self.number(body["seq"]) { line += " #\(seq)" }
        if let kind = body["kind"] as? String, kind != "fetch" { line += " \(kind)" }
        line += " \(method) \(status == 0 && !opaque ? "failed" : String(status))"
        if problem, let text = body["statusText"] as? String, !text.isEmpty { line += " \(text)" }
        if let ms { line += " \(ms) ms" }
        if size > 0 { line += " " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
        line += " " + url
        if !failure.isEmpty { line += " (\(failure))" }

        var detail: [String] = []
        if !response.isEmpty {
            if problem || response.count > 3 {
                detail.append("response headers: " + Self.flatten(response))
            } else {
                line += " \u{00B7} " + Self.flatten(response, separator: ", ")
            }
        }
        if let sent = body["reqHeaders"] as? [String: Any], !sent.isEmpty { detail.append("request headers: " + Self.flatten(sent)) }
        if let sentBody = body["reqBody"] as? String, !sentBody.isEmpty { detail.append("request body: " + sentBody) }
        if let final = body["finalURL"] as? String, !final.isEmpty { detail.append("redirected to: " + final) }
        if let text = body["body"] as? String, !text.isEmpty { detail.append("response body: " + text) }
        if let online = body["online"] as? Bool, !online { detail.append("the page thinks the phone is offline") }

        let level: DebugLog.Level = status == 429 || status >= 500 ? .error : (problem ? .warning : .info)
        let message = ([line] + detail.map { "  " + $0 }).joined(separator: "\n")
        DebugLog.shared.add(.net, message, level: level)
        NetLedger.shared.record(source: label, kind: body["kind"] as? String ?? "fetch", method: method,
                                host: body["host"] as? String ?? "", path: body["path"] as? String ?? "",
                                status: opaque && status == 0 ? nil : status, ms: ms,
                                retryAfter: response["retry-after"] as? String,
                                detail: status == 429 ? message : nil)
    }

    /// Images, scripts and the like the page loaded, batched every few seconds by the logger.
    /// The tik.ninja ones count toward its limit like any other request.
    private func logResources(_ body: [String: Any]) {
        let items = body["items"] as? [[String: Any]] ?? []
        let others = body["others"] as? [String: Any] ?? [:]
        var kinds: [String] = []
        var failed: [String] = []
        for item in items {
            let kind = item["kind"] as? String ?? "other"
            let host = item["host"] as? String ?? ""
            let path = item["path"] as? String ?? ""
            let status = Self.number(item["status"]) ?? 0
            kinds.append(kind)
            if status >= 400 { failed.append("\(status) \(host)\(path)") }
            NetLedger.shared.record(source: label, kind: kind, method: "GET", host: host, path: path,
                                    status: status > 0 ? status : nil, ms: Self.number(item["ms"]))
        }
        let otherCounts = others.map { (key: $0.key, count: Self.number($0.value) ?? 0) }.sorted { $0.count > $1.count }
        let otherTotal = otherCounts.reduce(0) { $0 + $1.count }
        var line = "[\(label)] Page resources: \(items.count) from tik.ninja"
        if !kinds.isEmpty { line += " (" + NetLedger.tally(kinds, limit: 5) + ")" }
        line += ", \(otherTotal) from other sites"
        if !otherCounts.isEmpty {
            line += " (" + otherCounts.prefix(4).map { "\($0.key) \($0.count)" }.joined(separator: " \u{00B7} ") + ")"
        }
        DebugLog.shared.add(.net, line, level: failed.isEmpty ? .info : .warning)
        if !failed.isEmpty {
            DebugLog.shared.warn(.net, "[\(label)] Page resources that failed: " + failed.prefix(12).joined(separator: "; "))
        }
    }

    /// A server-sent-events or WebSocket connection the page opened.
    private func logStream(_ body: [String: Any]) {
        let kind = body["kind"] as? String ?? "stream"
        let event = body["event"] as? String ?? "?"
        var line = "[\(label)] \(kind.uppercased()) \(event) \(body["url"] as? String ?? "")"
        if let ms = Self.number(body["ms"]) { line += " after \(ms) ms" }
        if let code = Self.number(body["code"]) { line += ", code \(code)" }
        if let reason = body["reason"] as? String, !reason.isEmpty { line += ", reason \(reason)" }
        if let state = Self.number(body["state"]) { line += ", readyState \(state)" }
        if let count = Self.number(body["count"]) { line += ", \(count) messages so far" }
        if let data = body["data"] as? String, !data.isEmpty { line += "\n  data: " + data }
        DebugLog.shared.add(.net, line, level: event == "error" ? .warning : .info)
        // EventSource requests already arrive with the page's resources; WebSockets don't.
        if event == "connect" && kind == "ws" {
            NetLedger.shared.record(source: label, kind: kind, method: "GET", host: body["host"] as? String ?? "",
                                    path: body["path"] as? String ?? "", status: nil, ms: nil)
        }
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
            DebugLog.shared.add(.nav, "[\(label)] Opening \(url.host ?? url.absoluteString) in Safari")
            UIApplication.shared.open(url)
        } else {
            DebugLog.shared.add(.nav, "[\(label)] Blocked a navigation to \(url.host ?? url.absoluteString)")
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        if navigationResponse.isForMainFrame, let http = response as? HTTPURLResponse {
            notePageResponse(http)
        }
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

    /// The page load's own answer. A refusal here (Cloudflare turning the page away, say) never
    /// reaches the request logger, which only runs once a page has loaded.
    private func notePageResponse(_ http: HTTPURLResponse) {
        lastPageStatus = http.statusCode
        let ms = navigationStart.map { Self.ms(since: $0) }
        let summary = HTTPDebug.describe(http)
        let line = "[\(label)] The page itself (\(http.url?.absoluteString ?? "?")) answered \(summary)"
        if http.statusCode >= 400 {
            DebugLog.shared.add(.web, line, level: http.statusCode == 429 ? .error : .warning)
        }
        NetLedger.shared.record(source: label, kind: "page", method: "GET", url: http.url, status: http.statusCode, ms: ms,
                                retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                                detail: http.statusCode == 429 ? line : nil)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadCenter.shared.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadCenter.shared.adopt(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationStart = Date()
        DebugLog.shared.add(.web, "[\(label)] Loading \(webView.url?.absoluteString ?? "page")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loads += 1
        lastLoaded = Date()
        let elapsed = navigationStart.map { " in \(Self.ms(since: $0)) ms" } ?? ""
        let status = lastPageStatus.map { ", HTTP \($0)" } ?? ""
        DebugLog.shared.add(.web, "[\(label)] Loaded \(webView.url?.absoluteString ?? "page")\(elapsed)\(status)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        DebugLog.shared.warn(.web, "[\(label)] The page's web process ended (usually memory pressure); reloading it")
        delegate?.bridgeLostContent()
    }

    private func loadFailed(_ error: Error) {
        let ns = error as NSError
        // -999: replaced by another navigation. 102: became a download. 204: handled by a plug-in.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        DebugLog.shared.error(.web, "[\(label)] Load failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
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
