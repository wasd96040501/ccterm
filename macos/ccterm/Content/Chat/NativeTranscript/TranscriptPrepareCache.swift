import AppKit
import Foundation

/// Content-addressed LRU cache for `TranscriptPreparedItem`.
///
/// Purpose: on session switch / theme change / re-entry into the same view,
/// avoid re-parsing Markdown, re-typesetting CoreText, and re-highlighting
/// code blocks for content that was already processed in an earlier pass.
///
/// Design:
/// - **Key**: `(contentHash, widthBucket, variant)`. `contentHash` already
///   encodes source + theme fingerprint (via `AssistantPrepared.contentHash`
///   / `UserPrepared.contentHash` / `PlaceholderPrepared.contentHash`), so a
///   theme change yields different keys naturally.
/// - **Width bucketing**: `floor(width / 32)` — same bucket shares layout,
///   avoiding misses on sub-pixel resizes. A real window resize to a
///   different bucket misses and re-layouts.
/// - **Variant**: distinguishes assistant / user (+ expanded state) /
///   placeholder. Prevents hash collisions between unrelated content types.
///
/// Value storage: the cache keeps the entire `TranscriptPreparedItem`
/// including layout data. On hit, callers swap in the **current** stableId
/// via `withStableId(_:)` — stableId is external (per entry UUID), not part
/// of the cacheable content.
///
/// Thread safety: plain `NSLock` around all mutations. Reader locks are the
/// same; contention is negligible compared to the work being cached (tens of
/// milliseconds of Markdown parse + layout vs. microseconds of lock).
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
        let widthBucket: Int
        let variant: Variant
    }

    enum Variant: Hashable {
        case assistant
        case user(isExpanded: Bool)
        case placeholder
    }

    private let lock = NSLock()
    private var store: [Key: TranscriptPreparedItem] = [:]
    private var order: [Key] = []
    private let capacity: Int

    /// For tests/instrumentation.
    private(set) var hitCount: Int = 0
    private(set) var missCount: Int = 0

    /// Width most recently observed by a real `TranscriptController.setEntries`
    /// invocation. Hover-prewarm reads this to choose a bucket matching the
    /// user's actual window geometry instead of guessing a theme-defined max.
    /// `nil` until the first setEntries runs.
    private var _lastObservedWidth: CGFloat?
    var lastObservedWidth: CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return _lastObservedWidth
    }
    func recordObservedWidth(_ width: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        _lastObservedWidth = width
    }

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// 绕过 macOS 26 SDK 的 `swift_task_deinitOnExecutorImpl` libmalloc 崩溃 —
    /// 同 `TranscriptRow.deinit` 的处理。cache 存储的 value types 释放本身
    /// 线程安全，跳过 executor-hop 是安全的。
    nonisolated deinit { }

    /// Look up a prepared item. Returns the cached value with its original
    /// stableId — caller rewrites stableId via `TranscriptPreparedItem.withStableId(_:)`.
    func get(_ key: Key) -> TranscriptPreparedItem? {
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
    func put(_ key: Key, _ item: TranscriptPreparedItem) {
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

// MARK: - Key helpers

extension TranscriptPrepareCache {
    /// Bucket a width into a cache-friendly discrete value. 32-pt granularity
    /// means sub-pixel resizes stay in the same bucket; moving to a different
    /// window column (or split-view half) misses.
    static func widthBucket(_ width: CGFloat) -> Int {
        Int((width / 32).rounded(.down))
    }
}

// MARK: - stableId rewriting on cache hit

extension TranscriptPreparedItem {
    /// Returns a copy of this item with `stableId` swapped to `newId`.
    /// Cached items lose their original session-bound stableId on retrieval;
    /// the caller must attach the current entry's stableId so downstream
    /// `TranscriptDiff.compute` can match / carry-over correctly.
    func withStableId(_ newId: AnyHashable) -> TranscriptPreparedItem {
        switch self {
        case .assistant(let p, let l):
            let newP = AssistantPrepared(
                source: p.source,
                parsedDocument: p.parsedDocument,
                prebuilt: p.prebuilt,
                stable: newId,
                contentHash: p.contentHash,
                hasHighlight: p.hasHighlight)
            return .assistant(newP, l)
        case .user(let p, let l, let isExp):
            let newP = UserPrepared(
                text: p.text,
                stable: newId,
                contentHash: p.contentHash)
            return .user(newP, l, isExpanded: isExp)
        case .placeholder(let p, let l):
            let newP = PlaceholderPrepared(
                label: p.label,
                stable: newId,
                contentHash: p.contentHash)
            return .placeholder(newP, l)
        }
    }

    /// Extract the cache key components for a fully-prepared item. The
    /// `widthBucket` is implicit — caller supplies it (from the current
    /// `width` used to produce the layout).
    func cacheKey(width: CGFloat) -> TranscriptPrepareCache.Key {
        switch self {
        case .assistant(let p, _):
            return TranscriptPrepareCache.Key(
                contentHash: p.contentHash,
                widthBucket: TranscriptPrepareCache.widthBucket(width),
                variant: .assistant)
        case .user(let p, _, let isExp):
            return TranscriptPrepareCache.Key(
                contentHash: p.contentHash,
                widthBucket: TranscriptPrepareCache.widthBucket(width),
                variant: .user(isExpanded: isExp))
        case .placeholder(let p, _):
            return TranscriptPrepareCache.Key(
                contentHash: p.contentHash,
                widthBucket: TranscriptPrepareCache.widthBucket(width),
                variant: .placeholder)
        }
    }
}
