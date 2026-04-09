import Cocoa
import WebKit

/// A WKWebView wrapper that auto-sizes to its web content height.
///
/// Uses a `defaultHigh` (750) priority height constraint to express the desired content height.
/// The parent constrains the maximum height via Auto Layout (e.g., `<= maxHeight` at higher priority).
/// When the parent cap is smaller than content, WKWebView scrolls internally.
///
/// No `maxHeight` property — height limiting is the parent's responsibility via constraints.
/// This eliminates circular feedback loops between height calculation and layout.
final class AutoSizingWebView: NSView {

    // MARK: - Public API

    /// Fires when web content reports a new height AND the constraint constant actually changes.
    /// Use this to trigger animation in the parent.
    var onContentHeightChanged: (() -> Void)?

    /// Receive messages from web content. Internal messages (`ready`, `contentHeight`) are handled
    /// automatically and not forwarded here.
    var onMessage: ((_ type: String, _ body: [String: Any]) -> Void)?

    /// Send a typed message to web content via `window.__bridge(type, json)`.
    func send(type: String, json: String) {
        let operation: () -> Void = { [weak self] in
            guard let self else { return }
            self.webView.callAsyncJavaScript(
                "window.__bridge(type, json)",
                arguments: ["type": type, "json": json],
                in: nil, in: .page
            ) { _ in }
        }
        if isReady { operation() } else { pendingCalls.append(operation) }
    }

    // MARK: - Properties

    private let webView: WKWebView
    private var contentHeightConstraint: NSLayoutConstraint!
    private var contentHeight: CGFloat = 0
    private var isReady = false
    private var pendingCalls: [() -> Void] = []
    private static let handlerName = "bridge"

    // MARK: - Lifecycle

    /// - Parameter htmlResource: Name of the HTML file in the bundle (without extension).
    init(htmlResource: String) {
        let config = WKWebViewConfiguration()
        let handler = LeakFreeHandler()
        config.userContentController.add(handler, name: Self.handlerName)

        let webView = CCWebView.create(configuration: config)
        self.webView = webView
        super.init(frame: .zero)

        handler.delegate = self
        webView.navigationDelegate = self
        setupUI()
        loadHTML(resource: htmlResource)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Private Methods

    private func setupUI() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        contentHeightConstraint = heightAnchor.constraint(equalToConstant: 0)
        contentHeightConstraint.priority = .init(NSLayoutConstraint.Priority.defaultHigh.rawValue - 1)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentHeightConstraint,
        ])
    }

    private func loadHTML(resource: String) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "html") else { return }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func markReady() {
        guard !isReady else { return }
        isReady = true
        let ops = pendingCalls
        pendingCalls.removeAll()
        ops.forEach { $0() }
    }

    private func handleContentHeight(_ height: CGFloat) {
        guard abs(height - contentHeight) >= 1 else { return }
        contentHeight = height
        contentHeightConstraint.constant = height
        onContentHeightChanged?()
    }
}

// MARK: - WKNavigationDelegate

extension AutoSizingWebView: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        markReady()
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

extension AutoSizingWebView: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            markReady()
        case "contentHeight":
            if let height = body["height"] as? CGFloat {
                DispatchQueue.main.async { [weak self] in
                    self?.handleContentHeight(height)
                }
            }
        default:
            onMessage?(type, body)
        }
    }
}
