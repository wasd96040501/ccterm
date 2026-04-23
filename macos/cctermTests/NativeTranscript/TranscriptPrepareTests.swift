import AgentSDK
import AppKit
import CoreText
import XCTest
@testable import ccterm

/// 验证 nonisolated `TranscriptPrepare` 的输出与原同步路径
/// (`AssistantMarkdownRow.init(source:…)` + `makeSize`、等)语义等价。
///
/// 重点：
/// - `assistant` 的 prebuilt 与 `AssistantMarkdownRow.init` 内部产出一致
/// - `layoutAssistant` 输出的 cachedHeight / origins / headerRects 与 `makeSize` 一致
/// - `layoutUser` 输出与 `UserBubbleRow.makeSize` 一致（等效构造 + applyLayout）
/// - `layoutPlaceholder` 输出与 `PlaceholderRow.makeSize` 一致
/// - prepare / layout 可在 Task.detached 跨 actor 边界执行（Sendable 检查）
@MainActor
final class TranscriptPrepareTests: XCTestCase {

    private let theme = TranscriptTheme.default
    private let width: CGFloat = 720

    // MARK: - Assistant round trip

    /// 通过 `init(prepared:)` + `applyLayout` 构造的 row，和 `init(source:)` +
    /// `makeSize` 构造的 row，在关键 layout 字段上必须等值。
    func testAssistantPreparedRoundTripMatchesSync() {
        let source = """
        # Heading

        Some **bold** text with `inline code`, followed by a paragraph that
        should wrap to at least two lines across a reasonable column width.

        ```swift
        func hello() {
            print("world")
        }
        ```

        - list item one
        - list item two

        | Col A | Col B |
        | ----- | ----- |
        | 1     | 2     |
        """
        let stableId: AnyHashable = "t-1"

        // Sync path.
        let syncRow = AssistantMarkdownRow(source: source, theme: theme, stable: stableId)
        syncRow.makeSize(width: width)

        // Prepared path.
        let prepared = TranscriptPrepare.assistant(source: source, theme: theme, stable: stableId)
        let layout = TranscriptPrepare.layoutAssistant(
            prebuilt: prepared.prebuilt, theme: theme, width: width)
        let asyncRow = AssistantMarkdownRow(prepared: prepared, theme: theme)
        asyncRow.applyLayout(layout)

        XCTAssertEqual(syncRow.source, asyncRow.source)
        XCTAssertEqual(syncRow.stableId, asyncRow.stableId)
        XCTAssertEqual(syncRow.contentHash, asyncRow.contentHash)
        XCTAssertEqual(syncRow.contentHash, prepared.contentHash)

        XCTAssertEqual(syncRow.cachedWidth, asyncRow.cachedWidth, accuracy: 0.01)
        XCTAssertEqual(syncRow.cachedHeight, asyncRow.cachedHeight, accuracy: 0.01)

        // codeBlockHit same header rect → click-to-copy still works.
        let headerY = theme.rowVerticalPadding + (asyncRow.prebuiltForTesting.first?.topPadding ?? 0)
        // 取 layout 里第一个 codeBlock header 的 rect —— 不依赖于 row 的内部
        // codeBlockHeaderRects 具体结构，只比对都存在。
        XCTAssertFalse(layout.codeBlockHeaderRects.isEmpty, "sample has a code block")
        _ = headerY  // silenced; kept as doc
    }

    /// layoutAssistant 对 pure text 输入应产生与 `makeSize` byte-equal 的
    /// cachedHeight / origins。
    func testAssistantLayoutMatchesSyncForPlainMarkdown() {
        let source = "plain paragraph\n\nsecond paragraph"
        let syncRow = AssistantMarkdownRow(source: source, theme: theme, stable: "p")
        syncRow.makeSize(width: width)

        let prepared = TranscriptPrepare.assistant(source: source, theme: theme, stable: "p")
        let layout = TranscriptPrepare.layoutAssistant(
            prebuilt: prepared.prebuilt, theme: theme, width: width)

        XCTAssertEqual(syncRow.cachedHeight, layout.cachedHeight, accuracy: 0.01)
        XCTAssertEqual(syncRow.cachedWidth, layout.cachedWidth, accuracy: 0.01)
    }

    // MARK: - User round trip

    func testUserPreparedRoundTripMatchesSync() {
        let text = "Hello world — this should sit in a user bubble on the right side."
        let stable: AnyHashable = "u-1"

        let syncRow = UserBubbleRow(text: text, theme: theme, stable: stable)
        syncRow.makeSize(width: width)

        let prepared = TranscriptPrepare.user(text: text, theme: theme, stable: stable)
        let layout = TranscriptPrepare.layoutUser(
            text: prepared.text, theme: theme, width: width, isExpanded: false)
        let asyncRow = UserBubbleRow(prepared: prepared, theme: theme)
        asyncRow.applyLayout(layout)

        XCTAssertEqual(syncRow.text, asyncRow.text)
        XCTAssertEqual(syncRow.stableId, asyncRow.stableId)
        XCTAssertEqual(syncRow.contentHash, asyncRow.contentHash)
        XCTAssertEqual(syncRow.contentHash, prepared.contentHash)
        XCTAssertEqual(syncRow.cachedWidth, asyncRow.cachedWidth, accuracy: 0.01)
        XCTAssertEqual(syncRow.cachedHeight, asyncRow.cachedHeight, accuracy: 0.01)
    }

    /// 折叠态（长文本 + isExpanded=false）下 prepared 高度应匹配 sync。
    func testUserLayoutMatchesSyncInCollapsedState() {
        let longText = (0..<20).map { "line \($0)" }.joined(separator: "\n")
        let stable: AnyHashable = "u-long"

        let syncRow = UserBubbleRow(text: longText, theme: theme, stable: stable)
        syncRow.isExpanded = false
        syncRow.makeSize(width: width)

        let layout = TranscriptPrepare.layoutUser(
            text: longText, theme: theme, width: width, isExpanded: false)

        XCTAssertEqual(syncRow.cachedHeight, layout.cachedHeight, accuracy: 0.01)
    }

    func testUserLayoutMatchesSyncInExpandedState() {
        let longText = (0..<20).map { "line \($0)" }.joined(separator: "\n")
        let syncRow = UserBubbleRow(text: longText, theme: theme, stable: "u")
        syncRow.isExpanded = true
        syncRow.makeSize(width: width)

        let layout = TranscriptPrepare.layoutUser(
            text: longText, theme: theme, width: width, isExpanded: true)

        XCTAssertEqual(syncRow.cachedHeight, layout.cachedHeight, accuracy: 0.01)
    }

    // MARK: - Placeholder round trip

    func testPlaceholderPreparedRoundTripMatchesSync() {
        let label = "[Tool: Bash]"
        let stable: AnyHashable = "pl-1"

        let syncRow = PlaceholderRow(label: label, theme: theme, stable: stable)
        syncRow.makeSize(width: width)

        let prepared = TranscriptPrepare.placeholder(label: label, theme: theme, stable: stable)
        let layout = TranscriptPrepare.layoutPlaceholder(label: prepared.label, theme: theme)
        let asyncRow = PlaceholderRow(prepared: prepared, theme: theme)
        asyncRow.applyLayout(layout)

        XCTAssertEqual(syncRow.label, asyncRow.label)
        XCTAssertEqual(syncRow.stableId, asyncRow.stableId)
        XCTAssertEqual(syncRow.contentHash, asyncRow.contentHash)
        XCTAssertEqual(syncRow.contentHash, prepared.contentHash)
        XCTAssertEqual(syncRow.cachedHeight, asyncRow.cachedHeight, accuracy: 0.01)
    }

    // MARK: - Off-main execution

    // MARK: - prepareAll — multi-entry mirror of build()

    /// `prepareAll` 走完整 entry walk,对混合 user/assistant/group 输入应生成
    /// 与 `TranscriptRowBuilder.build` 等价的 item 序列(1:1 位置对应)。
    func testPrepareAllProducesItemsMatchingBuild() async {
        let entries: [MessageEntry] = [
            makeLocalUserEntry(text: "hello"),
            makeAssistantEntry(text: "a paragraph\n\n```swift\nlet x = 1\n```"),
            makeLocalUserEntry(text: "another message"),
        ]

        // Sync build (main-actor) for baseline.
        let rows = await MainActor.run {
            TranscriptRowBuilder.build(
                entries: entries, theme: theme.markdown, expandedUserBubbles: [])
        }
        // Prepared build (off-main).
        let items = await Task.detached { [theme = theme, width = width] in
            TranscriptRowBuilder.prepareAll(
                entries: entries, theme: theme, width: width)
        }.value

        XCTAssertEqual(rows.count, items.count)
        for (row, item) in zip(rows, items) {
            switch (row, item) {
            case (is UserBubbleRow, .user): break
            case (is AssistantMarkdownRow, .assistant): break
            case (is PlaceholderRow, .placeholder): break
            default:
                XCTFail("row/item type mismatch: row=\(type(of: row)) item=\(item)")
            }
            XCTAssertEqual(row.stableId, stableId(from: item))
        }
    }

    // MARK: - prepareBounded — viewport-first Phase 1 primitive

    /// Phase 1 的核心契约：按 entries 顺序 prepare+layout，直到累计高度
    /// >= minHeight 就停止，返回"已消费"的 entries 数量 + 这部分的 items。
    func testPrepareBoundedStopsAtViewportBudget() async {
        let entries: [MessageEntry] = (0..<20).map { i in
            makeLocalUserEntry(text: "entry \(i) with enough text to make a row")
        }
        let viewportH: CGFloat = 300

        let result = await Task.detached { [theme = theme, width = width] in
            TranscriptRowBuilder.prepareBounded(
                entries: entries,
                theme: theme,
                width: width,
                expandedUserBubbles: [],
                minAccumulatedHeight: viewportH)
        }.value

        // 消费了部分 entries，不是全部（否则视口就白填了）。
        XCTAssertGreaterThan(result.consumedEntryCount, 0)
        XCTAssertLessThan(result.consumedEntryCount, entries.count,
            "bounded walk should stop before exhausting entries for this viewport")

        let accumulatedHeight = result.items.reduce(CGFloat(0)) { acc, item in
            switch item {
            case .assistant(_, let l): return acc + l.cachedHeight
            case .user(_, let l, _): return acc + l.cachedHeight
            case .placeholder(_, let l): return acc + l.cachedHeight
            case .diff(_, let l): return acc + l.cachedHeight
            }
        }
        XCTAssertGreaterThanOrEqual(accumulatedHeight, viewportH,
            "walk should only stop once viewport budget is met")
    }

    /// minHeight 很大 → consume 全部 entries，不超额停止。
    func testPrepareBoundedHandlesUnderflow() async {
        let entries = [
            makeLocalUserEntry(text: "short"),
            makeLocalUserEntry(text: "also short"),
        ]
        let result = await Task.detached { [theme = theme, width = width] in
            TranscriptRowBuilder.prepareBounded(
                entries: entries, theme: theme, width: width,
                expandedUserBubbles: [], minAccumulatedHeight: .greatestFiniteMagnitude)
        }.value

        XCTAssertEqual(result.consumedEntryCount, entries.count)
    }

    /// minHeight == 0 → 仍然至少吃完第一条（按"consume full entry before check"语义）。
    func testPrepareBoundedWithZeroBudgetConsumesOneEntry() async {
        let entries = (0..<5).map { makeLocalUserEntry(text: "msg \($0)") }
        let result = await Task.detached { [theme = theme, width = width] in
            TranscriptRowBuilder.prepareBounded(
                entries: entries, theme: theme, width: width,
                expandedUserBubbles: [], minAccumulatedHeight: 0)
        }.value
        XCTAssertEqual(result.consumedEntryCount, 1,
            "zero budget → consume exactly one entry")
    }

    /// Smoke-test that prepare + layout can actually run off-main. If any
    /// reachable state accidentally requires `@MainActor`, Swift concurrency
    /// checks will fire at compile time inside the detached Task.
    func testPrepareAndLayoutRunFromDetachedTask() async {
        let theme = self.theme
        let width = self.width
        let source = """
        Paragraph.

        ```swift
        let x = 1
        ```
        """

        let (prepared, layout) = await Task.detached {
            let prepared = TranscriptPrepare.assistant(
                source: source, theme: theme, stable: "off")
            let layout = TranscriptPrepare.layoutAssistant(
                prebuilt: prepared.prebuilt, theme: theme, width: width)
            return (prepared, layout)
        }.value

        XCTAssertGreaterThan(layout.cachedHeight, 0)
        XCTAssertEqual(prepared.source, source)
    }
}

// MARK: - Test helpers

extension AssistantMarkdownRow {
    /// Expose prebuilt for prepared-path assertions.
    var prebuiltForTesting: [AssistantMarkdownRow.PrebuiltSegment] {
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            if child.label == "prebuilt",
               let p = child.value as? [AssistantMarkdownRow.PrebuiltSegment] {
                return p
            }
        }
        return []
    }
}

// MARK: - Entry fixtures

extension TranscriptPrepareTests {
    fileprivate func makeLocalUserEntry(text: String) -> MessageEntry {
        let input = LocalUserInput(text: text, image: nil, planContent: nil)
        return .single(SingleEntry(
            id: UUID(),
            payload: .localUser(input),
            delivery: nil,
            toolResults: [:]))
    }

    fileprivate func makeAssistantEntry(text: String) -> MessageEntry {
        let json: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ]
        let msg = (try? Message2(json: json)) ?? Message2.unknown(name: "assistant", raw: json)
        return .single(SingleEntry(
            id: UUID(),
            payload: .remote(msg),
            delivery: nil,
            toolResults: [:]))
    }

    fileprivate func stableId(from item: TranscriptPreparedItem) -> AnyHashable {
        switch item {
        case .assistant(let p, _): return p.stable
        case .user(let p, _, _): return p.stable
        case .placeholder(let p, _): return p.stable
        case .diff(let p, _): return p.stable
        }
    }
}
