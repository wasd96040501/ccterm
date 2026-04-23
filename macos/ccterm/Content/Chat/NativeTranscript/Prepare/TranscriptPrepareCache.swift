import AppKit
import Foundation

/// Content-addressed LRU cache for **width-independent** prepared data only.
///
/// Scope deliberately narrow: the cache stores the output of Markdown parse /
/// prebuild / syntax highlight enrichment — i.e. the
/// `Prepared` half of `TranscriptPreparedItem`. `Layout` (CoreText typesetting,
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
///   collisions between unrelated content types. User's `isExpanded` does not
///   participate — `UserPrepared` is expand-independent (it carries only text
///   + hash); expand state is applied at layout time.
/// - **Value**: `CachedPrepared` — the Prepared half only. Layout is produced
///   on-demand by callers via `TranscriptPrepare.layoutX(..., width: width)`.
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
        let variant: Variant
    }

    enum Variant: Hashable {
        case assistant
        case user
        case placeholder
    }

    private let lock = NSLock()
    private var store: [Key: CachedPrepared] = [:]
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

    /// Look up a cached Prepared. Returns the value with its original
    /// stableId — caller rewrites stableId via `CachedPrepared.withStableId(_:)`.
    func get(_ key: Key) -> CachedPrepared? {
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
    func put(_ key: Key, _ prepared: CachedPrepared) {
        lock.lock()
        defer { lock.unlock() }
        if store[key] != nil {
            store[key] = prepared
            if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
            order.append(key)
            return
        }
        store[key] = prepared
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

// MARK: - Cached value type

/// What the cache actually stores: the `Prepared` half of a prepared item.
/// `Layout` is intentionally absent — width-dependent work is recomputed every
/// time by `TranscriptRowBuilder.cachedOrBuildX` / `applyHighlightTokens`.
enum CachedPrepared: @unchecked Sendable {
    case assistant(AssistantPrepared)
    case user(UserPrepared)
    case placeholder(PlaceholderPrepared)
}

extension CachedPrepared {
    /// Returns a copy with the embedded prepared's `stable` replaced by `newId`.
    /// Cache hits carry the original session's stableId; the caller must swap
    /// to the current entry's stableId so downstream `TranscriptDiff.compute`
    /// can match / carry-over correctly.
    func withStableId(_ newId: AnyHashable) -> CachedPrepared {
        switch self {
        case .assistant(let p):
            return .assistant(AssistantPrepared(
                source: p.source,
                parsedDocument: p.parsedDocument,
                prebuilt: p.prebuilt,
                stable: newId,
                contentHash: p.contentHash,
                hasHighlight: p.hasHighlight))
        case .user(let p):
            return .user(UserPrepared(
                text: p.text,
                stable: newId,
                contentHash: p.contentHash))
        case .placeholder(let p):
            return .placeholder(PlaceholderPrepared(
                label: p.label,
                stable: newId,
                contentHash: p.contentHash))
        }
    }

    /// Content-only cache key. No width component — Layout is never cached.
    var cacheKey: TranscriptPrepareCache.Key {
        switch self {
        case .assistant(let p):
            return TranscriptPrepareCache.Key(
                contentHash: p.contentHash, variant: .assistant)
        case .user(let p):
            return TranscriptPrepareCache.Key(
                contentHash: p.contentHash, variant: .user)
        case .placeholder(let p):
            return TranscriptPrepareCache.Key(
                contentHash: p.contentHash, variant: .placeholder)
        }
    }
}

// MARK: - TranscriptPreparedItem helpers

extension TranscriptPreparedItem {
    /// Strip the Layout half and return the Prepared half — what the cache
    /// stores. Paired with `cacheKey` at the call site.
    var preparedOnly: CachedPrepared {
        switch self {
        case .assistant(let p, _): return .assistant(p)
        case .user(let p, _, _): return .user(p)
        case .placeholder(let p, _): return .placeholder(p)
        }
    }

    /// Content-only cache key derived from the embedded prepared — mirrors
    /// `CachedPrepared.cacheKey` so callers can go straight from item to key.
    var cacheKey: TranscriptPrepareCache.Key {
        preparedOnly.cacheKey
    }
}
