import XCTest

/// InputBar2 stop 按钮 / ESC 中断的 UI 测试。
///
/// 配合 `--ui-test-skip-bootstrap` 启动参数:`SessionManager2` 创建的 handle 会
/// 跳过 CLI bootstrap,`send` 入口同步 `pendingTurnCount += 1` → `isRunning=true`,
/// bar 切到 stop 形态;无真实 CLI,turn 不会因 `.result` 自动归零,可以稳定测试
/// stop 是否真把它归零。
///
/// 测试不依赖 Claude CLI 是否已安装。
final class InputBar2StopButtonUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 1. send 按钮初始可见。
    /// 2. 输入文字 → Cmd+Return → bar 切到 stop 态。
    /// 3. 点击 stop → bar 切回 send 态(本次 PR 修的核心 bug:之前 `interrupt()`
    ///    被 `guard status == .responding` 拦下,导致点了 stop 按钮 isRunning
    ///    不归零、UI 停在 stop 态)。
    @MainActor
    func testStopButtonCancelsRunningState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-skip-bootstrap"]
        app.launch()

        let sendButton = app.buttons["InputBar2.SendButton"]
        let stopButton = app.buttons["InputBar2.StopButton"]

        XCTAssertTrue(sendButton.waitForExistence(timeout: 10),
                      "send button should be present on launch")
        XCTAssertFalse(stopButton.exists, "stop button should not be visible before sending")

        // 通过 send 按钮所在位置反推 bar 区域:点击 bar 左侧文字输入区让焦点落到
        // TextInputView(NSTextView 不通过 a11y id 直接 query)
        let barCenter = sendButton.coordinate(withNormalizedOffset: CGVector(dx: -10, dy: 0.5))
        barCenter.click()
        app.typeText("hello")

        // Cmd+Return 触发 onCommandReturn → handle.send
        app.typeKey("\r", modifierFlags: .command)

        XCTAssertTrue(stopButton.waitForExistence(timeout: 3),
                      "stop button should appear after sending (isRunning=true)")
        XCTAssertFalse(sendButton.exists, "send button should be hidden while running")

        // 核心断言:点 stop 后必须真切回 send 态
        stopButton.click()

        XCTAssertTrue(sendButton.waitForExistence(timeout: 3),
                      "send button should return after clicking stop (interrupt should reset pendingTurnCount)")
        XCTAssertFalse(stopButton.exists, "stop button should be gone after interrupt")
    }

    /// ESC 键在 isRunning 时等价于点 stop。`InputBarView2.swift` 中
    /// `onEscape: { if isRunning { onStop() } }`。
    @MainActor
    func testEscapeKeyCancelsRunningState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-skip-bootstrap"]
        app.launch()

        let sendButton = app.buttons["InputBar2.SendButton"]
        let stopButton = app.buttons["InputBar2.StopButton"]

        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))

        let barCenter = sendButton.coordinate(withNormalizedOffset: CGVector(dx: -10, dy: 0.5))
        barCenter.click()
        app.typeText("hello")
        app.typeKey("\r", modifierFlags: .command)

        XCTAssertTrue(stopButton.waitForExistence(timeout: 3))

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        XCTAssertTrue(sendButton.waitForExistence(timeout: 3),
                      "send button should return after pressing ESC while running")
    }
}
