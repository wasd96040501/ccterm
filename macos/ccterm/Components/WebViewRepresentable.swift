import SwiftUI
import WebKit

/// 通用 WKWebView SwiftUI 封装。
/// 处理 cursor guard（通过 CursorGuard 全局注册表防止 WKWebView cursor 穿透）和 toolbar 区域 hitTest 过滤。
struct WebViewRepresentable: NSViewRepresentable {

    let webView: WKWebView

    /// 是否过滤 toolbar 区域的点击（chat WebView 需要，plan 不需要）
    var filterToolbarHits: Bool = false

    /// 需要压制 cursor 的区域（坐标系：origin 在左上角，与 SwiftUI 一致）。
    /// 在这些区域内 WKWebView 的 cursor 变化会被拦截为 arrow。
    /// 传 `[.infinite]` 表示全区域压制。
    var cursorGuardRects: [CGRect] = []

    func makeNSView(context: Context) -> WebViewContainerView {
        WebViewContainerView(webView: webView, filterToolbarHits: filterToolbarHits)
    }

    func updateNSView(_ nsView: WebViewContainerView, context: Context) {
        nsView.filterToolbarHits = filterToolbarHits
        nsView.cursorGuardRects = cursorGuardRects
    }
}

/// 包裹 WKWebView 的 NSView，统一处理 cursor guard 注册和 hitTest。
final class WebViewContainerView: NSView {

    override var isFlipped: Bool { true }

    private let webView: WKWebView
    var filterToolbarHits: Bool

    var cursorGuardRects: [CGRect] = [] {
        didSet {
            if cursorGuardRects.isEmpty {
                CursorGuard.unregister(self)
            } else {
                CursorGuard.register(self, rects: cursorGuardRects)
            }
        }
    }

    init(webView: WKWebView, filterToolbarHits: Bool = false) {
        self.webView = webView
        self.filterToolbarHits = filterToolbarHits
        super.init(frame: .zero)

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        CursorGuard.unregister(self)
    }

    // MARK: - HitTest

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard filterToolbarHits, hit === webView,
              let window = window, let superview = superview else {
            return hit
        }
        let windowPoint = superview.convert(point, to: nil)
        if windowPoint.y >= window.contentLayoutRect.maxY {
            return nil
        }
        return hit
    }
}
