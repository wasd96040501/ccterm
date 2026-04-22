import AgentSDK
import AppKit
import XCTest
@testable import ccterm

/// End-to-end scroll intent 行为测试。通过 `TranscriptTestHarness` 把
/// `TranscriptScrollView` 放进真实 NSWindow，验证 clipView 会按 intent 定位：
///
/// - 首次 entries → clipView 停在底部（`.bottom`）
/// - prepend 前缀 → 原首行的 documentY 保持不动（`.anchor`）
/// - pure append → clipOriginY 不变（`.preserve`，fast-path）
/// - viewportH=0 的脱离 window controller → Phase 1 至少挂多于 1 条（fallback）
@MainActor
final class TranscriptScrollIntentTests: XCTestCase {

    // MARK: - Bottom intent (首次打开)

    func testFirstPaintParksAtBottom() throws {
        let h = TranscriptTestHarness(size: NSSize(width: 800, height: 600))
        let entries = TranscriptTestEntries.manyUsers(50)
        h.setEntries(entries)

        // 末行必须可见（可视范围覆盖最后一行）。
        let visible = h.visibleRowRange()
        let lastIdx = h.controller.rows.count - 1
        XCTAssertGreaterThan(h.controller.rows.count, 10, "Phase 2 应已回灌，rows 至少几十")
        XCTAssertTrue(
            visible.location <= lastIdx && (visible.location + visible.length) > lastIdx,
            "末行必须落在可视 range 内，visible=\(visible) lastIdx=\(lastIdx)")

        // clipOriginY 应该显著 > 0（落在底部附近，不在顶部）。
        XCTAssertGreaterThan(h.clipOriginY, 10,
            "应 scroll 到底部，clipOriginY=\(h.clipOriginY) 不应近似 0")
    }

    // MARK: - Anchor intent (prepend 保位)

    func testPrependPreservesAnchor() throws {
        let h = TranscriptTestHarness(size: NSSize(width: 800, height: 600))

        // 起始：10 条。首次 → .bottom。rows[0] 的 documentY 记录下来。
        let tail = TranscriptTestEntries.manyUsers(10)
        h.setEntries(tail)

        let firstTailStable = h.controller.rows.first!.stableId
        let yBeforePrepend = h.documentY(of: firstTailStable)
        let clipYBefore = h.clipOriginY

        // 构造一个"先前的 20 条"（新 UUIDs，拼在 tail 之前）。
        let prefix = TranscriptTestEntries.manyUsers(20, prefix: "prev")
        let combined = prefix + tail
        h.setEntries(combined)

        // firstTailStable 还在 rows 里、documentY 比 prepend 前大（被挤到下方）。
        guard let yAfter = h.documentY(of: firstTailStable) else {
            XCTFail("prepend 后 firstTailStable 消失")
            return
        }
        XCTAssertGreaterThan(yAfter, yBeforePrepend ?? 0,
            "rows[0] 已被 prepend 挤到下方")

        // 关键：clipOriginY 应当跟随 anchor 调整（不等于 prepend 前那个值）。
        // 保值不变意味着首行当前"屏幕相对位置"不跳——
        //   yAfter - clipOriginY_after  ≈  yBefore - clipOriginY_before
        let screenOffsetBefore = (yBeforePrepend ?? 0) - clipYBefore
        let screenOffsetAfter = yAfter - h.clipOriginY
        XCTAssertEqual(screenOffsetBefore, screenOffsetAfter, accuracy: 1.0,
            "anchor row 在屏幕上的相对位置应保持不变：before=\(screenOffsetBefore) after=\(screenOffsetAfter)")
    }

    // MARK: - Preserve intent (pure append)

    func testPureAppendKeepsScrollPosition() throws {
        let h = TranscriptTestHarness(size: NSSize(width: 800, height: 600))
        let base = TranscriptTestEntries.manyUsers(30)
        h.setEntries(base)
        // 先往上滚到中部，模拟"用户正在读历史"。
        let midY: CGFloat = 200
        h.clipView.setBoundsOrigin(NSPoint(x: 0, y: midY))
        h.pumpLayout()

        // append 2 条新消息。
        let extended = base + TranscriptTestEntries.manyUsers(2, prefix: "live")
        h.setEntries(extended)

        XCTAssertEqual(h.clipOriginY, midY, accuracy: 2.0,
            "append 不应改变 clipOriginY（.preserve 语义）")
    }

    // MARK: - Viewport fallback (无 window)

    /// 不挂进 window 的 controller（clipView.bounds.height = 0）走 fallback。
    /// 原先的 bug：phase1Budget = 0 → prepareBoundedTail 第 1 条满足阈值立即返
    /// 回 → 只挂 1 行。fallback 后必须挂更多。
    func testBudgetFallbackProducesMultipleRows() throws {
        let tv = TranscriptTableView(frame: NSRect(x: 0, y: 0, width: 720, height: 0))
        let controller = TranscriptController(tableView: tv)
        controller.theme = .default
        tv.dataSource = controller
        tv.delegate = controller

        let entries = TranscriptTestEntries.manyUsers(50)
        controller.setEntries(entries, themeChanged: false)

        // setEntries bottom path 立即做 Phase 1 sync merge → rows 至少是 Phase 1 的尾部。
        // fallback-const = 400pt → 末尾应能放进 ~6-15 条（取决于具体高度）。
        XCTAssertGreaterThan(controller.rows.count, 1,
            "fallback 应让 Phase 1 挂多于 1 行，实际 rows=\(controller.rows.count)")
    }
}
