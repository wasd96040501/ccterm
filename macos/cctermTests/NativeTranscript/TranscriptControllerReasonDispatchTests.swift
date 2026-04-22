import AgentSDK
import AppKit
import XCTest
@testable import ccterm

/// `TranscriptController.setEntries(_:reason:themeChanged:)` 的 dispatch 行为测试。
/// 意图**由 caller 传入**——controller 不再从 delta 形状推断——所以按 reason
/// 枚举逐 case 验证最终 scroll / rows 落点。
///
/// 通过 `TranscriptTestHarness` 装入真实 NSWindow，让 clipView / `rect(ofRow:)`
/// 正常工作。
@MainActor
final class TranscriptControllerReasonDispatchTests: XCTestCase {

    // MARK: - .idle 短路

    func testIdleReasonShortCircuits() throws {
        let h = TranscriptTestHarness(size: NSSize(width: 800, height: 600))
        h.controller.setEntries(
            TranscriptTestEntries.manyUsers(5),
            reason: .idle,
            themeChanged: false)
        h.pumpLayout()
        h.flushRunLoop()

        XCTAssertEqual(h.controller.rows.count, 0,
            ".idle 必须短路，rows 保持为空")
    }

    // MARK: - .initialPaint → .bottom

    func testInitialPaintLandsAtBottom() throws {
        let h = TranscriptTestHarness(size: NSSize(width: 800, height: 600))
        let entries = TranscriptTestEntries.manyUsers(50)
        h.controller.setEntries(entries, reason: .initialPaint, themeChanged: false)
        h.pumpLayout()
        h.flushRunLoop()

        XCTAssertGreaterThan(h.controller.rows.count, 10, "Phase 2 应已回灌")

        let lastIdx = h.controller.rows.count - 1
        let visible = h.visibleRowRange()
        XCTAssertTrue(
            visible.location <= lastIdx && (visible.location + visible.length) > lastIdx,
            "末行必须落在可视 range 内")
        XCTAssertGreaterThan(h.clipOriginY, 10,
            "clipOriginY 应显著 > 0（落在底部附近），实际=\(h.clipOriginY)")
    }

    // MARK: - .prependHistory → .anchor(rows[0])

    func testPrependHistoryAnchorsToFirstTailRow() throws {
        let h = TranscriptTestHarness(size: NSSize(width: 800, height: 600))

        // Phase A: tail 10 条，首帧 .bottom。
        let tail = TranscriptTestEntries.manyUsers(10)
        h.controller.setEntries(tail, reason: .initialPaint, themeChanged: false)
        h.pumpLayout()
        h.flushRunLoop()

        let firstTailStable = h.controller.rows.first!.stableId
        let yBefore = h.documentY(of: firstTailStable) ?? 0
        let clipYBefore = h.clipOriginY

        // Phase B: prepend 20 条 prefix。
        let prefix = TranscriptTestEntries.manyUsers(20, prefix: "prev")
        let combined = prefix + tail
        h.controller.setEntries(combined, reason: .prependHistory, themeChanged: false)
        h.pumpLayout()
        h.flushRunLoop()

        guard let yAfter = h.documentY(of: firstTailStable) else {
            XCTFail(".prependHistory 后 firstTailStable 丢失")
            return
        }
        XCTAssertGreaterThan(yAfter, yBefore,
            "prepend 后 firstTailStable 被挤到下方")

        let screenOffsetBefore = yBefore - clipYBefore
        let screenOffsetAfter = yAfter - h.clipOriginY
        XCTAssertEqual(screenOffsetBefore, screenOffsetAfter, accuracy: 1.0,
            "anchor 行在屏幕上相对位置必须保持")
    }

    // MARK: - .liveAppend → .preserve + 尾部 insert

    func testLiveAppendPreservesScrollAndAppendsOnlySuffix() throws {
        let h = TranscriptTestHarness(size: NSSize(width: 800, height: 600))

        let base = TranscriptTestEntries.manyUsers(30)
        h.controller.setEntries(base, reason: .initialPaint, themeChanged: false)
        h.pumpLayout()
        h.flushRunLoop()

        // 用户滚到中部
        let midY: CGFloat = 200
        h.clipView.setBoundsOrigin(NSPoint(x: 0, y: midY))
        h.pumpLayout()
        let rowsBefore = h.controller.rows.count

        let extended = base + TranscriptTestEntries.manyUsers(2, prefix: "live")
        h.controller.setEntries(extended, reason: .liveAppend, themeChanged: false)
        h.pumpLayout()
        h.flushRunLoop()

        XCTAssertEqual(h.clipOriginY, midY, accuracy: 2.0,
            "liveAppend 不改 clipOriginY")
        XCTAssertEqual(h.controller.rows.count, rowsBefore + 2,
            "仅追加 2 行，既有行不重建")
    }

    // MARK: - .update → .preserve + 全量 diff

    func testUpdateReasonPreservesScroll() throws {
        let h = TranscriptTestHarness(size: NSSize(width: 800, height: 600))

        let base = TranscriptTestEntries.manyUsers(20)
        h.controller.setEntries(base, reason: .initialPaint, themeChanged: false)
        h.pumpLayout()
        h.flushRunLoop()

        let midY: CGFloat = 150
        h.clipView.setBoundsOrigin(NSPoint(x: 0, y: midY))
        h.pumpLayout()

        // 同 entries 再推一次（模拟 tool_result resolve 等 in-place 更新）
        h.controller.setEntries(base, reason: .update, themeChanged: true)
        h.pumpLayout()
        h.flushRunLoop()

        XCTAssertEqual(h.clipOriginY, midY, accuracy: 2.0,
            ".update 必须保住 clipOriginY")
    }

    // MARK: - Signature short-circuit

    /// 同 signature + 同 theme + 非 .idle reason → 立即返回。
    /// 用 .update 触发（.initialPaint 等首次加载走满管线）。
    func testEqualSignatureShortCircuits() throws {
        let h = TranscriptTestHarness(size: NSSize(width: 800, height: 600))
        let entries = TranscriptTestEntries.manyUsers(10)

        h.controller.setEntries(entries, reason: .initialPaint, themeChanged: false)
        h.pumpLayout()
        h.flushRunLoop()
        let rowsAfterPaint = h.controller.rows.count

        // 再次喂同一批 entries（.update）——短路应当不改 rows。
        h.controller.setEntries(entries, reason: .update, themeChanged: false)
        h.pumpLayout()
        // 不 flushRunLoop: short-circuit 立即返回，不 schedule Phase 2 task
        XCTAssertEqual(h.controller.rows.count, rowsAfterPaint,
            "signature+theme 等价必须短路")
    }
}
