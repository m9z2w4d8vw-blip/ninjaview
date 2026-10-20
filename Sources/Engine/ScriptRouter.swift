import WebKit

@MainActor
protocol ScriptMessageTarget: AnyObject {
    func handleScriptMessage(_ body: [String: Any])
}

/// WKUserContentController retains its handlers strongly; routing through this
/// object, which holds its target weakly, avoids a retain cycle. It also buffers
/// messages (like "ready") that arrive while a preloaded page has no owner yet.
@MainActor
final class ScriptRouter: NSObject, WKScriptMessageHandler {
    weak var target: ScriptMessageTarget? {
        didSet {
            guard target != nil else { return }
            Task { @MainActor [weak self] in self?.flush() }
        }
    }
    private var buffer: [[String: Any]] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let target, buffer.isEmpty {
            target.handleScriptMessage(body)
        } else {
            buffer.append(body)
            if buffer.count > 200 { buffer.removeFirst() }
        }
    }

    private func flush() {
        guard let target else { return }
        let pending = buffer
        buffer.removeAll()
        pending.forEach { target.handleScriptMessage($0) }
    }
}
