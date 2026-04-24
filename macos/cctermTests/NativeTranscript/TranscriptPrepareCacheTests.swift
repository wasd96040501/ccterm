import AgentSDK
import AppKit
import XCTest
@testable import ccterm

/// 验证内容寻址缓存的 get/put/LRU/invalidate 行为,以及 cache 跨 width 不
/// 漂移(layout 永远按当前 width 重算)。
@MainActor
final class TranscriptPrepareCacheTests: XCTestCase {

    private let theme = TranscriptTheme.default
    private let width: CGFloat = 720

    // MARK: - Basic get / put / miss

    func testMissThenPutThenHit() {
        let cache = TranscriptPrepareCache(capacity: 10)
        let key = TranscriptPrepareCache.Key(contentHash: 42, tag: UserBubbleComponent.tag)
        let content = UserBubbleComponent.Content(text: "hello")

        XCTAssertNil(cache.get(key))
        cache.put(key, .init(tag: UserBubbleComponent.tag, content: content))

        let got = cache.get(key)
        XCTAssertNotNil(got)
        let typed = got?.contentAs(UserBubbleComponent.self)
        XCTAssertEqual(typed?.text, "hello")
    }

    // MARK: - LRU eviction

    func testLRUEvictsOldestWhenCapacityExceeded() {
        let cache = TranscriptPrepareCache(capacity: 3)
        let k1 = put(cache, hash: 1, text: "1")
        let k2 = put(cache, hash: 2, text: "2")
        let k3 = put(cache, hash: 3, text: "3")
        XCTAssertEqual(cache.count, 3)

        _ = cache.get(k1)  // touch k1 → most-recently-used

        _ = put(cache, hash: 4, text: "4")  // evicts LRU (k2)

        XCTAssertNotNil(cache.get(k1))
        XCTAssertNil(cache.get(k2), "k2 LRU → evicted")
        XCTAssertNotNil(cache.get(k3))
    }

    // MARK: - No drift across widths

    /// 同 contentHash 在两 width 下跑 prepareAll —— Prepared 命中 cache,
    /// 但 Layout 永远按当前 width 算。两个 width 下 cachedHeight 必须不同(
    /// 长 wrap 的不同行数),且各自等于独立 layout 调用的结果。
    func testNoDriftAcrossWidths() async {
        TranscriptPrepareCache.shared.invalidateAll()

        let longText = String(
            repeating: "The quick brown fox jumps over the lazy dog. ",
            count: 8)
        let entries = [makeLocalUserEntry(text: longText)]

        let widthA: CGFloat = 400
        let widthB: CGFloat = 780

        let itemsA = await Task.detached { [theme = theme] in
            TranscriptRowBuilder.prepareAll(
                entries: entries, theme: theme, width: widthA)
        }.value

        let itemsB = await Task.detached { [theme = theme] in
            TranscriptRowBuilder.prepareAll(
                entries: entries, theme: theme, width: widthB)
        }.value

        XCTAssertEqual(itemsA.count, 1)
        XCTAssertEqual(itemsB.count, 1)
        XCTAssertEqual(itemsA[0].tag, UserBubbleComponent.tag)
        XCTAssertEqual(itemsB[0].tag, UserBubbleComponent.tag)
        XCTAssertEqual(itemsA[0].layoutWidth, widthA, accuracy: 0.01)
        XCTAssertEqual(itemsB[0].layoutWidth, widthB, accuracy: 0.01)

        // 两个 width 下高度不等 → 证明 B 没复用 A 的 cached layout。
        XCTAssertNotEqual(
            itemsA[0].cachedHeight, itemsB[0].cachedHeight,
            "layout must be recomputed per width")

        // Cache 只存 Content(单个 slot),不会因为两个 width 而膨胀。
        XCTAssertEqual(TranscriptPrepareCache.shared.count, 1)
    }

    // MARK: - Invalidate

    func testInvalidateAllClearsEverything() {
        let cache = TranscriptPrepareCache(capacity: 10)
        _ = put(cache, hash: 1, text: "a")
        _ = put(cache, hash: 2, text: "b")
        XCTAssertEqual(cache.count, 2)

        cache.invalidateAll()
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: - End-to-end: shared cache speeds up second prepareAll

    func testSharedCacheServesSecondPrepareAll() async {
        TranscriptPrepareCache.shared.invalidateAll()

        let entries: [MessageEntry] = [
            makeLocalUserEntry(text: "hello"),
            makeLocalUserEntry(text: "world"),
        ]

        _ = await Task.detached { [theme = theme, width = width] in
            TranscriptRowBuilder.prepareAll(
                entries: entries, theme: theme, width: width)
        }.value

        let firstHits = TranscriptPrepareCache.shared.hitCount
        let firstMisses = TranscriptPrepareCache.shared.missCount

        _ = await Task.detached { [theme = theme, width = width] in
            TranscriptRowBuilder.prepareAll(
                entries: entries, theme: theme, width: width)
        }.value

        let totalHits = TranscriptPrepareCache.shared.hitCount
        let totalMisses = TranscriptPrepareCache.shared.missCount

        XCTAssertEqual(totalHits - firstHits, 2,
            "second prepareAll should hit cache for both entries")
        XCTAssertEqual(totalMisses, firstMisses,
            "no new misses on second prepareAll")
    }

    // MARK: - Helpers

    @discardableResult
    private func put(
        _ cache: TranscriptPrepareCache, hash: Int, text: String
    ) -> TranscriptPrepareCache.Key {
        let key = TranscriptPrepareCache.Key(contentHash: hash, tag: UserBubbleComponent.tag)
        cache.put(key, .init(tag: UserBubbleComponent.tag,
                             content: UserBubbleComponent.Content(text: text)))
        return key
    }

    private func makeLocalUserEntry(text: String) -> MessageEntry {
        let input = LocalUserInput(text: text, image: nil, planContent: nil)
        return .single(SingleEntry(
            id: UUID(),
            payload: .localUser(input),
            delivery: nil,
            toolResults: [:]))
    }
}
