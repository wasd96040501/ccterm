import AgentSDK
import AppKit
import XCTest
@testable import ccterm

/// 覆盖 2026-04 居中内容列改动：
/// 1. `TranscriptTheme.maxContentWidth` 默认 720pt。
/// 2. window 宽 > 720 时 row 排版宽度被 clamp 到 720；窄时占满。
/// 3. `TranscriptController.contentInset(forRow:rowRect:)` 正确反映居中留白。
///
/// 不覆盖 live resize 分支（依赖 `NSView.inLiveResize`，测试里触发不到）和
/// 绘制层的 CTM 平移（视觉属性，靠手动验证）。
@MainActor
final class CenteredColumnTests: XCTestCase {

    func testMaxContentWidthDefault() {
        // 这是唯一一个硬编码期望值的 test —— 它测的就是"默认值是多少"。
        // 其它 test 应通过 `TranscriptTheme.default.maxContentWidth` 引用。
        XCTAssertEqual(TranscriptTheme.default.maxContentWidth, 720)
    }

    func testRowLayoutClampsAndContentInsetPositiveWhenWide() {
        let maxW = TranscriptTheme.default.maxContentWidth
        let width: CGFloat = maxW + 480
        let sv = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        sv.layoutSubtreeIfNeeded()
        let ctrl = sv.controller
        ctrl.theme = .default

        ctrl.setEntries([userEntry("Hello")], themeChanged: false)
        waitUntil { !ctrl.rows.isEmpty && ctrl.rows[0].cachedWidth > 0 }

        XCTAssertEqual(ctrl.rows.count, 1)
        XCTAssertEqual(ctrl.rows[0].cachedWidth, maxW, accuracy: 1)

        let rowRect = CGRect(x: 0, y: 0, width: width, height: ctrl.rows[0].cachedHeight)
        let inset = ctrl.contentInset(forRow: 0, rowRect: rowRect)
        XCTAssertEqual(inset, (width - maxW) / 2, accuracy: 1)
    }

    func testRowLayoutFullWidthAndNoInsetWhenNarrow() {
        let maxW = TranscriptTheme.default.maxContentWidth
        let width: CGFloat = maxW - 120
        let sv = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        sv.layoutSubtreeIfNeeded()
        let ctrl = sv.controller
        ctrl.theme = .default

        ctrl.setEntries([userEntry("Hi")], themeChanged: false)
        waitUntil { !ctrl.rows.isEmpty && ctrl.rows[0].cachedWidth > 0 }

        XCTAssertEqual(ctrl.rows[0].cachedWidth, width, accuracy: 1)

        let rowRect = CGRect(x: 0, y: 0, width: width, height: ctrl.rows[0].cachedHeight)
        let inset = ctrl.contentInset(forRow: 0, rowRect: rowRect)
        XCTAssertEqual(inset, 0, accuracy: 0.01)
    }

    func testContentInsetOutOfBoundsReturnsZero() {
        let sv = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        let ctrl = sv.controller
        // rows 为空：任何 idx 都应返回 0（不应崩溃）
        XCTAssertEqual(ctrl.contentInset(forRow: 0, rowRect: CGRect(x: 0, y: 0, width: 1000, height: 40)), 0)
        XCTAssertEqual(ctrl.contentInset(forRow: -1, rowRect: CGRect(x: 0, y: 0, width: 1000, height: 40)), 0)
    }

    // MARK: - Helpers

    private func userEntry(_ text: String) -> MessageEntry {
        let json: [String: Any] = [
            "type": "user",
            "uuid": UUID().uuidString,
            "message": [
                "role": "user",
                "content": text,
            ],
        ]
        let msg = (try? Message2(json: json)) ?? Message2.unknown(name: "user", raw: json)
        return .single(SingleEntry(
            id: UUID(),
            payload: .remote(msg),
            delivery: nil,
            toolResults: [:]))
    }

    /// `setEntries` 内部走 `Task` + `MainActor.run` apply，主线程跑完一个
    /// runloop tick 才会把 rows 和 cachedWidth 填好。pump 到 check 成立或超时。
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        if !check() {
            XCTFail("waitUntil timed out after \(timeout)s", file: file, line: line)
        }
    }
}
