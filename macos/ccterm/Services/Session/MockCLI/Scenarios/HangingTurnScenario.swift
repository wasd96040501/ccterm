#if DEBUG

import Foundation

/// "turn 永远挂着"的 scenario:host 发用户消息后,mock 只 echo 不发 result,
/// `isRunning` 持续为 true,直到 host 发 `interrupt` 才被 base 的默认 `onInterrupt`
/// 关掉 turn。
///
/// 服务对象:`InputBar2StopButtonUITests` —— 验证 stop 按钮真的能中断 turn。
/// 其它 control_request(initialize 等)都走 `MockCLIBaseScenario` 默认行为,
/// 这里只 override 唯一一个偏离默认的钩子。
final class HangingTurnScenario: MockCLIBaseScenario {
    override func onUserMessage(text: String, uuid: String?, send: MockCLISender) {
        if let uuid {
            send.echoUser(text: text, uuid: uuid, sessionId: sessionId)
        }
        // 故意不发 result —— turn 一直挂着。
    }
}

#endif
