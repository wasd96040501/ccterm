import JavaScriptCore
import SwiftUI

actor SyntaxHighlightEngine {
    private var context: JSContext?
    private var tokenizeFn: JSValue?
    private var tokenizeBatchFn: JSValue?

    // LRU cache keyed by (code, language). JSCore tokenisation is pure — same
    // inputs always produce the same tokens — so memoising is safe. Keeps
    // chat scrolling snappy when the same command / file diff appears many
    // times, and means a collapsed → expanded ToolBlock hits the cache on
    // re-mount instead of re-invoking the JS engine.
    private struct CacheKey: Hashable {
        let code: String
        let language: String?
    }
    private var cache: [CacheKey: [SyntaxToken]] = [:]
    private var lruOrder: [CacheKey] = []
    private let maxCacheEntries = 256

    func load() {
        // Idempotent — callers (AppState eager preload + MarkdownView lazy)
        // both invoke this; only the first call does real work.
        guard tokenizeFn == nil else { return }
        guard let url = Bundle.main.url(forResource: "hljs-jscore", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            NSLog("[SyntaxHighlightEngine] Failed to load hljs-jscore.js from bundle")
            return
        }

        let ctx = JSContext()!
        ctx.exceptionHandler = { _, value in
            NSLog("[SyntaxHighlightEngine] JS exception: \(value?.toString() ?? "unknown")")
        }
        ctx.evaluateScript(source)

        guard let fn = ctx.objectForKeyedSubscript("tokenize"), !fn.isUndefined else {
            NSLog("[SyntaxHighlightEngine] tokenize function not found")
            return
        }

        self.context = ctx
        self.tokenizeFn = fn
        // Optional batch entry point. Older bundles may not have it; fall
        // back to per-call when missing.
        if let batch = ctx.objectForKeyedSubscript("tokenizeBatch"), !batch.isUndefined {
            self.tokenizeBatchFn = batch
        }
    }

    /// External single-request API. **Auto-coalesces**: multiple
    /// `highlight(...)` calls arriving in the same event-loop tick merge
    /// into one internal `highlightBatch` call, crossing the JSCore
    /// boundary only once. Callers don't notice — each gets its own tokens.
    ///
    /// Implementation: cache miss → enqueue into `pendingCoalesce`; the
    /// first miss schedules the flush task; the flush task does one
    /// `Task.yield()` so other callers queued in the same tick can enter
    /// the actor and append, then takes the whole batch to JSCore.
    func highlight(code: String, language: String?) async -> [SyntaxToken] {
        let key = CacheKey(code: code, language: language)
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        return await withCheckedContinuation { cont in
            pendingCoalesce.append(PendingEntry(code: code, language: language, cont: cont))
            if !flushScheduled {
                flushScheduled = true
                Task { [weak self] in await self?.flushCoalesced() }
            }
        }
    }

    /// Private synchronous path: run a single JSCore request and update
    /// the cache. Used by `highlightBatch`'s fallback (when
    /// `tokenizeBatchFn` is absent) and by `flushCoalesced`'s internal
    /// batch call.
    private func highlightDirect(code: String, language: String?) -> [SyntaxToken] {
        let key = CacheKey(code: code, language: language)
        if let cached = cache[key] {
            touch(key)
            return cached
        }

        guard let fn = tokenizeFn else {
            return [SyntaxToken(text: code, scope: nil)]
        }

        let args: [Any] = language != nil ? [code, language!] : [code, NSNull()]
        guard let result = fn.call(withArguments: args),
            let jsonString = result.toString(),
            let data = jsonString.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [[Any]]
        else {
            return [SyntaxToken(text: code, scope: nil)]
        }

        let tokens: [SyntaxToken] = parsed.compactMap { pair -> SyntaxToken? in
            guard pair.count >= 2, let text = pair[0] as? String else { return nil }
            let scope = pair[1] as? String
            return SyntaxToken(text: text, scope: scope)
        }

        insert(key: key, tokens: tokens)
        return tokens
    }

    // MARK: - Coalescing

    private struct PendingEntry {
        let code: String
        let language: String?
        let cont: CheckedContinuation<[SyntaxToken], Never>
    }
    private var pendingCoalesce: [PendingEntry] = []
    private var flushScheduled = false

    /// Coalescing flush — runs inside the actor. `await Task.yield()` is
    /// the key: it releases the actor so other `highlight(...)` callers
    /// queued in the same tick can enter and enqueue. After yield returns,
    /// we have the complete batch and process it in one shot.
    private func flushCoalesced() async {
        await Task.yield()

        let batch = pendingCoalesce
        pendingCoalesce = []
        flushScheduled = false
        guard !batch.isEmpty else { return }

        // Multiple callers in the same tick may request identical
        // (code, lang) — dedupe within the batch and send only one JS
        // request whose result they share.
        var unique: [(code: String, language: String?)] = []
        var keyToUniqueIdx: [CacheKey: Int] = [:]
        var entryToUniqueIdx = [Int](repeating: 0, count: batch.count)
        for (i, entry) in batch.enumerated() {
            let key = CacheKey(code: entry.code, language: entry.language)
            if let ui = keyToUniqueIdx[key] {
                entryToUniqueIdx[i] = ui
            } else {
                let ui = unique.count
                unique.append((entry.code, entry.language))
                keyToUniqueIdx[key] = ui
                entryToUniqueIdx[i] = ui
            }
        }

        let uniqueResults = highlightBatch(unique)
        for (i, entry) in batch.enumerated() {
            entry.cont.resume(returning: uniqueResults[entryToUniqueIdx[i]])
        }
    }

    /// Batch highlight. For multiple code blocks in one assistant message,
    /// a single JSCore call + JSON round-trip handles them all, saving
    /// (N-1) entry hops vs. calling `highlight(_:language:)` N times.
    /// Each request still consults the LRU cache; only misses are packed
    /// into the JS call.
    func highlightBatch(_ requests: [(code: String, language: String?)]) -> [[SyntaxToken]] {
        guard !requests.isEmpty else { return [] }

        // Check the cache first; record miss indices, batch-send them to
        // JS, and slot the results back in original order.
        var results: [[SyntaxToken]?] = Array(repeating: nil, count: requests.count)
        var missIndices: [Int] = []
        var missPayload: [(String, String?)] = []

        for (i, req) in requests.enumerated() {
            let key = CacheKey(code: req.code, language: req.language)
            if let cached = cache[key] {
                touch(key)
                results[i] = cached
            } else {
                missIndices.append(i)
                missPayload.append((req.code, req.language))
            }
        }

        if missIndices.isEmpty {
            return results.compactMap { $0 }
        }

        // Prefer the batch JS entry point; older bundles lack it, so fall
        // back to per-call.
        if let batchFn = tokenizeBatchFn {
            let payload: [[Any]] = missPayload.map { [$0.0, $0.1 as Any? ?? NSNull()] }
            if let payloadData = try? JSONSerialization.data(withJSONObject: payload),
                let payloadJSON = String(data: payloadData, encoding: .utf8),
                let rv = batchFn.call(withArguments: [payloadJSON]),
                let jsonString = rv.toString(),
                let data = jsonString.data(using: .utf8),
                let parsed = try? JSONSerialization.jsonObject(with: data) as? [[[Any]]],
                parsed.count == missIndices.count
            {
                for (offset, origIndex) in missIndices.enumerated() {
                    let tokens: [SyntaxToken] = parsed[offset].compactMap { pair in
                        guard pair.count >= 2, let text = pair[0] as? String else { return nil }
                        let scope = pair[1] as? String
                        return SyntaxToken(text: text, scope: scope)
                    }
                    let req = requests[origIndex]
                    insert(key: CacheKey(code: req.code, language: req.language), tokens: tokens)
                    results[origIndex] = tokens
                }
                return results.map { $0 ?? [] }
            }
            // JS batch call failed → degrade to per-call.
            appLog(.warning, "SyntaxHighlightEngine", "tokenizeBatch failed; falling back per-call")
        }

        for origIndex in missIndices {
            let req = requests[origIndex]
            let tokens = highlightDirect(code: req.code, language: req.language)
            results[origIndex] = tokens
        }
        return results.map { $0 ?? [] }
    }

    // MARK: - LRU helpers

    private func touch(_ key: CacheKey) {
        if let idx = lruOrder.firstIndex(of: key) {
            lruOrder.remove(at: idx)
        }
        lruOrder.append(key)
    }

    private func insert(key: CacheKey, tokens: [SyntaxToken]) {
        cache[key] = tokens
        lruOrder.append(key)
        while cache.count > maxCacheEntries, let evict = lruOrder.first {
            lruOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
    }
}

// MARK: - EnvironmentKey

private struct SyntaxEngineKey: EnvironmentKey {
    static let defaultValue: SyntaxHighlightEngine? = nil
}

extension EnvironmentValues {
    var syntaxEngine: SyntaxHighlightEngine? {
        get { self[SyntaxEngineKey.self] }
        set { self[SyntaxEngineKey.self] = newValue }
    }
}
