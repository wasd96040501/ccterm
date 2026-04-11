import WebKit
import Observation

/// Observable state machine that integrates loading HTML, sending business data,
/// and receiving content height from the web page into a single coherent unit.
///
/// Data sending is state-driven: the caller provides bridge data at init time,
/// and the loader sends it only after JS confirms readiness via a `"ready"` message.
/// If the web content process is terminated by the system, the page is reloaded
/// and data is resent automatically.
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

    /// Bridge data to send when JS is ready.
    private let bridgeType: String?
    private let bridgeJSON: String?

    /// Whether JS has posted the "ready" message.
    private var isPageReady = false

    /// The file URL loaded into the WebView (kept for reload after process termination).
    private var loadedURL: URL?

    init(htmlResource: String, bridgeType: String? = nil, bridgeJSON: String? = nil) {
        self.bridgeType = bridgeType
        self.bridgeJSON = bridgeJSON
        let config = WKWebViewConfiguration()
        let handler = LeakFreeHandler()
        config.userContentController.add(handler, name: Self.handlerName)
        self.webView = CCWebView.create(configuration: config)
        super.init()
        handler.delegate = self
        webView.navigationDelegate = self
        if let url = Bundle.main.url(forResource: htmlResource, withExtension: "html") {
            loadedURL = url
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    /// Send bridge data if JS is ready and data is available.
    private func sendIfReady() {
        guard isPageReady, let type = bridgeType, let json = bridgeJSON else { return }
        webView.callAsyncJavaScript(
            "window.__bridge(type, json)",
            arguments: ["type": type, "json": json],
            in: nil, in: .page
        ) { result in
            if case .failure(let error) = result {
                appLog(.error, "WebViewHeightLoader", "callAsyncJavaScript failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebViewHeightLoader: WKNavigationDelegate {

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        // didFinish 只表示 HTML 文档加载完成，不保证 JS 已初始化。
        // 数据发送由 JS "ready" 消息驱动，不在这里触发。
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
            isPageReady = true
            sendIfReady()
        case "contentHeight":
            if let height = body["height"] as? CGFloat, height > 0 {
                state = .ready(height: height)
            }
        default:
            break
        }
    }
}
