#if DEBUG

import Foundation

/// One JSON message the mock CLI received from the host (AgentSDK),
/// pre-parsed into common shapes.
///
/// Parsing rules:
/// - `type=user` → `.userMessage`; `text` extracts string content, `uuid`
///   extracts the uuid used for echo.
/// - `type=control_request` → `.controlRequest`, with `subtype` / `requestId`
///   / `params`.
/// - `type=control_response` → `.controlResponse` (host responding to a
///   control_request the mock sent, e.g. a permission decision).
/// - Anything else falls into `.unknown` (scenario may parse raw).
///
/// Scenarios can handle new message types via the `.unknown` path by reading
/// `raw` directly, without first extending `MockCLIIncoming`.
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

/// Stdout write handle. Thread-safe — serializes internally.
final class MockCLISender {

    private let writer: (Data) -> Void
    private let lock = NSLock()

    init(writer: @escaping (Data) -> Void) {
        self.writer = writer
    }

    // MARK: - Low-level

    /// Write one JSON line (newline appended). All convenience methods funnel
    /// through here.
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

    // MARK: - Helpers (common CLI→host message shapes)

    /// Reply success to a `control_request`. `response` goes into the inner
    /// `response.response` field.
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

    /// Emit `system.init` (session-established signal).
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

    /// Echo a user message (drives the host's queued→confirmed match).
    /// `uuid` must match what the host sent.
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

    /// Emit an assistant text message (streaming chunk or full block).
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

    /// Emit the turn-completion result (success path).
    func sendResultSuccess(sessionId: String, numTurns: Int = 1) {
        sendJSON([
            "type": "result",
            "subtype": "success",
            "session_id": sessionId,
            "is_error": false,
            "num_turns": numTurns,
        ])
    }

    /// Emit the turn-completion result (error path, e.g. on interrupt).
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
