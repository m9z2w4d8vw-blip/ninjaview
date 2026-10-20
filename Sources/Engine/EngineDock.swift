import UIKit
import WebKit

/// Engine pages sit in the app's window, behind everything, so WebKit lays them
/// out at phone size and runs their timers at full speed. They never take touches.
@MainActor
enum EngineDock {
    private static var waiting: [WKWebView] = []

    static func park(_ webView: WKWebView) {
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        guard let window = hostWindow else {
            if !waiting.contains(where: { $0 === webView }) { waiting.append(webView) }
            return
        }
        waiting.removeAll { $0 === webView }
        if webView.superview !== window {
            webView.removeFromSuperview()
            window.insertSubview(webView, at: 0)
        } else {
            window.sendSubviewToBack(webView)
        }
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = window.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    /// Pages created before the window existed (at launch) get parked here.
    static func flushWaiting() {
        let pending = waiting
        waiting.removeAll()
        pending.forEach { park($0) }
    }

    static func remove(_ webView: WKWebView) {
        waiting.removeAll { $0 === webView }
        webView.removeFromSuperview()
    }

    static var hostWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}
