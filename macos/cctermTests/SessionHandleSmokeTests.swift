import XCTest
import AgentSDK
@testable import ccterm

/// 真实 CLI 子进程 smoke test。仿照 AgentSDK/Sources/SmokeTest/main.swift。
final class SessionHandleSmokeTests: XCTestCase {

    /// SessionHandle + AgentSDK.Session 完整流程：
    /// start → sendMessage → 收到 system.init + assistant + result。
    @MainActor
    func testSessionHandle_fullFlow() async throws {
        let stack = CoreDataStack(inMemory: true)
        let repository = SessionRepository(coreDataStack: stack)
        let handle = SessionHandle(sessionId: "smoke-test", repository: repository)

        let config = SessionConfiguration(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            permissionMode: .default,
            maxTurns: 1
        )
        let agentSession = Session(configuration: config)

        handle.attach(agentSession)
        try await agentSession.start()
        handle.status = .idle

        // 发消息，CLI 会回 system.init + assistant + result
        let turnDone = expectation(description: "turn ended (status back to idle)")

        // 观察 status 变化：responding → idle 表示一轮结束
        var gotInit = false
        let observation = withObservationTracking {
            _ = handle.status
            _ = handle.cwd
        } onChange: { }
        // 用轮询检查，因为 @Observable 的 onChange 只触发一次
        _ = observation

        agentSession.sendMessage("Say hello in one sentence.")
        handle.status = .responding

        // 轮询等待 turn 结束，最多 15 秒
        Task { @MainActor in
            for _ in 0..<150 {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if handle.cwd != nil { gotInit = true }
                if gotInit && handle.status == .idle {
                    turnDone.fulfill()
                    return
                }
            }
        }

        await fulfillment(of: [turnDone], timeout: 20)

        NSLog("[SmokeTest] cwd=%@", handle.cwd ?? "nil")
        NSLog("[SmokeTest] status=%d", handle.status == .idle ? 1 : 0)

        XCTAssertNotNil(handle.cwd, "system.init should set cwd")
        XCTAssertEqual(handle.status, .idle, "status should be idle after turn")

        handle.detach()
    }
}
