import AppKit
import XCTest
@testable import ccterm

/// 覆盖 `TranscriptDiff` 的 carry-over / update / insert / delete 不变式。
///
/// 用 `PlaceholderComponent` 的真实 callbacks 构造 `ComponentRow` 做 fake —
/// stableId / contentHash 是协议层属性,不依赖 component 内部细节。
@MainActor
final class TranscriptDiffTests: XCTestCase {

    /// 构造一个稳定可比较的 ComponentRow:用 PlaceholderComponent + 命名 stableId。
    private func makeRow(stable: String, hash: Int) -> ComponentRow {
        let stableId = StableId(
            entryId: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
            locator: .custom(stable))
        let theme = TranscriptTheme.default
        let input = PlaceholderComponent.Input(stableId: stableId, label: stable)
        let content = PlaceholderComponent.prepare(input, theme: theme)
        let layout = PlaceholderComponent.layout(content, theme: theme, width: 100, state: ())
        let item = PreparedItem<PlaceholderComponent>(
            stableId: stableId,
            input: input,
            content: content,
            contentHash: hash,
            state: (),
            layout: layout)
        return item.makeRow(theme: theme, layoutWidth: 100)
    }

    func testCarryOverWhenStableIdAndHashMatch() {
        let r1 = makeRow(stable: "a", hash: 1)
        let r2 = makeRow(stable: "a", hash: 1)
        let t = TranscriptDiff.compute(old: [r1], new: [r2], animated: false)

        XCTAssertTrue(t.inserted.isEmpty)
        XCTAssertTrue(t.updated.isEmpty)
        XCTAssertTrue(t.deleted.isEmpty)
        XCTAssertEqual(t.finalRows.count, 1)
        XCTAssertEqual(t.finalRows[0].stableId, r1.stableId)
        XCTAssertEqual(t.finalRows[0].contentHash, 1)
    }

    func testUpdateWhenStableIdSameButHashDiffers() {
        let r1 = makeRow(stable: "a", hash: 1)
        let r2 = makeRow(stable: "a", hash: 2)
        let t = TranscriptDiff.compute(old: [r1], new: [r2], animated: false)

        XCTAssertEqual(t.updated.count, 1)
        XCTAssertEqual(t.updated[0].0, 0)
        XCTAssertEqual(t.updated[0].1.contentHash, 2)
        XCTAssertEqual(t.finalRows[0].contentHash, 2)
    }

    func testInsertAndDeleteByStableId() {
        let a = makeRow(stable: "a", hash: 1)
        let b = makeRow(stable: "b", hash: 1)
        let c = makeRow(stable: "c", hash: 1)
        let t = TranscriptDiff.compute(old: [a, b], new: [b, c], animated: false)

        XCTAssertEqual(t.deleted, [0])  // a
        XCTAssertEqual(t.inserted.count, 1)
        XCTAssertEqual(t.inserted[0].0, 1)  // c at new index 1
        XCTAssertEqual(t.inserted[0].1.stableId, c.stableId)
        // b 应 carry-over
        XCTAssertEqual(t.finalRows[0].stableId, b.stableId)
        XCTAssertEqual(t.finalRows[1].stableId, c.stableId)
    }

    func testEmptyNewProducesAllDeleted() {
        let a = makeRow(stable: "a", hash: 1)
        let b = makeRow(stable: "b", hash: 1)
        let t = TranscriptDiff.compute(old: [a, b], new: [], animated: false)
        XCTAssertEqual(t.deleted.sorted(), [0, 1])
        XCTAssertTrue(t.inserted.isEmpty)
        XCTAssertTrue(t.updated.isEmpty)
        XCTAssertTrue(t.finalRows.isEmpty)
    }
}
