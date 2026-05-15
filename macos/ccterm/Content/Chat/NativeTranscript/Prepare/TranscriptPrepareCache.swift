import AppKit
import Foundation

/// Content-addressed LRU cache for **width-independent** parsed Content only.
///
/// Stores the output of `C.prepare(input, theme:)`(parse + prebuild)keyed by
/// `(contentHash, tag)`. Width-dependent layout is **not** cached — always
/// recomputed at the exact current width to avoid the "切 sidebar 第一帧不对"
/// drift bug rooted in bucketed layout caching.
///
/// ## Key
///
/// `(contentHash, tag)`. `contentHash` encodes source + theme fingerprint
/// per-component; `tag = C.tag` separates content types so unrelated
/// components don't hash-collide.
///
/// ## Value
///
/// `CachedContent { tag, content: any Sendable }` — `content` is the typed
/// `C.Content` boxed as `any Sendable`. Consumers typecheck via
/// `contentAs(_:)` before unwrapping.
///
/// ## Thread safety
///
/// Plain `NSLock`. Contention negligible vs. parse cost(tens of ms vs. μs).
///
/// ## Scope
///
/// Singleton (`shared`) across all `TranscriptController` instances. Multiple
/// chat windows share cross-controller hits.
final class TranscriptPrepareCache: @unchecked Sendable {

    static let shared = TranscriptPrepareCache(capacity: 1500)

    struct Key: Hashable, Sendable {
        let contentHash: Int
        let tag: String
    }

    /// Cache 存储的值 —— 一段 component 的 Content,boxed 后跨 actor 边界。
    struct CachedContent: @unchecked Sendable {
        let tag: String
        let content: any Sendable

        /// 类型安全 unwrap。`tag` 不匹配 → nil。
        func contentAs<C: TranscriptComponent>(_ type: C.Type) -> C.Content? {
            guard tag == C.tag else { return nil }
            return content as? C.Content
        }
    }

    private let lock = NSLock()
    private var store: [Key: CachedContent] = [:]
    private var order: [Key] = []
    private let capacity: Int

    private(set) var hitCount: Int = 0
    private(set) var missCount: Int = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    nonisolated deinit { }

    func get(_ key: Key) -> CachedContent? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = store[key] else {
            missCount += 1
            return nil
        }
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        order.append(key)
        hitCount += 1
        return item
    }

    func put(_ key: Key, _ item: CachedContent) {
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

    func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
        order.removeAll()
        hitCount = 0
        missCount = 0
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return store.count
    }
}
