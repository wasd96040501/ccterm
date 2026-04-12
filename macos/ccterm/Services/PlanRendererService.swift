import WebKit

@MainActor
final class PlanRendererService: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private(set) var isReady = false
    private var pendingCalls: [(String, String)] = []

    // MARK: - Inbound Event Callbacks (React → Swift)

    var onTextSelected: ((PlanComment.SelectionRange) -> Void)?
    var onSelectionCleared: (() -> Void)?
    var onCommentEdit: ((UUID, String) -> Void)?
    var onCommentDelete: ((UUID) -> Void)?
    var onSearchResult: ((Int, Int) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        let handler = LeakFreeLoaderHandler()
        config.userContentController.add(handler, name: "bridge")

        self.webView = CCWebView.create(configuration: config)
        super.init()

        handler.delegate = self
        webView.navigationDelegate = self

        if let url = Bundle.main.url(forResource: "plan-fullscreen-react", withExtension: "html") {
            appLog(.debug, "PlanDebug", "PlanRendererService: loading HTML from \(url.absoluteString)")
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            appLog(.error, "PlanDebug", "PlanRendererService: plan-fullscreen-react.html NOT FOUND in bundle")
        }
    }

    deinit {
        // WKWebView and configuration are created on MainActor in init,
        // deinit runs on MainActor for @MainActor classes.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
    }

    // MARK: - WKNavigationDelegate

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

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        handleBridgeEvent(type: type, body: body)
    }

    private func handleBridgeEvent(type: String, body: [String: Any]) {
        switch type {
        case "ready":
            appLog(.debug, "PlanDebug", "PlanRendererService: received 'ready', flushing \(pendingCalls.count) pending calls")
            isReady = true
            flushPendingCalls()
        case "textSelected":
            guard let startOffset = body["startOffset"] as? Int,
                  let endOffset = body["endOffset"] as? Int,
                  let selectedText = body["selectedText"] as? String else { return }
            onTextSelected?(PlanComment.SelectionRange(
                startOffset: startOffset, endOffset: endOffset, selectedText: selectedText))
        case "selectionCleared":
            onSelectionCleared?()
        case "commentAction":
            guard let action = body["action"] as? String,
                  let idStr = body["commentId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            if action == "edit", let text = body["text"] as? String {
                onCommentEdit?(id, text)
            } else if action == "delete" {
                onCommentDelete?(id)
            }
        case "searchResult":
            if let total = body["total"] as? Int, let current = body["current"] as? Int {
                onSearchResult?(total, current)
            }
        default:
            break
        }
    }

    // MARK: - Outbound Bridge (Swift → React)

    func setPlan(key: String, markdown: String) {
        appLog(.debug, "PlanDebug", "PlanRendererService: setPlan key=\(key) markdown length=\(markdown.count)")
        queueSend(type: "setPlan", payload: ["key": key, "markdown": markdown])
    }

    func setComments(key: String, comments: [PlanComment]) {
        let dtos = comments.map { c -> [String: Any] in
            var dto: [String: Any] = [
                "id": c.id.uuidString,
                "text": c.text,
                "isInline": c.isInline,
                "createdAt": ISO8601DateFormatter().string(from: c.createdAt),
            ]
            if let range = c.selectionRange {
                dto["startOffset"] = range.startOffset
                dto["endOffset"] = range.endOffset
                dto["selectedText"] = range.selectedText
            }
            return dto
        }
        queueSend(type: "setComments", payload: ["key": key, "comments": dtos])
    }

    func switchPlan(key: String) {
        appLog(.debug, "PlanDebug", "PlanRendererService: switchPlan key=\(key)")
        queueSend(type: "switchPlan", payload: ["key": key])
    }

    func clearPlan(key: String) {
        appLog(.debug, "PlanDebug", "PlanRendererService: clearPlan key=\(key)")
        queueSend(type: "clearPlan", payload: ["key": key])
    }

    func search(query: String, direction: String) {
        queueSend(type: "search", payload: ["query": query, "direction": direction])
    }

    func clearSelection() {
        queueSend(type: "clearSelection", payload: [:])
    }

    func setBottomPadding(_ height: CGFloat) {
        queueSend(type: "setBottomPadding", payload: ["height": height])
    }

    // MARK: - Queue & Flush

    private func queueSend(type: String, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        if isReady {
            callBridge(type: type, json: json)
        } else {
            pendingCalls.append((type, json))
        }
    }

    private func flushPendingCalls() {
        let calls = pendingCalls
        pendingCalls = []
        for (type, json) in calls {
            callBridge(type: type, json: json)
        }
    }

    private func callBridge(type: String, json: String) {
        webView.callAsyncJavaScript(
            "window.__bridge(type, json)",
            arguments: ["type": type, "json": json],
            in: nil, in: .page
        ) { _ in }
    }
}

// MARK: - LeakFreeLoaderHandler

private final class LeakFreeLoaderHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
