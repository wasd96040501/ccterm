#if DEBUG

import Foundation

/// UI test 用的 mock claude CLI 行为脚本(最小契约)。
///
/// **大多数 scenario 不直接实现此协议,而是继承 `MockCLIBaseScenario`**——base
/// 提供"贴近真 claude CLI"的默认行为(initialize ack、interrupt ack、user echo
/// + result success...),scenario 只 override 偏离默认的钩子。直接实现此协议
/// 的场景:需要完全自定义路由 / 跳过默认解析(典型如 chaos test 想要直接读 raw
/// JSON 并随机 emit)。
///
/// 协议层不提供任何默认行为,故意保持"裸"——所有"mock claude 应该怎么行动" 都是
/// **test-specific** 的、写在 scenario 类里;`MockCLIRunner` / `MockCLISender` /
/// `MockCLIIncoming.parse` 只是脚手架,不替 scenario 做决定。
///
/// 注册:每个 scenario 必须在 `MockCLIRegistry.scenarios` 加一行 name → factory,
/// 名字与 UI test 里 `launchEnvironment["CCTERM_MOCK_CLI_SCENARIO"]` 的值匹配。
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
