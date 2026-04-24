import AppKit
import Foundation

/// Content-addressed LRU cache for **width-independent** prepared data only.
///
/// Scope deliberately narrow: the cache stores the output of Markdown parse /
/// prebuild / syntax highlight enrichment — i.e. a `TranscriptPreparedItem`
/// with `layout` stripped (nil). `Layout` (CoreText typesetting,
/// `cachedHeight`) is **not** cached — it is always recomputed at the exact
/// current width.
///
/// Why: a previous design cached layouts bucketed by `floor(width / 32)`. That
/// made heights drift between same-bucket widths, causing Phase 1's budget math
/// (which accumulated cached heights) to disagree with the row's actual
/// `cachedHeight` after `makeSize(width:)`. On wrap-heavy content the
/// drift accumulates to visible scroll-anchor misalignment ("切 sidebar 第一帧
/// 不对"). Stripping layout from the cache makes `heightOf(item)` exactly equal
/// to `row.cachedHeight` by construction.
///
/// Design:
/// - **Key**: `(contentHash, variant)`. `contentHash` encodes source + theme
///   fingerprint on the prepared side — a theme change naturally yields
///   different keys. No width component.
/// - **Variant**: assistant / user / placeholder. Prevents hash
///   collisions between unrelated content types.
/// - **Value**: `any TranscriptPreparedItem` with `layout == nil`
///   (produced by `strippingLayout()`). Layout is produced on-demand by
///   callers via `TranscriptPrepare.layoutX(..., width: width)`.
///
/// Thread safety: plain `NSLock` around all mutations. Reader locks are the
/// same; contention is negligible compared to the work being cached (tens of
/// milliseconds of Markdown parse + prebuild vs. microseconds of lock).
///
/// Scope: shared singleton (`TranscriptPrepareCache.shared`). Multiple
/// `TranscriptController` instances (e.g., multiple chat windows) share the
/// same cache and benefit from cross-controller hits.
final class TranscriptPrepareCache: @unchecked Sendable {

    /// Shared instance — singleton across all `TranscriptController` instances.
    /// Capacity sized to cover 3-5 medium sessions' worth of rows.
    static let shared = TranscriptPrepareCache(capacity: 1500)

    struct Key: Hashable {
        let contentHash: Int
        /// Component 唯一标签(= `TranscriptComponent.tag`)。约定:类型名。
        /// 同 process 内保证独一无二;框架只按 String 比较,零语义。
        let tag: String
    }

    private let lock = NSLock()
    private var store: [Key: any TranscriptPreparedItem] = [:]
    private var order: [Key] = []
    private let capacity: Int

    /// For tests/instrumentation.
    private(set) var hitCount: Int = 0
    private(set) var missCount: Int = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// 绕过 macOS 26 SDK 的 `swift_task_deinitOnExecutorImpl` libmalloc 崩溃 —
    /// 同 `TranscriptRow.deinit` 的处理。cache 存储的 value types 释放本身
    /// 线程安全，跳过 executor-hop 是安全的。
    nonisolated deinit { }

    /// Look up a cached prepared item. Returns the stored value with its
    /// **original** stableId — caller must `.withStableId(_:)` to rewrite.
    func get(_ key: Key) -> (any TranscriptPreparedItem)? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = store[key] else {
            missCount += 1
            return nil
        }
        // LRU bump
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        order.append(key)
        hitCount += 1
        return item
    }

    /// Insert or update. Evicts oldest entries when `capacity` is exceeded.
    /// Callers are expected to pass `item.strippingLayout()`; this isn't
    /// enforced structurally—storing an item with a layout wastes memory but
    /// is otherwise harmless.
    func put(_ key: Key, _ item: any TranscriptPreparedItem) {
        lock.lock()
        defer { lock.unlock() }
        if store[key] != nil {
            store[key] = item
            if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
            order.append(key)
            return
        }
        store[key] = item
        order.append(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            store.removeValue(forKey: oldest)
        }
    }

    /// Drop everything — used by unit tests and manual invalidation.
    func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
        order.removeAll()
        hitCount = 0
        missCount = 0
    }

    /// Non-destructive count — for tests.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return store.count
    }
}
