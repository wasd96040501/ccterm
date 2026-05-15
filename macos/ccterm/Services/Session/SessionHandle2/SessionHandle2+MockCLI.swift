#if DEBUG

import Foundation
import AgentSDK

/// UI test 模式下注入的 CLI 子进程覆盖。
///
/// `AppState+TestMode` 在检测到 `CCTERM_TEST_MODE=1` 时设值,`SessionHandle2.makeAgentConfig`
/// 检测到非 nil 时把 `binaryPath`(执行二进制)和 `env`(子进程环境变量)替换掉,
/// CLI 真就 spawn 当前 ccterm 二进制走 mock 路径(详见 `AppEntryPoint`)。
///
/// 进程级 — 一旦设值就影响后续所有 `SessionHandle2.ensureStarted`;UI test 是
/// 单进程单 scenario 的,不需要 per-handle 粒度。
struct MockCLIOverride {

    /// 直接传给 `SessionConfiguration.binaryPath`。常规情况就是 `Bundle.main.executablePath!`。
    let binaryPath: String

    /// 直接传给 `SessionConfiguration.env`。至少包含
    /// `CCTERM_RUN_AS_MOCK_CLI=1` + `CCTERM_MOCK_CLI_SCENARIO=<name>`。
    let env: [String: String]
}

extension SessionHandle2 {

    /// 全局开关。`nil` 表示生产模式(走真 claude CLI),非 nil 表示 UI test 模式。
    /// 仅 `AppState+TestMode` 在 app 启动时设一次,后续不动。
    @MainActor static var mockCLIOverride: MockCLIOverride?
}

#endif
