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

    // MARK: - .initialPaint with scrollHint

    /// 首次打开时 hint 对齐某个已存在的 entry id → Phase 1 围绕该 anchor 展开，
    /// scroll 锚到 (stableId, topOffset)。验证：anchor 在可视范围内，且相对 clip
    /// 顶部的偏移 ≈ 传入的 topOffset。
    func testInitialPaintWithScrollHintAnchors() throws {
        let h = TranscriptTestHarness(size: NSSize(width: 800, height: 600))
        let entries = TranscriptTestEntries.manyUsers(50)
        // 选一个中间偏后的 anchor
        let anchorEntry = entries[35]
        let hint = SavedScrollAnchor(entryId: anchorEntry.id, topOffset: 100)

        h.controller.setEntries(
            entries, reason: .initialPaint, themeChanged: false,
            scrollHint: hint)
        h.pumpLayout()
        h.flushRunLoop()

        // Anchor row 应该在 rows 里（Phase 1 + Phase 2 都挂了）
        guard let anchorY = h.documentY(of: anchorEntry.id) else {
            XCTFail("anchor row 丢失")
            return
        }
        // anchorY - clip.origin.y ≈ topOffset
        let observedOffset = anchorY - h.clipOriginY
        XCTAssertEqual(observedOffset, 100, accuracy: 2.0,
            "anchor 行应保持 topOffset=100，实际=\(observedOffset)")
    }

    /// hint 的 stableId 不在 entries 里（跨-session 切换场景）→ fallback 到
    /// `.bottom` 行为。末行可见、clipOriginY 显著 > 0。
    func testInitialPaintWithStaleHintFallsBackToBottom() throws {
        let h = TranscriptTestHarness(size: NSSize(width: 800, height: 600))
        let entries = TranscriptTestEntries.manyUsers(50)
        let staleHint = SavedScrollAnchor(entryId: UUID(), topOffset: 100)

        h.controller.setEntries(
            entries, reason: .initialPaint, themeChanged: false,
            scrollHint: staleHint)
        h.pumpLayout()
        h.flushRunLoop()

        let lastIdx = h.controller.rows.count - 1
        let visible = h.visibleRowRange()
        XCTAssertTrue(
            visible.location <= lastIdx && (visible.location + visible.length) > lastIdx,
            "stale hint 必须 fallback 到 .bottom（末行可视）")
        XCTAssertGreaterThan(h.clipOriginY, 10,
            "stale hint fallback 后 clipOriginY 应落在底部附近")
    }

    // MARK: - captureScrollHint

    /// 滚到中部 → captureScrollHint 返回非 nil，stableId 是当前顶可视 row。
    /// 贴底 → 返回 nil（避免强制恢复覆盖自然贴底行为）。
    func testCaptureScrollHintMiddleVsBottom() throws {
        let h = TranscriptTestHarness(size: NSSize(width: 800, height: 600))
        let entries = TranscriptTestEntries.manyUsers(30)
        h.controller.setEntries(entries, reason: .initialPaint, themeChanged: false)
        h.pumpLayout()
        h.flushRunLoop()

        // 贴底（.bottom 已是末位）→ captureScrollHint 应返回 nil
        XCTAssertNil(h.controller.captureScrollHint(),
            "贴底时 captureScrollHint 必须返回 nil (让下次贴底)")

        // 滚到中部
        h.clipView.setBoundsOrigin(NSPoint(x: 0, y: 200))
        h.pumpLayout()

        guard let hint = h.controller.captureScrollHint() else {
            XCTFail("中部 captureScrollHint 必须返回非 nil")
            return
        }
        // entryId 必须能在 rows 里找到对应 source entry
        let found = h.controller.rows.contains { row in
            TranscriptController.entryId(fromRowStableId: row.stableId) == hint.entryId
        }
        XCTAssertTrue(found, "hint.entryId 必须能反查到 rows 里的一行")
    }

    // MARK: - Pending / flush path (layout-not-ready)

    /// SwiftUI `.id(sessionId)` 重建 NSView 时，updateNSView 先于第一次 layout
    /// 触发——此时 clipView.bounds.height = 0。setEntries 必须**不跑 pipeline**，
    /// 而是把 args 存到 `pendingSetEntries`；等 AppKit layout 走完调
    /// `tableWidthChanged` 时 flush 出来，保证走 `budget=ok` 路径。
    func testLayoutNotReadyStashesPending() throws {
        // 不走 harness 的 layoutIfNeeded——直接造一个裸 scrollView 模拟刚 makeNSView
        // 还没 insert 进 window 的状态。
        let sv = TranscriptScrollView(frame: .zero)
        sv.controller.theme = .default

        XCTAssertEqual(sv.contentView.bounds.height, 0,
            "裸 scrollView 的 clipView 高度应为 0")

        let entries = TranscriptTestEntries.manyUsers(20)
        sv.controller.setEntries(entries, reason: .initialPaint, themeChanged: false)

        // pipeline 未跑，rows 应为空。
        XCTAssertEqual(sv.controller.rows.count, 0,
            "layout 未就绪时 setEntries 必须停在 pending，不跑 pipeline")

        // 模拟 layout：给 scrollView 一个真实 frame，AppKit tile → tableView
        // setFrameSize → controller.tableWidthChanged(width) → flush pending
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 800, height: 600)),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sv
        sv.frame = NSRect(origin: .zero, size: NSSize(width: 800, height: 600))
        sv.tile()
        window.layoutIfNeeded()
        window.displayIfNeeded()

        // 跑一下 run loop 让 Phase 2 Task 回到主线程合并完成
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertGreaterThan(sv.controller.rows.count, 0,
            "tableWidthChanged 应当 flush pending setEntries，rows 非空")
        Task { @MainActor [window] in window.close() }
    }
}
