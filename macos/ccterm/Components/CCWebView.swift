import WebKit

/// 统一的 WKWebView 子类，封装通用配置和右键菜单定制。
final class CCWebView: WKWebView {

    /// 创建预配置的 WebView 实例（透明背景、DEBUG inspect）。
    /// - Parameter config: 外部预配置的 configuration（需要 userContentController 等场景）。
    ///   传 nil 则使用默认 configuration。
    static func create(configuration config: WKWebViewConfiguration? = nil) -> CCWebView {
        let configuration = config ?? WKWebViewConfiguration()
        #if DEBUG
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        let webView = CCWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    // MARK: - Context Menu

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.items.removeAll { item in
            let title = item.title.lowercased()
            return title == "reload" || title == "go back" || title == "go forward"
        }
        super.willOpenMenu(menu, with: event)
    }
}

// MARK: - LeakFreeHandler

/// Prevents WKUserContentController from retaining the message handler owner.
/// WKUserContentController holds a strong reference to added handlers; using this
/// weak-delegate proxy breaks the retain cycle.
final class LeakFreeHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: (any WKScriptMessageHandler)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
