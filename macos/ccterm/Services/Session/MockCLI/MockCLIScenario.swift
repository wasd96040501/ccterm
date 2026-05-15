#if DEBUG

import Foundation

/// UI test 用的 mock claude CLI 行为脚本。
///
/// 每个 scenario 对应一个特定的测试场景(stop 按钮、permission 流、流式输出 etc),
/// 子进程启动时由 `CCTERM_MOCK_CLI_SCENARIO` 环境变量选定。
///
/// 实现规范:
/// - scenario 类型必须无参 init。`MockCLIRegistry` 用 `() -> any MockCLIScenario` factory。
/// - 状态(sessionId、是否收到过 init、计数等)存类内可变属性即可——子进程单线程,
///   `MockCLIRunner` 串行化调用 `onStart` / `onIncoming`。
/// - 实现尽量贴近真 claude CLI 的行为(用 `MockCLISender` 的便捷方法发常见消息形状),
///   只在为了测试特定边界时偏离(如"故意不发 result 让 turn 永远挂着")。
///
/// 新增 scenario:
/// 1. 在 `Scenarios/<Name>Scenario.swift` 写一个新类型实现本协议
/// 2. 在 `MockCLIRegistry.scenarios` 注册名字 → factory
/// 3. UI test 通过 `launchEnvironment["CCTERM_MOCK_CLI_SCENARIO"] = "<Name>"` 选用
protocol MockCLIScenario: AnyObject {

    /// 子进程刚启动、stdin 还没有任何消息时调用一次。多数 scenario 不做事,等
    /// host 发 `initialize` control_request 再 react;特殊场景(如要先 emit
    /// 一条 "process died early" 信号)可以在这里发。
    func onStart(send: MockCLISender)

    /// 收到 host 的一行 JSON 时调用。`message` 是预解析的常见 shape;`.unknown`
    /// 路径下 scenario 可以读 `raw` 自行解析。
    func onIncoming(_ message: MockCLIIncoming, send: MockCLISender)
}

/// 默认实现:`onStart` 不做事。绝大多数 scenario 不需要覆盖。
extension MockCLIScenario {
    func onStart(send: MockCLISender) {}
}

#endif
