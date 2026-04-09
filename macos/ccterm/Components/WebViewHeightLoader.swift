import WebKit
import Observation

/// Observable state machine that integrates loading HTML, sending business data,
/// and receiving content height from the web page into a single coherent unit.
///
/// The page must post a `contentHeight` message via `window.webkit.messageHandlers.bridge`
/// in the format `{ type: "contentHeight", height: <number> }` when its layout is ready.
/// Both `bash-react` and `diff-react` already do this.
@Observable
final class WebViewHeightLoader: NSObject {
    enum State {
        case loading
        case ready(height: CGFloat)
    }

    private(set) var state: State = .loading
    let webView: WKWebView

    private static let handlerName = "bridge"
    private let onReady: ((WKWebView) -> Void)?
    private var hasSent = false

    init(htmlResource: String, onReady: ((WKWebView) -> Void)? = nil) {
        self.onReady = onReady
        let config = WKWebViewConfiguration()
        let handler = LeakFreeHandler()
        config.userContentController.add(handler, name: Self.handlerName)
        self.webView = CCWebView.create(configuration: config)
        super.init()
        handler.delegate = self
        webView.navigationDelegate = self
        if let url = Bundle.main.url(forResource: htmlResource, withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    private func triggerOnReadyIfNeeded() {
        guard !hasSent else { return }
        hasSent = true
        onReady?(webView)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewHeightLoader: WKNavigationDelegate {

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        triggerOnReadyIfNeeded()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

// MARK: - WKScriptMessageHandler

extension WebViewHeightLoader: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            triggerOnReadyIfNeeded()
        case "contentHeight":
            if let height = body["height"] as? CGFloat, height > 0 {
                state = .ready(height: height)
            }
        default:
            break
        }
    }
}
