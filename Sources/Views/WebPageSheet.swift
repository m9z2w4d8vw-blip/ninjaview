import SwiftUI
import WebKit

/// Shows a profile's engine page itself, for verification checks or a look at
/// something the app doesn't cover. Closing it parks the page out of sight again.
@MainActor
struct WebPageSheet: View {
    let webView: WKWebView
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            PageHost(webView: webView)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle("tik.ninja")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { _ = webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Reload page")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
    }
}

@MainActor
struct PageHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> PageHostView {
        let host = PageHostView()
        host.adopt(webView)
        return host
    }

    func updateUIView(_ host: PageHostView, context: Context) {
        host.adopt(webView)
    }
}

final class PageHostView: UIView {
    private weak var webView: WKWebView?

    func adopt(_ webView: WKWebView) {
        self.webView = webView
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.autoresizingMask = []
        webView.isUserInteractionEnabled = true
        webView.accessibilityElementsHidden = false
        addSubview(webView)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let webView, webView.superview === self { webView.frame = bounds }
    }
}
