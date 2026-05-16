#if DEBUG

import Foundation

/// Base scenario class with default behavior. **All test scenarios should
/// subclass this**, overriding only the hooks they care about; the rest fall
/// back to base "close to the real claude CLI" defaults.
///
/// Default behavior:
/// - `onStart`: no-op, wait for host to send initialize.
/// - `onInitialize`: ack control_response success + emit `system.init`.
/// - `onInterrupt`: ack control_response success + emit
///   `result.error_during_execution` to close the turn.
/// - `onControlRequest` (other subtypes): always ack success (prevents host
///   callbacks from hanging).
/// - `onUserMessage`: echo user (uuid match triggers queued→confirmed) + emit
///   `result.success`; one round-trip turn.
/// - `onControlResponse` / `onUnknown`: no-op.
///
/// Usage — one scenario per test, override only what differs:
/// ```swift
/// final class MyScenario: MockCLIBaseScenario {
///     override func onUserMessage(text: String, uuid: String?, send: MockCLISender) {
///         // Deviation: echo but don't send result — turn hangs forever.
///         if let uuid { send.echoUser(text: text, uuid: uuid, sessionId: sessionId) }
///     }
/// }
/// ```
///
/// The framework layer (`MockCLIRunner` / `MockCLISender` /
/// `MockCLIIncoming.parse`) is scaffolding only — no business or test-specific
/// logic. All "what mock claude should do" lives in scenario classes.
class MockCLIBaseScenario: MockCLIScenario {

    /// Scenario-internal session id. Used by `onInitialize` for `system.init`,
    /// and by `echoUser` / `sendResultXxx`. Scenarios may override in init.
    var sessionId: String = "11111111-1111-1111-1111-111111111111"

    init() {}

    // MARK: - MockCLIScenario

    func onStart(send: MockCLISender) {
        // Default no-op. Override only when a scenario must emit something on
        // subprocess startup (simulating CLI talking on its own); most
        // scenarios just wait for host's initialize.
    }

    final func onIncoming(_ message: MockCLIIncoming, send: MockCLISender) {
        switch message {
        case .controlRequest(let subtype, let requestId, let params, _):
            switch subtype {
            case "initialize":
                onInitialize(requestId: requestId, params: params, send: send)
            case "interrupt":
                onInterrupt(requestId: requestId, send: send)
            default:
                onControlRequest(subtype: subtype, requestId: requestId, params: params, send: send)
            }
        case .userMessage(let text, let uuid, _):
            onUserMessage(text: text, uuid: uuid, send: send)
        case .controlResponse(let requestId, let response, _):
            onControlResponse(requestId: requestId, response: response, send: send)
        case .unknown(let raw):
            onUnknown(raw: raw, send: send)
        }
    }

    // MARK: - Override points

    /// Host sent `initialize` control_request. Default: ack success + emit
    /// `system.init`.
    func onInitialize(requestId: String, params: [String: Any], send: MockCLISender) {
        send.ackControlSuccess(
            requestId: requestId,
            response: [
                "commands": [],
                "models": [],
            ])
        send.sendSystemInit(sessionId: sessionId)
    }

    /// Host sent `interrupt` control_request. Default: ack success and emit
    /// a `result.error_during_execution` to close the turn.
    func onInterrupt(requestId: String, send: MockCLISender) {
        send.ackControlSuccess(requestId: requestId)
        send.sendResultError(sessionId: sessionId, errors: ["interrupted"])
    }

    /// Other control_request subtypes (`set_model`, `apply_flag_settings`, ...).
    /// Default: ack success with empty response. Override to simulate errors
    /// or validate params.
    func onControlRequest(subtype: String, requestId: String, params: [String: Any], send: MockCLISender) {
        send.ackControlSuccess(requestId: requestId)
    }

    /// Host sent a user message. Default: echo one user message (with the
    /// host-supplied uuid), then immediately send `result.success` — turn
    /// completes in one round trip.
    ///
    /// Common overrides:
    /// - "turn hangs forever" → echo without sending result
    /// - "assistant streams N chunks then finishes" → echo + sendAssistantText * N + sendResultSuccess
    /// - "permission flow" → echo + send control_request(can_use_tool) to host
    func onUserMessage(text: String, uuid: String?, send: MockCLISender) {
        if let uuid {
            send.echoUser(text: text, uuid: uuid, sessionId: sessionId)
        }
        send.sendResultSuccess(sessionId: sessionId)
    }

    /// Host responding to a control_request the mock previously sent (e.g.
    /// mock sent `can_use_tool`, host replies allow/deny). Default no-op.
    func onControlResponse(requestId: String, response: [String: Any], send: MockCLISender) {
    }

    /// Any unrecognized message type. Default no-op; scenarios may parse `raw`.
    func onUnknown(raw: [String: Any], send: MockCLISender) {
    }
}

#endif
