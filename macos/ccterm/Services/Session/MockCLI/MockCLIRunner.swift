#if DEBUG

import Foundation

/// Mock claude CLI 子进程入口。
///
/// 进程结构(由 `AppEntryPoint` 调度):
/// ```
///   父进程(ccterm.app,XCUI test 启动) ──spawn──▶ 子进程(同一 ccterm 二进制,
///                                                      但 CCTERM_RUN_AS_MOCK_CLI=1
///                                                      → 走 MockCLIRunner.run())
/// ```
///
/// 通信:
/// - 父→子:stdin 一行一条 JSON(claude CLI 的 stream-json 协议)。
/// - 子→父:stdout 一行一条 JSON(同上)。
/// - stderr 用于 scenario 找不到 / 解析错的诊断输出。
///
/// 运行模型:
/// - 单线程同步。`scenario.onStart` → `scenario.onIncoming(...)` 按序串行。
/// - scenario 收到消息可立即写 stdout(同方法内)。
/// - stdin 出现 EOF 或被 close → 子进程退出 0。
enum MockCLIRunner {

    /// 入口。**不返回**:要么 `exit(0)` 结束,要么 `exit(1)` 出错。
    static func run() -> Never {
        let env = ProcessInfo.processInfo.environment
        let scenarioName = env["CCTERM_MOCK_CLI_SCENARIO"] ?? ""

        guard let scenario = MockCLIRegistry.scenario(named: scenarioName) else {
            let names = MockCLIRegistry.scenarios.keys.sorted().joined(separator: ", ")
            writeStderr("[MockCLI] no scenario registered for name=\(scenarioName)\n")
            writeStderr("[MockCLI] available: \(names)\n")
            exit(1)
        }

        let stdout = FileHandle.standardOutput
        let sender = MockCLISender { data in
            stdout.write(data)
        }

        scenario.onStart(send: sender)

        readStdinLoop { json in
            let incoming = MockCLIIncoming.parse(json)
            scenario.onIncoming(incoming, send: sender)
        }

        // stdin EOF — host 关掉了 pipe(典型:SessionHandle2.stop 走 close),
        // 干净退出让 onProcessExit(0) 触发常规清理路径。
        exit(0)
    }

    // MARK: - I/O helpers

    private static func readStdinLoop(handle: (_ json: [String: Any]) -> Void) {
        let stdin = FileHandle.standardInput
        var buffer = Data()
        let newline = UInt8(ascii: "\n")

        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { return }  // EOF
            buffer.append(chunk)

            while let idx = buffer.firstIndex(of: newline) {
                let lineData = buffer[buffer.startIndex..<idx]
                buffer.removeSubrange(buffer.startIndex...idx)
                guard !lineData.isEmpty else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    if let s = String(data: lineData, encoding: .utf8) {
                        writeStderr("[MockCLI] bad JSON line: \(s)\n")
                    }
                    continue
                }
                handle(json)
            }
        }
    }

    private static func writeStderr(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

#endif
