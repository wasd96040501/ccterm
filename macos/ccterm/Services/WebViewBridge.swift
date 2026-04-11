import Cocoa
import WebKit

protocol WebViewBridgeDelegate: AnyObject {
    func bridge(_ bridge: WebViewBridge, didReceive event: WebEvent)
}

enum WebEvent {
    case ready(conversationId: String)
    case searchResult(total: Int, current: Int)
    case scrollStateChanged(conversationId: String, isAtBottom: Bool)
    case editMessage(messageUuid: String, newText: String)
    case forkMessage(messageUuid: String)
}

final class WebViewBridge: NSObject {

    // MARK: - Properties

    weak var delegate: WebViewBridgeDelegate?

    private let webView: WKWebView
    private var isReady = false
    private var pendingCalls: [() -> Void] = []
    private let encoder = JSONEncoder()
    private static let handlerName = "bridge"

    // MARK: - Lifecycle

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        let handler = LeakFreeBridgeHandler()
        handler.delegate = self
        webView.configuration.userContentController.add(handler, name: Self.handlerName)
    }

    // MARK: - Public Methods

    func switchConversation(_ conversationId: String) {
        send(type: "switchConversation", payload: SwitchConversationPayload(conversationId: conversationId))
    }

    func setTurnActive(conversationId: String, isTurnActive: Bool, interrupted: Bool = false) {
        send(type: "setTurnActive", payload: SetTurnActivePayload(conversationId: conversationId, isTurnActive: isTurnActive, interrupted: interrupted))
    }

    func search(query: String, direction: String) {
        send(type: "search", payload: SearchPayload(query: query, direction: direction))
    }

    func setBottomPadding(_ height: CGFloat) {
        appLog(.debug, "Bridge", "setBottomPadding: height=\(String(format: "%.1f", height)) isReady=\(isReady)")
        send(type: "setBottomPadding", payload: SetBottomPaddingPayload(height: height))
    }

    func scrollToBottom() {
        send(type: "scrollToBottom", payload: EmptyPayload())
    }

    /// 转发原始 Message2 JSON 到 React（新路径）。
    func forwardRawMessage(conversationId: String, messageJSON: [String: Any]) {
        sendRaw(type: "forwardRawMessage", payload: [
            "conversationId": conversationId,
            "message": messageJSON,
        ])
    }

    /// 批量转发原始 Message2 JSON（history replay 用）。
    func setRawMessages(conversationId: String, messagesJSON: [[String: Any]]) {
        sendRaw(type: "setRawMessages", payload: [
            "conversationId": conversationId,
            "messages": messagesJSON,
        ])
    }

    func markReady() {
        isReady = true
        let ops = pendingCalls
        pendingCalls.removeAll()
        for op in ops {
            op()
        }
    }

    // MARK: - Private Methods

    /// 发送 [String: Any] payload（非 Encodable），使用 JSONSerialization。
    private func sendRaw(type: String, payload: [String: Any]) {
        let operation = { [weak self] in
            guard let self else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            self.webView.callAsyncJavaScript(
                "window.__bridge(type, json)",
                arguments: ["type": type, "json": json],
                in: nil,
                in: .page
            ) { _ in
            }
        }
        if isReady {
            operation()
        } else {
            pendingCalls.append(operation)
        }
    }

    private func send<T: Encodable>(type: String, payload: T) {
        let operation = { [weak self] in
            guard let self else { return }
            guard let data = try? self.encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            self.webView.callAsyncJavaScript(
                "window.__bridge(type, json)",
                arguments: ["type": type, "json": json],
                in: nil,
                in: .page
            ) { _ in
            }
        }
        if isReady {
            operation()
        } else {
            pendingCalls.append(operation)
        }
    }
}

// MARK: - Payload Types

private struct SwitchConversationPayload: Encodable {
    let conversationId: String
}

private struct SetTurnActivePayload: Encodable {
    let conversationId: String
    let isTurnActive: Bool
    let interrupted: Bool
}

private struct SearchPayload: Encodable {
    let query: String
    let direction: String
}

private struct SetBottomPaddingPayload: Encodable {
    let height: Double
}

private struct EmptyPayload: Encodable {}

// MARK: - WKScriptMessageHandler

extension WebViewBridge: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            if let conversationId = body["conversationId"] as? String {
                delegate?.bridge(self, didReceive: .ready(conversationId: conversationId))
            }
        case "searchResult":
            let total = body["total"] as? Int ?? 0
            let current = body["current"] as? Int ?? 0
            delegate?.bridge(self, didReceive: .searchResult(total: total, current: current))
        case "scrollStateChanged":
            if let conversationId = body["conversationId"] as? String,
               let isAtBottom = body["isAtBottom"] as? Bool {
                delegate?.bridge(self, didReceive: .scrollStateChanged(conversationId: conversationId, isAtBottom: isAtBottom))
            }
        case "editMessage":
            if let messageUuid = body["messageUuid"] as? String,
               let newText = body["newText"] as? String {
                delegate?.bridge(self, didReceive: .editMessage(messageUuid: messageUuid, newText: newText))
            }
        case "forkMessage":
            if let messageUuid = body["messageUuid"] as? String {
                delegate?.bridge(self, didReceive: .forkMessage(messageUuid: messageUuid))
            }
        default:
            break
        }
    }
}

// MARK: - LeakFreeBridgeHandler

private final class LeakFreeBridgeHandler: NSObject, WKScriptMessageHandler {

    weak var delegate: WKScriptMessageHandler?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
