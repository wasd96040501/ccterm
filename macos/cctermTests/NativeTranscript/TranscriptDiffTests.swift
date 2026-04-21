import XCTest
@testable import ccterm

/// 覆盖 `TranscriptDiff` 的 carry-over / update / insert / delete 不变式。
///
/// 增量 merge 的老 bug 是：stableId 不变 + contentHash 不变被错判成 update，
/// 丢掉 layout cache；或者反过来 contentHash 变了还 carry-over。这里把两个
/// 边界各扎一道桩。
@MainActor
final class TranscriptDiffTests: XCTestCase {

    private final class FakeRow: TranscriptRow {
        let stable: String
        let hash: Int
        init(stable: String, hash: Int) {
            self.stable = stable
            self.hash = hash
            super.init()
        }
        override var stableId: AnyHashable { stable }
        override var contentHash: Int { hash }
    }

    func testCarryOverWhenStableIdAndHashMatch() {
        let r1 = FakeRow(stable: "a", hash: 1)
        let r2 = FakeRow(stable: "a", hash: 1)  // new, same id, same hash
        let t = TranscriptDiff.compute(old: [r1], new: [r2], animated: false)

        XCTAssertTrue(t.inserted.isEmpty)
        XCTAssertTrue(t.updated.isEmpty)
        XCTAssertTrue(t.deleted.isEmpty)
        XCTAssertEqual(t.finalRows.count, 1)
        XCTAssertTrue(
            t.finalRows[0] === r1,
            "carry-over must reuse the OLD row object so cached layout persists")
    }

    func testUpdateWhenStableIdSameButHashDiffers() {
        let r1 = FakeRow(stable: "a", hash: 1)
        let r2 = FakeRow(stable: "a", hash: 2)
        let t = TranscriptDiff.compute(old: [r1], new: [r2], animated: false)

        XCTAssertEqual(t.updated.count, 1)
        XCTAssertEqual(t.updated[0].0, 0)
        XCTAssertTrue(t.updated[0].1 === r2)
        XCTAssertTrue(t.finalRows[0] === r2)
    }

    func testInsertAndDeleteByStableId() {
        let a = FakeRow(stable: "a", hash: 1)
        let b = FakeRow(stable: "b", hash: 1)
        let c = FakeRow(stable: "c", hash: 1)
        let t = TranscriptDiff.compute(old: [a, b], new: [b, c], animated: false)

        XCTAssertEqual(t.deleted, [0])  // a
        XCTAssertEqual(t.inserted.count, 1)
        XCTAssertEqual(t.inserted[0].0, 1)  // c at new index 1
        XCTAssertTrue(t.inserted[0].1 === c)
        // b 应 carry-over（same stable id + hash）
        XCTAssertTrue(t.finalRows[0] === b)
        XCTAssertTrue(t.finalRows[1] === c)
    }

    func testEmptyNewProducesAllDeleted() {
        let a = FakeRow(stable: "a", hash: 1)
        let b = FakeRow(stable: "b", hash: 1)
        let t = TranscriptDiff.compute(old: [a, b], new: [], animated: false)
        XCTAssertEqual(t.deleted.sorted(), [0, 1])
        XCTAssertTrue(t.inserted.isEmpty)
        XCTAssertTrue(t.updated.isEmpty)
        XCTAssertTrue(t.finalRows.isEmpty)
    }
}
