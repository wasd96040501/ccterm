import AgentSDK
import AppKit
import XCTest
@testable import ccterm

/// 验证内容寻址缓存的 get/put/LRU/invalidate 行为，以及 `withStableId`
/// 在 cache hit 时正确替换 stableId。
///
/// Cache 现在只存 Prepared（width 无关），Layout 每次按当前 width 重算——
/// 相关的 drift 回归测试见 `testNoDriftAcrossWidths`。
@MainActor
final class TranscriptPrepareCacheTests: XCTestCase {

    private let theme = TranscriptTheme.default
    private let width: CGFloat = 720

    // MARK: - Basic get / put / miss

    func testMissThenPutThenHit() {
        let cache = TranscriptPrepareCache(capacity: 10)
        let item = makeUserItem(text: "hello", stable: "id-1")
        let key = item.cacheKey

        XCTAssertNil(cache.get(key))
        cache.put(key, item)

        let got = cache.get(key)
        XCTAssertNotNil(got)
        guard let userItem = got as? UserPreparedItem else {
            return XCTFail("expected UserPreparedItem")
        }
        XCTAssertEqual(userItem.prepared.text, "hello")
    }

    // MARK: - LRU eviction

    func testLRUEvictsOldestWhenCapacityExceeded() {
        let cache = TranscriptPrepareCache(capacity: 3)
        let k1 = putUser(cache, text: "1", stable: "s1")
        let k2 = putUser(cache, text: "2", stable: "s2")
        let k3 = putUser(cache, text: "3", stable: "s3")
        XCTAssertEqual(cache.count, 3)

        // Touch k1 → becomes most-recently-used.
        _ = cache.get(k1)

        // Add a 4th → evicts LRU (k2).
        _ = putUser(cache, text: "4", stable: "s4")

        XCTAssertNotNil(cache.get(k1), "k1 recently touched → still present")
        XCTAssertNil(cache.get(k2), "k2 LRU → evicted")
        XCTAssertNotNil(cache.get(k3))
    }

    // MARK: - withStableId semantics

    /// Cache hits return Prepared with the cached-era stableId; `withStableId`
    /// rewrites it so TranscriptDiff can match the current entry. contentHash
    /// must be preserved (stable-id-independent).
    func testWithStableIdPreservesContentHash() {
        let item = makeUserItem(text: "shared text", stable: "original-id")
        let rewritten = item.withStableId("new-id" as AnyHashable)

        guard let rewrittenUser = rewritten as? UserPreparedItem else {
            return XCTFail("expected UserPreparedItem")
        }
        XCTAssertEqual(rewrittenUser.prepared.text, "shared text")
        XCTAssertEqual(rewrittenUser.prepared.stable, AnyHashable("new-id"))
        XCTAssertEqual(rewrittenUser.prepared.contentHash, item.prepared.contentHash)
    }

    // MARK: - No drift across widths

    /// 回归测试：同 contentHash 在两个不同 width 下跑 prepareAll，cache 命中
    /// Prepared 但 **Layout 必按新 width 算**——每个 item 的 `layout.cachedHeight`
    /// 必须等于同 width 下独立跑 `layoutX` 的结果，且 **两个 width 下高度不相等**
    /// （证明 layout 没有复用旧值）。
    ///
    /// 这是 501976c 之后 sidebar 切换 "第一帧错位" 的根因：bucket-cached layout
    /// 让 `heightOf(item)` 和 `row.cachedHeight` 跨 width 产生 drift。现在 layout
    /// 不缓存，drift 构造上不可能。
    func testNoDriftAcrossWidths() async {
        TranscriptPrepareCache.shared.invalidateAll()

        // 一条会 wrap 的长文本 user bubble。两个 width 落差大到 wrap 行数不同。
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

        guard let userA = itemsA.first as? UserPreparedItem,
              let userB = itemsB.first as? UserPreparedItem,
              let layoutA = userA.layout,
              let layoutB = userB.layout else {
            return XCTFail("expected user items with layout")
        }

        // Layout 必须按 caller 传入的 width 算出来。
        XCTAssertEqual(layoutA.cachedWidth, widthA, accuracy: 0.01)
        XCTAssertEqual(layoutB.cachedWidth, widthB, accuracy: 0.01)

        // 两个 width 下高度应该不同（证明 B 没复用 A 的 cached layout）。
        XCTAssertNotEqual(
            layoutA.cachedHeight, layoutB.cachedHeight,
            "layout must be recomputed per width; got identical heights \(layoutA.cachedHeight)")

        // 独立跑 `layoutUser(width: widthA)` 应该和 itemsA 的 layout 一致——
        // 这是 "heightOf(item) == row.cachedHeight" 等式的双端。
        let refA = TranscriptPrepare.layoutUser(
            text: longText, theme: theme, width: widthA, isExpanded: false)
        XCTAssertEqual(layoutA.cachedHeight, refA.cachedHeight, accuracy: 0.01)

        let refB = TranscriptPrepare.layoutUser(
            text: longText, theme: theme, width: widthB, isExpanded: false)
        XCTAssertEqual(layoutB.cachedHeight, refB.cachedHeight, accuracy: 0.01)

        // Cache 只存 Prepared（size == 1），不会因为两个 width 而膨胀。
        XCTAssertEqual(TranscriptPrepareCache.shared.count, 1,
            "cache stores Prepared only; two widths must share one slot")
    }

    // MARK: - Invalidate

    func testInvalidateAllClearsEverything() {
        let cache = TranscriptPrepareCache(capacity: 10)
        _ = putUser(cache, text: "a", stable: "1")
        _ = putUser(cache, text: "b", stable: "2")
        XCTAssertEqual(cache.count, 2)

        cache.invalidateAll()
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: - End-to-end: shared cache speeds up second prepareAll

    /// 第一次 prepareAll 全 miss,put 到 shared cache;第二次 prepareAll
    /// 同内容应该全 hit(Prepared 命中)。Layout 每次都重算,但 Prepared 复用。
    func testSharedCacheServesSecondPrepareAll() async {
        TranscriptPrepareCache.shared.invalidateAll()

        let entries: [MessageEntry] = [
            makeLocalUserEntry(text: "hello"),
            makeLocalUserEntry(text: "world"),
        ]

        let first = await Task.detached { [theme = theme, width = width] in
            TranscriptRowBuilder.prepareAll(
                entries: entries, theme: theme, width: width)
        }.value

        let firstHits = TranscriptPrepareCache.shared.hitCount
        let firstMisses = TranscriptPrepareCache.shared.missCount

        let second = await Task.detached { [theme = theme, width = width] in
            TranscriptRowBuilder.prepareAll(
                entries: entries, theme: theme, width: width)
        }.value

        let totalHits = TranscriptPrepareCache.shared.hitCount
        let totalMisses = TranscriptPrepareCache.shared.missCount

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(totalHits - firstHits, 2,
            "second prepareAll should hit cache for both entries")
        XCTAssertEqual(totalMisses, firstMisses,
            "no new misses on second prepareAll")

        // Identity: layout heights match (same width, same text → same layout).
        for (f, s) in zip(first, second) {
            if let fu = f as? UserPreparedItem, let su = s as? UserPreparedItem {
                XCTAssertEqual(fu.cachedHeight, su.cachedHeight, accuracy: 0.01)
            }
        }
    }

    // MARK: - Helpers

    private func makeUserItem(text: String, stable: AnyHashable) -> UserPreparedItem {
        UserPreparedItem(
            prepared: TranscriptPrepare.user(text: text, theme: theme, stable: stable),
            layout: nil)
    }

    @discardableResult
    private func putUser(
        _ cache: TranscriptPrepareCache,
        text: String,
        stable: AnyHashable
    ) -> TranscriptPrepareCache.Key {
        let item = makeUserItem(text: text, stable: stable)
        let key = item.cacheKey
        cache.put(key, item)
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
