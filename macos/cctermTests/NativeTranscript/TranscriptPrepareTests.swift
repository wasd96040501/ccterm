import AgentSDK
import AppKit
import CoreText
import XCTest
@testable import ccterm

/// 验证 component-level prepare/layout 流程的语义。
///
/// 重点:
/// - 每个 component 的 `prepare → layout → cachedHeight` 链路自洽
/// - prepare/layout 跨 actor 边界(Sendable 保证)
/// - `prepareAll` / `prepareBounded` 的 viewport-first 契约
@MainActor
final class TranscriptPrepareTests: XCTestCase {

    private let theme = TranscriptTheme.default
    private let width: CGFloat = 720

    // MARK: - Component round-trip

    func testAssistantContentLayoutHasContentSizes() {
        let source = """
        # Heading

        Some **bold** text with `inline code`.

        ```swift
        func hello() {
            print("world")
        }
        ```
        """
        let stableId = StableId(entryId: UUID(), locator: .whole)
        let input = AssistantMarkdownComponent.Input(stableId: stableId, source: source)
        let content = AssistantMarkdownComponent.prepare(input, theme: theme)
        let layout = AssistantMarkdownComponent.layout(
            content, theme: theme, width: width, state: .default)

        XCTAssertGreaterThan(layout.cachedHeight, 0)
        XCTAssertEqual(layout.cachedWidth, width, accuracy: 0.01)
        XCTAssertFalse(layout.codeBlockHeaderRects.isEmpty,
            "sample has a code block")
    }

    func testUserBubbleLayoutMatchesCollapsedVsExpanded() {
        let longText = (0..<20).map { "line \($0)" }.joined(separator: "\n")
        let stableId = StableId(entryId: UUID(), locator: .whole)
        let input = UserBubbleComponent.Input(stableId: stableId, text: longText)
        let content = UserBubbleComponent.prepare(input, theme: theme)

        var collapsedState = UserBubbleComponent.State()
        collapsedState.isExpanded = false
        let collapsed = UserBubbleComponent.layout(
            content, theme: theme, width: width, state: collapsedState)

        var expandedState = UserBubbleComponent.State()
        expandedState.isExpanded = true
        let expanded = UserBubbleComponent.layout(
            content, theme: theme, width: width, state: expandedState)

        XCTAssertLessThan(collapsed.cachedHeight, expanded.cachedHeight,
            "collapsed bubble must be shorter than expanded")
    }

    func testPlaceholderLayoutFixedHeight() {
        let stableId = StableId(entryId: UUID(), locator: .whole)
        let input = PlaceholderComponent.Input(stableId: stableId, label: "[Tool: Bash]")
        let content = PlaceholderComponent.prepare(input, theme: theme)
        let l1 = PlaceholderComponent.layout(content, theme: theme, width: 400, state: ())
        let l2 = PlaceholderComponent.layout(content, theme: theme, width: 800, state: ())
        XCTAssertEqual(l1.cachedHeight, l2.cachedHeight,
            "placeholder height is width-independent")
        XCTAssertEqual(l1.cachedHeight,
            theme.placeholderHeight + 2 * theme.rowVerticalPadding,
            accuracy: 0.01)
    }

    // MARK: - prepareAll

    /// `prepareAll` 把 entries dispatch 到对应 component。
    func testPrepareAllProducesItemsByComponentTag() async {
        let entries: [MessageEntry] = [
            makeLocalUserEntry(text: "hello"),
            makeAssistantEntry(text: "a paragraph"),
            makeLocalUserEntry(text: "another"),
        ]

        let items = await Task.detached { [theme = theme, width = width] in
            TranscriptRowBuilder.prepareAll(
                entries: entries, theme: theme, width: width)
        }.value

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].tag, UserBubbleComponent.tag)
        XCTAssertEqual(items[1].tag, AssistantMarkdownComponent.tag)
        XCTAssertEqual(items[2].tag, UserBubbleComponent.tag)
    }

    // MARK: - prepareBounded

    func testPrepareBoundedStopsAtViewportBudget() async {
        let entries: [MessageEntry] = (0..<20).map { i in
            makeLocalUserEntry(text: "entry \(i) with enough text to make a row")
        }
        let viewportH: CGFloat = 300

        let result = await Task.detached { [theme = theme, width = width] in
            TranscriptRowBuilder.prepareBounded(
                entries: entries, theme: theme, width: width,
                stickyStates: [:],
                minAccumulatedHeight: viewportH)
        }.value

        XCTAssertGreaterThan(result.consumedEntryCount, 0)
        XCTAssertLessThan(result.consumedEntryCount, entries.count,
            "bounded walk should stop before exhausting entries for this viewport")

        let accumulatedHeight = result.items.reduce(CGFloat(0)) { acc, item in
            acc + item.cachedHeight
        }
        XCTAssertGreaterThanOrEqual(accumulatedHeight, viewportH,
            "walk should only stop once viewport budget is met")
    }

    func testPrepareBoundedHandlesUnderflow() async {
        let entries = [
            makeLocalUserEntry(text: "short"),
            makeLocalUserEntry(text: "also short"),
        ]
        let result = await Task.detached { [theme = theme, width = width] in
            TranscriptRowBuilder.prepareBounded(
                entries: entries, theme: theme, width: width,
                stickyStates: [:],
                minAccumulatedHeight: .greatestFiniteMagnitude)
        }.value

        XCTAssertEqual(result.consumedEntryCount, entries.count)
    }

    func testPrepareBoundedWithZeroBudgetConsumesOneEntry() async {
        let entries = (0..<5).map { makeLocalUserEntry(text: "msg \($0)") }
        let result = await Task.detached { [theme = theme, width = width] in
            TranscriptRowBuilder.prepareBounded(
                entries: entries, theme: theme, width: width,
                stickyStates: [:],
                minAccumulatedHeight: 0)
        }.value
        XCTAssertEqual(result.consumedEntryCount, 1,
            "zero budget → consume exactly one entry")
    }

    func testPrepareAndLayoutRunFromDetachedTask() async {
        let theme = self.theme
        let width = self.width
        let source = "Paragraph.\n\n```swift\nlet x = 1\n```"
        let stableId = StableId(entryId: UUID(), locator: .whole)

        let layout = await Task.detached {
            let input = AssistantMarkdownComponent.Input(stableId: stableId, source: source)
            let content = AssistantMarkdownComponent.prepare(input, theme: theme)
            return AssistantMarkdownComponent.layout(
                content, theme: theme, width: width, state: .default)
        }.value

        XCTAssertGreaterThan(layout.cachedHeight, 0)
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
}
