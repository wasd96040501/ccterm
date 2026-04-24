import AgentSDK
import AppKit
import CoreText
import XCTest
@testable import ccterm

/// 覆盖 `UserBubbleComponent` 折叠路径的状态同步、几何、不变式。
///
/// 重点:
/// - CT vs 几何两阶段:state 翻转走 `relayouted` 不重跑 CT
/// - `canCollapse` 阈值
/// - selectables 折叠态高度 clamp
/// - 宽度变化保持 expanded state
/// - Builder 接受 sticky state(`expandedUserBubbles` 便利入口)
@MainActor
final class UserBubbleCollapseTests: XCTestCase {

    private let theme = TranscriptTheme.default
    private let testWidth: CGFloat = 900

    private func makeText(lines n: Int) -> String {
        (0..<n).map { "line \($0)" }.joined(separator: "\n")
    }

    private func layoutFor(
        lines n: Int,
        isExpanded: Bool = false
    ) -> UserBubbleComponent.Layout {
        let stableId = StableId(entryId: UUID(), locator: .whole)
        let input = UserBubbleComponent.Input(stableId: stableId, text: makeText(lines: n))
        let content = UserBubbleComponent.prepare(input, theme: theme)
        var state = UserBubbleComponent.State()
        state.isExpanded = isExpanded
        return UserBubbleComponent.layout(
            content, theme: theme, width: testWidth, state: state)
    }

    // MARK: - 1. 阈值下不折叠

    func testNoCollapseBelowThreshold() {
        let layout = layoutFor(lines: 10)
        XCTAssertFalse(UserBubbleComponent.canCollapse(layout: layout, theme: theme))
        var state = UserBubbleComponent.State()
        state.isExpanded = false
        XCTAssertFalse(UserBubbleComponent.shouldCollapse(layout: layout, state: state, theme: theme))
    }

    // MARK: - 2. min-hidden 守卫

    func testMinHiddenGuard() {
        let threshold = theme.userBubbleCollapseThreshold
        let minHidden = theme.userBubbleMinHiddenLines

        let borderline = layoutFor(lines: threshold + minHidden - 1)
        XCTAssertFalse(UserBubbleComponent.canCollapse(layout: borderline, theme: theme))

        let overThreshold = layoutFor(lines: threshold + minHidden)
        XCTAssertTrue(UserBubbleComponent.canCollapse(layout: overThreshold, theme: theme))
    }

    // MARK: - 3. 折叠态高度对应 threshold 条

    func testCollapsedHeightStrictlyLessThanExpanded() {
        let collapsed = layoutFor(lines: 20, isExpanded: false)
        let expanded = layoutFor(lines: 20, isExpanded: true)
        XCTAssertLessThan(collapsed.cachedHeight, expanded.cachedHeight)
    }

    // MARK: - 4. relayouted 快路径不重跑 CT

    /// state 翻、width 不变 → `relayouted` 复用 textLayout 引用(同一 CTLine)。
    func testRelayoutedReusesCT() {
        let layout = layoutFor(lines: 20, isExpanded: false)
        guard let firstLineBefore = layout.textLayout.lines.first else {
            return XCTFail("expected lines")
        }
        let beforeAddr = Unmanaged.passUnretained(firstLineBefore).toOpaque()

        var newState = UserBubbleComponent.State()
        newState.isExpanded = true
        guard let relaid = UserBubbleComponent.relayouted(layout, theme: theme, state: newState) else {
            return XCTFail("relayouted should return non-nil for state-only change")
        }

        guard let firstLineAfter = relaid.textLayout.lines.first else {
            return XCTFail("expected lines after relayout")
        }
        let afterAddr = Unmanaged.passUnretained(firstLineAfter).toOpaque()
        XCTAssertEqual(beforeAddr, afterAddr,
            "CTLine reference must be stable across state-only relayout")
    }

    // MARK: - 5. Builder sticky state → isExpanded 被填充

    func testBuilderAppliesExpandedSticky() {
        let id = UUID()
        let input = LocalUserInput(text: makeText(lines: 20), image: nil, planContent: nil)
        let single = SingleEntry(
            id: id,
            payload: .localUser(input),
            delivery: nil,
            toolResults: [:])
        let entry = MessageEntry.single(single)

        // Sticky 通过 expandedUserBubbles 便利入口构造
        let stickyExpanded: [StableId: any Sendable] = .expandedUserBubbles([id])
        let itemsExpanded = TranscriptRowBuilder.prepareAll(
            entries: [entry], theme: theme, width: testWidth,
            stickyStates: stickyExpanded)
        let itemsDefault = TranscriptRowBuilder.prepareAll(
            entries: [entry], theme: theme, width: testWidth,
            stickyStates: [:])

        // Heights:expanded > default(folded)
        XCTAssertEqual(itemsExpanded.count, 1)
        XCTAssertEqual(itemsDefault.count, 1)
        XCTAssertGreaterThan(itemsExpanded[0].cachedHeight,
                             itemsDefault[0].cachedHeight,
                             "sticky-expanded item must be taller than default folded")
    }

    // MARK: - 6. selectables 折叠态 clamp 高度

    func testSelectablesClampedWhenCollapsed() {
        let layout = layoutFor(lines: 20, isExpanded: false)
        var state = UserBubbleComponent.State()
        state.isExpanded = false
        let slots = UserBubbleComponent.selectables(layout, state: state)
        guard let slot = slots.first else { return XCTFail("expected slot") }

        let totalTextHeight = slot.layout.totalHeight
        let visibleTextHeight = layout.cachedHeight
            - 2 * theme.rowVerticalPadding
            - 2 * theme.bubbleVerticalPadding

        XCTAssertLessThan(slot.frameInRow.height, totalTextHeight)
        XCTAssertEqual(slot.frameInRow.height, visibleTextHeight, accuracy: 0.5)

        // 展开后恢复全量
        var expandedState = UserBubbleComponent.State()
        expandedState.isExpanded = true
        let expandedLayout = layoutFor(lines: 20, isExpanded: true)
        let slotsExpanded = UserBubbleComponent.selectables(expandedLayout, state: expandedState)
        guard let expSlot = slotsExpanded.first else {
            return XCTFail("expected slot after expand")
        }
        XCTAssertEqual(expSlot.frameInRow.height,
                       expandedLayout.textLayout.totalHeight, accuracy: 0.5)
    }

    // MARK: - 7. interactions:chevron toggleState

    func testChevronInteractionExposed() {
        let layout = layoutFor(lines: 20, isExpanded: false)
        var state = UserBubbleComponent.State()
        state.isExpanded = false
        let interactions = UserBubbleComponent.interactions(layout, state: state)
        XCTAssertEqual(interactions.count, 1, "long row exposes chevron interaction")

        let shortLayout = layoutFor(lines: 5)
        let shortInteractions = UserBubbleComponent.interactions(shortLayout, state: state)
        XCTAssertTrue(shortInteractions.isEmpty,
            "short row has no chevron interaction")
    }

    // MARK: - 8. width-only re-layout reflects new wrap

    func testWidthChangeChangesWrap() {
        let stableId = StableId(entryId: UUID(), locator: .whole)
        let longLines = (0..<20).map { i in
            "line \(i) with enough text to definitely wrap when the column gets narrow"
        }.joined(separator: "\n")
        let input = UserBubbleComponent.Input(stableId: stableId, text: longLines)
        let content = UserBubbleComponent.prepare(input, theme: theme)

        var state = UserBubbleComponent.State()
        state.isExpanded = true

        let wide = UserBubbleComponent.layout(
            content, theme: theme, width: testWidth, state: state)
        let narrow = UserBubbleComponent.layout(
            content, theme: theme, width: testWidth * 0.45, state: state)

        XCTAssertGreaterThan(narrow.textLayout.lines.count,
                             wide.textLayout.lines.count,
            "narrow width should wrap to more lines")
        XCTAssertGreaterThan(narrow.cachedHeight, wide.cachedHeight)
    }
}
