import Foundation
import SwiftUI

/// 进程入口。**唯一带 `@main` 的类型**。
///
/// 默认转发到 `CCTermApp.main()`(SwiftUI app)。仅 DEBUG 下识别 `CCTERM_RUN_AS_MOCK_CLI=1`
/// 环境变量,识别到则改走 `MockCLIRunner.run()`(读 stdin、写 stdout 行级 JSON,
/// 跟真 claude CLI 协议一致),用作 UI test 的"mock claude 子进程"。
///
/// 为什么需要这个 wrapper:UI test 的 mock CLI 需要一个可执行的二进制,直接复用
/// 当前 ccterm 二进制(在 child 进程里改走 mock 路径)避免维护单独的 SPM target。
/// 父进程仍是常规 SwiftUI app,子进程一进入 main 就 fork 到 `MockCLIRunner.run()`,
/// 不会触碰 SwiftUI / CoreData 等子系统。
@main
struct AppEntryPoint {
    static func main() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CCTERM_RUN_AS_MOCK_CLI"] == "1" {
            MockCLIRunner.run()
        }
        #endif
        CCTermApp.main()
    }
}
