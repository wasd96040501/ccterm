import Cocoa
import WebKit

/// Chat 业务容器：创建和配置 WKWebView，管理 Bridge 和导航。
/// 不再是 NSView 子类，视图封装由通用 WebViewRepresentable 负责。
@MainActor
final class ChatContentView: NSObject, WKNavigationDelegate {

    // MARK: - Properties

    let bridge: WebViewBridge
    let webView: WKWebView

    // MARK: - Lifecycle

    override init() {
        webView = CCWebView.create()
        bridge = WebViewBridge(webView: webView)
        super.init()
        webView.navigationDelegate = self
        warmUp()
    }

    // MARK: - Private Methods

    private func warmUp() {
        guard let htmlURL = Bundle.main.url(forResource: "chat-react", withExtension: "html") else {
            NSLog("[ChatContentView] chat-react.html not found in bundle")
            return
        }
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        bridge.markReady()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[ChatContentView] Navigation failed: \(error.localizedDescription)")
        bridge.markReady()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("[ChatContentView] Provisional navigation failed: \(error.localizedDescription)")
        bridge.markReady()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
