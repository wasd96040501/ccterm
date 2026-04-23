import AgentSDK
import AppKit
import XCTest
@testable import ccterm

/// 验证 `TranscriptRowBuilder.prepareBoundedTail` 的 viewport-first 尾部走法。
///
/// 覆盖：
/// - 空 entries → 空 result, phase1StartIndex = 0
/// - budget = 0 → 只挂末尾 1 条, phase1StartIndex = N-1
/// - 单行高度已经 > budget → 仍只挂这 1 条（不能返回空）
/// - 所有行累计 < budget → 全部挂上, phase1StartIndex = 0
/// - 正常路径 → 从尾向前累积直到 >= budget
/// - items 是 forward order（oldest→newest 保序）
final class TranscriptPrepareTailTests: XCTestCase {

    private let theme = TranscriptTheme(markdown: .default)
    private let width: CGFloat = 720

    private func assistantEntry(_ text: String) -> MessageEntry {
        let json: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ]
        let msg = (try? Message2(json: json)) ?? Message2.unknown(name: "assistant", raw: json)
        return .single(SingleEntry(id: UUID(), payload: .remote(msg), delivery: nil, toolResults: [:]))
    }

    private func userEntry(_ text: String) -> MessageEntry {
        let json: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
        ]
        let msg = (try? Message2(json: json)) ?? Message2.unknown(name: "user", raw: json)
        return .single(SingleEntry(id: UUID(), payload: .remote(msg), delivery: nil, toolResults: [:]))
    }

    // MARK: - Empty

    func testEmptyEntriesReturnsEmpty() {
        let r = TranscriptRowBuilder.prepareBoundedTail(
            entries: [],
            theme: theme, width: width,
            expandedUserBubbles: [],
            minAccumulatedHeight: 600)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertEqual(r.phase1StartIndex, 0)
    }

    // MARK: - Budget boundaries

    /// budget = 0 时，第一条 entry 挂上后 accumulated 就 >= 0，立刻停 → 只末尾 1 条。
    func testZeroBudgetProducesTailOnly() {
        let entries: [MessageEntry] = (0..<10).map { userEntry("msg \($0)") }
        let r = TranscriptRowBuilder.prepareBoundedTail(
            entries: entries,
            theme: theme, width: width,
            expandedUserBubbles: [],
            minAccumulatedHeight: 0)
        XCTAssertEqual(r.phase1StartIndex, entries.count - 1)
        XCTAssertEqual(r.items.count, 1)
    }

    /// 单行高度本身就 > budget：walk 完成一个 entry 后 accumulated > budget → 停。
    /// 绝不能返回空 result —— 否则 setEntries 第一次挂 0 行。
    func testSingleRowTallerThanBudgetStillProducesOneEntry() {
        // 一条很高的 assistant（几十行代码）
        let bigCode = """
        ```swift
        \(String(repeating: "let x = 42\n", count: 60))
        ```
        """
        let entries: [MessageEntry] = [
            userEntry("short"),
            assistantEntry(bigCode),
        ]
        let r = TranscriptRowBuilder.prepareBoundedTail(
            entries: entries,
            theme: theme, width: width,
            expandedUserBubbles: [],
            minAccumulatedHeight: 10)
        XCTAssertEqual(r.phase1StartIndex, 1, "应停在最后一条（index=1）")
        XCTAssertGreaterThanOrEqual(r.items.count, 1)
    }

    /// 所有行累加仍 < budget → 全部 entries 进入 Phase 1，phase1StartIndex = 0。
    func testAllEntriesFitUnderBudget() {
        let entries: [MessageEntry] = (0..<3).map { userEntry("m\($0)") }
        let r = TranscriptRowBuilder.prepareBoundedTail(
            entries: entries,
            theme: theme, width: width,
            expandedUserBubbles: [],
            minAccumulatedHeight: 100_000)  // 10 万 pt，永远填不满
        XCTAssertEqual(r.phase1StartIndex, 0)
        XCTAssertGreaterThanOrEqual(r.items.count, entries.count)
    }

    // MARK: - Normal path

    /// 正常 viewport budget：从尾向前累积到越过阈值。
    func testNormalBudgetPicksTailSlice() {
        let entries: [MessageEntry] = (0..<30).map { userEntry("message number \($0) here") }
        let r = TranscriptRowBuilder.prepareBoundedTail(
            entries: entries,
            theme: theme, width: width,
            expandedUserBubbles: [],
            minAccumulatedHeight: 300)
        // 挂载的应当是末尾一段，非全量、非单条。
        XCTAssertGreaterThan(r.phase1StartIndex, 0)
        XCTAssertLessThan(r.phase1StartIndex, entries.count - 1)
        XCTAssertEqual(r.items.count, entries.count - r.phase1StartIndex)
    }

    // MARK: - Order preservation

    /// items 必须是 forward order（oldest→newest 保持 entries 原顺序）。
    /// 内部虽然是 reverse walk，输出要翻回来——否则 diff / row factory 对不上。
    func testItemsAreInForwardOrder() {
        // 构造可区分 text 的 entries，从 prepared items 中提取 stable id
        // 与 entries 的 id 做顺序一致性验证。
        let entries: [MessageEntry] = (0..<10).map { userEntry("m\($0)") }
        let r = TranscriptRowBuilder.prepareBoundedTail(
            entries: entries,
            theme: theme, width: width,
            expandedUserBubbles: [],
            minAccumulatedHeight: 100_000)  // 全量
        XCTAssertEqual(r.items.count, entries.count)

        let entryIds = entries.map { $0.id }
        var itemStables: [AnyHashable] = []
        for item in r.items {
            guard item is UserPreparedItem else {
                XCTFail("expected UserPreparedItem"); continue
            }
            itemStables.append(item.stableId)
        }
        let expectedStables = entryIds.map { AnyHashable($0) }
        XCTAssertEqual(itemStables, expectedStables, "items 顺序必须等于 entries 的顺序")
    }
}
