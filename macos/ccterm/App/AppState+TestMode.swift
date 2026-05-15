#if DEBUG

import Foundation

/// UI test 模式装配。app 进程启动时通过环境变量与 XCUI test runner 握手:
///
/// | 环境变量                       | 含义                                           |
/// |--------------------------------|------------------------------------------------|
/// | `CCTERM_TEST_MODE=1`           | 总开关。开了才走 in-memory repo / mock CLI     |
/// | `CCTERM_MOCK_CLI_SCENARIO=foo` | mock CLI 子进程要跑哪个 scenario(参看 Registry)|
///
/// 作用:
/// 1. 切换 `SessionManager2` 用 `InMemorySessionRepository`,避免把测试数据写进
///    主 CoreData store(脏数据)。
/// 2. 给 `SessionHandle2.mockCLIOverride` 注入 binary path + env,让后续
///    `ensureStarted` spawn 的"CLI 子进程"实际是当前 ccterm 二进制(走 `AppEntryPoint`
///    的 mock 分支,跑指定 scenario)。
///
/// 仅 DEBUG。release build 此文件整体不参与编译。
extension AppState {

    /// 在 `init` 早期调用。返回值是测试模式专用的 `SessionManager2`(走 in-memory repo);
    /// 没启用测试模式则返回 nil,调用方按常规路径构造。
    static func applyTestModeIfNeeded() -> SessionManager2? {
        let env = ProcessInfo.processInfo.environment
        guard env["CCTERM_TEST_MODE"] == "1" else { return nil }

        let scenario = env["CCTERM_MOCK_CLI_SCENARIO"] ?? ""
        guard let executable = Bundle.main.executablePath else {
            // 没 executable path 几乎不可能(系统接口保证),但 fallback 仍要安全:不启用 mock CLI
            return SessionManager2(repository: InMemorySessionRepository())
        }

        SessionHandle2.mockCLIOverride = MockCLIOverride(
            binaryPath: executable,
            env: [
                "CCTERM_RUN_AS_MOCK_CLI": "1",
                "CCTERM_MOCK_CLI_SCENARIO": scenario,
            ]
        )

        return SessionManager2(repository: InMemorySessionRepository())
    }
}

#endif
