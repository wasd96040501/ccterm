#if DEBUG

import Foundation

/// 含默认行为的 scenario base class。**所有 test scenario 应当继承此类**,
/// 只 override 自己关心的钩子,其它走 base 的"贴近真 claude CLI"默认行为。
///
/// 默认行为概览:
/// - `onStart`:no-op,等 host 发 initialize。
/// - `onInitialize`:回 control_response success + 发 `system.init`。
/// - `onInterrupt`:回 control_response success + 发 `result.error_during_execution`,
///   关掉 turn。
/// - `onControlRequest`(其它 subtype):一律 ack success(避免 host callback 挂死)。
/// - `onUserMessage`:echo user(uuid 一致触发 queued→confirmed)+ 发
///   `result.success`,turn 一来一回完成。
/// - `onControlResponse`/`onUnknown`:no-op。
///
/// 用法 —— 一个测试一个 scenario,只 override 关心的钩子:
/// ```swift
/// final class MyScenario: MockCLIBaseScenario {
///     override func onUserMessage(text: String, uuid: String?, send: MockCLISender) {
///         // 偏离默认:echo 但不发 result —— turn 永远挂着
///         if let uuid { send.echoUser(text: text, uuid: uuid, sessionId: sessionId) }
///     }
/// }
/// ```
///
/// 框架层(`MockCLIRunner` / `MockCLISender` / `MockCLIIncoming.parse`)只负责脚手架,
/// 不写任何业务/测试相关逻辑;所有"mock claude 应该做什么"都在 scenario 类里。
class MockCLIBaseScenario: MockCLIScenario {

    /// scenario 内自洽的会话 id。`onInitialize` 回 `system.init`、`echoUser` /
    /// `sendResultXxx` 都用它。需要的话 scenario 可以在 init 里覆盖。
    var sessionId: String = "11111111-1111-1111-1111-111111111111"

    init() {}

    // MARK: - MockCLIScenario

    func onStart(send: MockCLISender) {
        // 默认 no-op。要在子进程一启动就 emit 东西(模拟"CLI 自言自语")的 scenario
        // 才需要 override —— 大多数 scenario 等 host 发 initialize 即可。
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

    /// host 发 `initialize` control_request。默认回 success + `system.init`。
    func onInitialize(requestId: String, params: [String: Any], send: MockCLISender) {
        send.ackControlSuccess(
            requestId: requestId,
            response: [
                "commands": [],
                "models": [],
            ])
        send.sendSystemInit(sessionId: sessionId)
    }

    /// host 发 `interrupt` control_request。默认 ack success 并 emit 一条
    /// `result.error_during_execution` 关掉 turn。
    func onInterrupt(requestId: String, send: MockCLISender) {
        send.ackControlSuccess(requestId: requestId)
        send.sendResultError(sessionId: sessionId, errors: ["interrupted"])
    }

    /// initialize / interrupt 之外的 control_request(`set_model` / `apply_flag_settings` 等)。
    /// 默认 ack success(空 response)。scenario override 来模拟错误 / 验证参数 / 等等。
    func onControlRequest(subtype: String, requestId: String, params: [String: Any], send: MockCLISender) {
        send.ackControlSuccess(requestId: requestId)
    }

    /// host 发用户消息。默认 echo 一条 user(用 host 给的 uuid),立刻发
    /// `result.success` —— turn 一发就完。
    ///
    /// 典型 override:
    /// - "turn 永远挂着" → echo 完不发 result
    /// - "assistant 流式回若干 chunk 再完结" → echo + sendAssistantText * N + sendResultSuccess
    /// - "permission 流" → echo + 发 control_request(can_use_tool) 给 host
    func onUserMessage(text: String, uuid: String?, send: MockCLISender) {
        if let uuid {
            send.echoUser(text: text, uuid: uuid, sessionId: sessionId)
        }
        send.sendResultSuccess(sessionId: sessionId)
    }

    /// host 回 mock 之前发出的 control_request(典型:mock 发了 `can_use_tool`,
    /// host 回 allow/deny)。默认 no-op。
    func onControlResponse(requestId: String, response: [String: Any], send: MockCLISender) {
        // 默认 no-op。
    }

    /// 任意未识别 type 的消息。默认 no-op,scenario 自行解析 raw 即可。
    func onUnknown(raw: [String: Any], send: MockCLISender) {
        // 默认 no-op。
    }
}

#endif
