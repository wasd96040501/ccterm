#if DEBUG

import Foundation

/// Scenario:让 turn 永远挂着。用于验证 stop / interrupt 路径——只要 host 不主动
/// interrupt,assistant 就永远不会发 result,turn 一直在飞。
///
/// 行为:
/// - host 发 `initialize` → ack success + 发 `system.init`(让 SessionHandle2 完成 bootstrap)
/// - host 发 user message → echo 回 user 一条(uuid 一致,触发 queued→confirmed),
///   **不**发 `assistant` / `result`,turn 永远挂着(`isRunning` 持续 true)
/// - host 发 `interrupt` → ack success + 发 `result.error_during_execution` 关掉 turn
/// - 其它 control_request → 一律 ack success(避免 host 那边 callback 挂死)
final class HangingTurnScenario: MockCLIScenario {

    /// 由首个收到的消息 / initialize 注入。默认是个稳定的固定 UUID,以便 scenario 内
    /// 自行 emit 时也能用。
    private var sessionId: String = "11111111-1111-1111-1111-111111111111"

    func onIncoming(_ message: MockCLIIncoming, send: MockCLISender) {
        switch message {
        case .controlRequest(let subtype, let requestId, _, _):
            handleControlRequest(subtype: subtype, requestId: requestId, send: send)

        case .userMessage(let text, let uuid, _):
            // echo 回去,uuid 保持一致 — SessionHandle2 用 uuid 把 .queued 转 .confirmed
            if let uuid {
                send.echoUser(text: text, uuid: uuid, sessionId: sessionId)
            }
            // 故意不发 assistant / result — turn 永远挂着

        case .controlResponse, .unknown:
            break
        }
    }

    private func handleControlRequest(subtype: String, requestId: String, send: MockCLISender) {
        switch subtype {
        case "initialize":
            send.ackControlSuccess(requestId: requestId, response: [
                "commands": [],
                "models": [],
            ])
            send.sendSystemInit(sessionId: sessionId)

        case "interrupt":
            send.ackControlSuccess(requestId: requestId)
            send.sendResultError(sessionId: sessionId, errors: ["interrupted"])

        default:
            send.ackControlSuccess(requestId: requestId)
        }
    }
}

#endif
