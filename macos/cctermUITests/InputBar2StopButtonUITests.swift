import XCTest

/// 验证 InputBar2 的 stop 按钮真的能中断 turn。
///
/// 走完整的"输入 → 发送 → CLI 挂起 → 点 stop → CLI ack"流程,但 CLI 是 mock
/// 的(`hangingTurn` scenario:故意不发 result,直到收到 interrupt 才回 ack +
/// `result.error_during_execution`),所以不依赖真 Claude CLI 也不污染 CoreData。
///
/// 测试模式接线见 [cctermUITests/CLAUDE.md](CLAUDE.md):
/// - `CCTERM_TEST_MODE=1` → in-memory repo + mock CLI 覆盖
/// - `CCTERM_MOCK_CLI_SCENARIO=hangingTurn` → 子进程跑 `HangingTurnScenario`
final class InputBar2StopButtonUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// stop 按钮中断 turn 后,InputBar2 切回 send 形态。
    ///
    /// 步骤:
    /// 1. send 按钮初始可见,stop 按钮不可见。
    /// 2. 点击 bar 让 NSTextView 拿到焦点,typeText("hi"),Cmd+Return 触发 send。
    /// 3. Mock CLI 不发 result → `isRunning=true` → bar 切到 stop 态。
    /// 4. 点击 stop → `interrupt()` 同步 `pendingTurnCount=0` → bar 立刻切回 send。
    @MainActor
    func testStopButtonCancelsRunningState() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CCTERM_TEST_MODE": "1",
            "CCTERM_MOCK_CLI_SCENARIO": "hangingTurn",
        ]
        app.launch()

        let sendButton = app.buttons["InputBar2.SendButton"]
        let stopButton = app.buttons["InputBar2.StopButton"]

        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 10),
            "send button should be present on launch")
        XCTAssertFalse(stopButton.exists, "stop button should not be visible before sending")

        // NSTextView 不直接吃 a11y query — 点 send 按钮左侧的 bar 区让焦点落到 InputTextView
        let barCenter = sendButton.coordinate(withNormalizedOffset: CGVector(dx: -10, dy: 0.5))
        barCenter.click()
        app.typeText("hi")
        app.typeKey("\r", modifierFlags: .command)

        // Mock CLI 不发 result,所以 turn 一直挂着 → stop 按钮可见
        XCTAssertTrue(
            stopButton.waitForExistence(timeout: 5),
            "stop button should appear after sending (mock CLI holds turn)")
        XCTAssertFalse(sendButton.exists, "send button should be hidden while running")

        // 核心断言:点 stop 必须把 bar 切回 send
        stopButton.click()

        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 3),
            "send button should return after stop (interrupt resets pendingTurnCount)")
        XCTAssertFalse(stopButton.exists, "stop button should be gone after interrupt")
    }
}
