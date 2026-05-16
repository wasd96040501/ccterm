#if DEBUG

import Foundation

/// Mock CLI 从 host(AgentSDK)收到的一条 JSON 消息,预解析为常见 shape。
///
/// 解析规则:
/// - `type=user` → `.userMessage`,`text` 抽出 string content,`uuid` 抽出 echo 用 uuid。
/// - `type=control_request` → `.controlRequest`,带上 `subtype`/`requestId`/`params`。
/// - `type=control_response` → `.controlResponse`(host 响应 mock 发出的 control_request,
///   如 permission 决策)。
/// - 其它都进 `.unknown`(scenario 可选自行读 raw)。
///
/// scenario 可以在 `.unknown` 路径里读 `raw` 自行解析未来新加的消息类型,
/// 不需要先扩 `MockCLIIncoming`。
enum MockCLIIncoming {
    case userMessage(text: String, uuid: String?, raw: [String: Any])
    case controlRequest(subtype: String, requestId: String, params: [String: Any], raw: [String: Any])
    case controlResponse(requestId: String, response: [String: Any], raw: [String: Any])
    case unknown(raw: [String: Any])

    static func parse(_ json: [String: Any]) -> MockCLIIncoming {
        let type = json["type"] as? String ?? ""
        switch type {
        case "user":
            let message = json["message"] as? [String: Any]
            let content = message?["content"]
            let text = extractText(from: content)
            let uuid = json["uuid"] as? String
            return .userMessage(text: text, uuid: uuid, raw: json)

        case "control_request":
            let request = json["request"] as? [String: Any] ?? [:]
            let subtype = request["subtype"] as? String ?? ""
            let requestId = json["request_id"] as? String ?? ""
            var params = request
            params.removeValue(forKey: "subtype")
            return .controlRequest(subtype: subtype, requestId: requestId, params: params, raw: json)

        case "control_response":
            let response = json["response"] as? [String: Any] ?? [:]
            let requestId = response["request_id"] as? String ?? ""
            return .controlResponse(requestId: requestId, response: response, raw: json)

        default:
            return .unknown(raw: json)
        }
    }

    private static func extractText(from content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            var out = ""
            for b in blocks where (b["type"] as? String) == "text" {
                if let t = b["text"] as? String { out += t }
            }
            return out
        }
        return ""
    }
}

/// 写 stdout 的句柄。线程安全 —— 内部同步串行化。
final class MockCLISender {

    private let writer: (Data) -> Void
    private let lock = NSLock()

    init(writer: @escaping (Data) -> Void) {
        self.writer = writer
    }

    // MARK: - Low-level

    /// 写一行 JSON(自动追加换行)。所有便捷方法最终都走这里。
    func sendJSON(_ json: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
            var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        guard let out = line.data(using: .utf8) else { return }
        writer(out)
    }

    // MARK: - Helpers (常用 CLI→host 消息形状)

    /// 对一条 `control_request` 回 success。`response` 是放进 `response.response` 里的字段。
    func ackControlSuccess(requestId: String, response: [String: Any] = [:]) {
        sendJSON([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestId,
                "response": response,
            ] as [String: Any],
        ])
    }

    /// 发 `system.init` 消息(session 建立信号)。
    func sendSystemInit(sessionId: String, model: String = "claude-sonnet-4-6") {
        sendJSON([
            "type": "system",
            "subtype": "init",
            "session_id": sessionId,
            "model": model,
            "tools": [],
            "mcp_servers": [],
            "permissionMode": "default",
        ])
    }

    /// echo 一条 user 消息(用于本地 queued→confirmed 匹配)。`uuid` 应与 host 发来的一致。
    func echoUser(text: String, uuid: String, sessionId: String) {
        sendJSON([
            "type": "user",
            "session_id": sessionId,
            "uuid": uuid,
            "message": [
                "role": "user",
                "content": text,
            ] as [String: Any],
        ])
    }

    /// 发 assistant 文本消息(streaming 中间块或完整块)。
    func sendAssistantText(_ text: String, sessionId: String, messageId: String = UUID().uuidString) {
        sendJSON([
            "type": "assistant",
            "session_id": sessionId,
            "message": [
                "id": messageId,
                "role": "assistant",
                "content": [
                    ["type": "text", "text": text]
                ],
            ] as [String: Any],
        ])
    }

    /// 发 turn 结束的 result(success 路径)。
    func sendResultSuccess(sessionId: String, numTurns: Int = 1) {
        sendJSON([
            "type": "result",
            "subtype": "success",
            "session_id": sessionId,
            "is_error": false,
            "num_turns": numTurns,
        ])
    }

    /// 发 turn 结束的 result(error 路径,如被 interrupt)。
    func sendResultError(sessionId: String, errors: [String] = ["interrupted"]) {
        sendJSON([
            "type": "result",
            "subtype": "error_during_execution",
            "session_id": sessionId,
            "is_error": true,
            "errors": errors,
        ])
    }
}

#endif
