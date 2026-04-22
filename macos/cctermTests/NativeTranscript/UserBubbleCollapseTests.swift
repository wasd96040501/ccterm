import AppKit
import CoreText
import XCTest
@testable import ccterm

/// 覆盖 `UserBubbleRow` 折叠路径的状态同步、几何、不变式。
///
/// 重点：
/// - 排版 vs 几何两阶段：toggle 只跑几何，不重跑 CT
/// - `canCollapse` 阈值（lines >= threshold + minHiddenLines）
/// - selectableRegions 在折叠态的 height clamp（selection 不越过可见区）
/// - state 在 resize / 手动切换间的 sticky
@MainActor
final class UserBubbleCollapseTests: XCTestCase {

    private let theme = TranscriptTheme.default

    /// 宽度故意给够大——让 `lines.count` 恰好等于 `\n` 切分的段数，
    /// 不被 wrap 再切细。
    private let testWidth: CGFloat = 900

    private func makeText(lines n: Int) -> String {
        (0..<n).map { "line \($0)" }.joined(separator: "\n")
    }

    private func makeRow(lines: Int, stable: String = "test") -> UserBubbleRow {
        UserBubbleRow(text: makeText(lines: lines), theme: theme, stable: stable)
    }

    // MARK: - 1. 阈值下不折叠

    func testNoCollapseBelowThreshold() {
        let row = makeRow(lines: 10)
        row.makeSize(width: testWidth)
        XCTAssertFalse(row.canCollapse, "10 lines should be under collapse threshold")
        XCTAssertFalse(row.shouldCollapse)
        XCTAssertNil(row.chevronHitRectInRow(), "no chevron hit when not collapsible")
    }

    // MARK: - 2. min-hidden 守卫

    /// `threshold + minHiddenLines - 1` 行不够资格，`threshold + minHiddenLines` 才够。
    func testMinHiddenGuard() {
        let threshold = theme.userBubbleCollapseThreshold
        let minHidden = theme.userBubbleMinHiddenLines

        let borderline = makeRow(lines: threshold + minHidden - 1, stable: "a")
        borderline.makeSize(width: testWidth)
        XCTAssertFalse(borderline.canCollapse,
            "lines < threshold+minHidden should not be collapsible (saves the user 1~2 lines only)")

        let overThreshold = makeRow(lines: threshold + minHidden, stable: "b")
        overThreshold.makeSize(width: testWidth)
        XCTAssertTrue(overThreshold.canCollapse)
    }

    // MARK: - 3. 折叠态高度对应 threshold 条

    func testCollapsedHeightMatchesFirstNLines() {
        let threshold = theme.userBubbleCollapseThreshold
        let row = makeRow(lines: 20)

        // 默认 isExpanded=false → 折叠态
        row.makeSize(width: testWidth)
        XCTAssertTrue(row.shouldCollapse)
        let collapsedHeight = row.cachedHeight

        // Toggle 展开 → 全量高度
        row.isExpanded = true
        row.makeSize(width: testWidth)
        XCTAssertFalse(row.shouldCollapse)
        let expandedHeight = row.cachedHeight

        XCTAssertLessThan(collapsedHeight, expandedHeight,
            "collapsed height must be strictly less than full height")

        // 粗略验证折叠高度与 `threshold / 20` 行数成正比（允许 ±1 行误差）。
        // 用 first line 高度估算。
        // （严格的 pixel-exact 校验会耦合行距细节，这里只要相对关系正确。）
        let perLine = expandedHeight / CGFloat(20)
        let expectedCollapsedLow = perLine * CGFloat(threshold - 1)
        XCTAssertGreaterThan(collapsedHeight, expectedCollapsedLow,
            "collapsed should show close to \(threshold) lines")
    }

    // MARK: - 4. Toggle 不重跑 CT

    /// makeSize 两阶段实现的核心契约：state 变、width 未变时，textLayout 的
    /// `CTLine` 引用保持同一——说明没跑 CTTypesetter。`CTLine` 是 immutable CF
    /// 类型，address 稳定对应 "同一对象"。
    func testToggleDoesNotRetypeset() {
        let row = makeRow(lines: 20)
        row.makeSize(width: testWidth)

        guard let firstLine = row.currentTextLayoutForTesting.lines.first else {
            return XCTFail("expected at least one line")
        }
        let beforeAddr = Unmanaged.passUnretained(firstLine).toOpaque()

        row.isExpanded = true
        row.makeSize(width: testWidth)

        guard let firstLineAfter = row.currentTextLayoutForTesting.lines.first else {
            return XCTFail("expected lines after toggle")
        }
        let afterAddr = Unmanaged.passUnretained(firstLineAfter).toOpaque()

        XCTAssertEqual(beforeAddr, afterAddr,
            "CTLine reference must be stable across toggle (= no CT re-typeset)")
    }

    // MARK: - 5. Builder 传入 expandedUserBubbles → row.isExpanded 被填充

    /// Builder signature 的核心契约：`expandedUserBubbles` 里的 stableId
    /// 对应的 UserBubbleRow 构造时 `isExpanded` 必须为 true。
    func testBuilderAppliesExpandedState() {
        let id: UUID = UUID()
        let input = LocalUserInput(text: makeText(lines: 20), image: nil, planContent: nil)
        let single = SingleEntry(
            id: id,
            payload: .localUser(input),
            delivery: nil,
            toolResults: [:])
        let entry = MessageEntry.single(single)

        let rowsExpanded = TranscriptRowBuilder.build(
            entries: [entry],
            theme: .default,
            expandedUserBubbles: [AnyHashable(id)])
        let rowsDefault = TranscriptRowBuilder.build(
            entries: [entry],
            theme: .default,
            expandedUserBubbles: [])

        guard let exp = rowsExpanded.first as? UserBubbleRow,
              let def = rowsDefault.first as? UserBubbleRow else {
            return XCTFail("expected UserBubbleRow from localUser entry")
        }
        XCTAssertTrue(exp.isExpanded, "set membership must set isExpanded=true")
        XCTAssertFalse(def.isExpanded, "absent from set → default false")
    }

    // MARK: - 6. 外部 state 改写 + makeSize → 几何随之更新

    /// 模拟 controller 在 layout pass 前 sync row state 的场景：即使
    /// cachedWidth 已对齐（carry-over），翻 `isExpanded` 后再 makeSize 必须
    /// 使 `cachedHeight` 反映新 state。这是「layout 循环去掉 `where cachedWidth
    /// != width` 过滤」的行为保障。
    func testStateChangeReflectedInGeometry() {
        let row = makeRow(lines: 20)
        row.makeSize(width: testWidth)
        let collapsedHeight = row.cachedHeight

        // 外部 sync：改 isExpanded，但 width 不变
        row.isExpanded = true
        row.makeSize(width: testWidth)
        let expandedHeight = row.cachedHeight

        XCTAssertNotEqual(collapsedHeight, expandedHeight,
            "state-only change must trigger geometry recompute")
        XCTAssertGreaterThan(expandedHeight, collapsedHeight)

        // Idempotent：同 state 同 width 再调一次不改值
        row.makeSize(width: testWidth)
        XCTAssertEqual(row.cachedHeight, expandedHeight, accuracy: 0.01)
    }

    // MARK: - 7. selectableRegions 折叠态 clamp 高度

    /// 折叠时 region 的 `frameInRow.height` 必须 <= 可见文字区高度——drag 起点
    /// 不能落到隐藏行。这是 `regionEnd` clamp 的上游保障。
    func testSelectableRegionClampedWhenCollapsed() {
        let row = makeRow(lines: 20)
        row.makeSize(width: testWidth)
        XCTAssertTrue(row.shouldCollapse)

        guard let region = row.selectableRegions.first else {
            return XCTFail("expected one selectable region")
        }

        // Region 的 full layout 总高度（隐藏 + 可见）
        let totalTextHeight = region.layout.totalHeight
        // 可见文字区高度（bubble - 2*vPad）
        let visibleTextHeight = row.cachedHeight - 2 * theme.rowVerticalPadding - 2 * theme.bubbleVerticalPadding

        XCTAssertLessThan(region.frameInRow.height, totalTextHeight,
            "collapsed region height should be < full text height")
        XCTAssertEqual(region.frameInRow.height, visibleTextHeight, accuracy: 0.5,
            "region height should match visible text area")

        // 展开后 region height 恢复到全量
        row.isExpanded = true
        row.makeSize(width: testWidth)
        guard let expandedRegion = row.selectableRegions.first else {
            return XCTFail("expected region after expand")
        }
        XCTAssertEqual(expandedRegion.frameInRow.height, totalTextHeight, accuracy: 0.5)
    }

    // MARK: - 8. Chevron hit test 矩形尺寸 + 返回规则

    func testChevronHitRect() {
        let shortRow = makeRow(lines: 5)
        shortRow.makeSize(width: testWidth)
        XCTAssertNil(shortRow.chevronHitRectInRow(),
            "short row returns nil (no chevron)")

        let longRow = makeRow(lines: 20)
        longRow.makeSize(width: testWidth)
        guard let hit = longRow.chevronHitRectInRow() else {
            return XCTFail("long row should expose chevron hit rect")
        }
        XCTAssertEqual(hit.width, theme.chevronHitSize, accuracy: 0.01)
        XCTAssertEqual(hit.height, theme.chevronHitSize, accuracy: 0.01)
    }

    // MARK: - 9. Width 变化不影响 expanded state

    func testWidthChangePreservesExpandedState() {
        // 用长 per-line 文本——窄 width 下会 wrap 增加 line count，可验证"重排版
        // 发生了"。若 per-line 本身已经短到无论多宽都不 wrap，width 变化不会触
        // 发 lineRects 变化，断言没意义。
        let longLines = (0..<20).map { i in
            "line \(i) with enough text to definitely wrap when the column gets narrow"
        }.joined(separator: "\n")
        let row = UserBubbleRow(text: longLines, theme: theme, stable: "x")
        row.makeSize(width: testWidth)
        XCTAssertTrue(row.canCollapse)

        row.isExpanded = true
        row.makeSize(width: testWidth)
        XCTAssertFalse(row.shouldCollapse)
        let expandedHeightWide = row.cachedHeight
        let linesWide = row.currentTextLayoutForTesting.lines.count

        // 变窄 → 重排版，isExpanded 保持
        row.makeSize(width: testWidth * 0.45)
        XCTAssertTrue(row.isExpanded, "isExpanded survives width change")
        XCTAssertFalse(row.shouldCollapse,
            "still expanded after width change (sticky)")
        let linesNarrow = row.currentTextLayoutForTesting.lines.count
        XCTAssertGreaterThan(linesNarrow, linesWide,
            "narrow width should wrap to more lines")
        XCTAssertGreaterThan(row.cachedHeight, expandedHeightWide,
            "more wrap → taller bubble in expanded state")
    }
}

// MARK: - Test helper

extension UserBubbleRow {
    /// Expose internal `textLayout` for identity checks in the CT-reuse test.
    /// Kept internal to the test target via `@testable import`.
    var currentTextLayoutForTesting: TranscriptTextLayout {
        // Mirror runs on the same actor; reach into the stored property.
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            if child.label == "textLayout", let l = child.value as? TranscriptTextLayout {
                return l
            }
        }
        return .empty
    }
}
