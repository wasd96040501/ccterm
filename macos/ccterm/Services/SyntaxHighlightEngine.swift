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
        // 可选：批量入口。老 bundle 可能没有，缺失时自动降级到 per-call。
        if let batch = ctx.objectForKeyedSubscript("tokenizeBatch"), !batch.isUndefined {
            self.tokenizeBatchFn = batch
        }
    }

    /// External single-request API. **自动聚合**：同一个 event-loop tick 内
    /// 到达的多个 `highlight(...)` 调用会合并成一次 `highlightBatch` 内部调用,
    /// 只跨一次 JSCore 边界。caller 不感知——每人拿到自己那份 tokens 就行。
    ///
    /// 实现：cache miss → 排入 `pendingCoalesce`，第一个 miss 调度 flush task；
    /// flush task 做一次 `Task.yield()` 让同 tick 排队的 caller 进入 actor 追加,
    /// yield 返回后拿完整 batch 去 JSCore。
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

    /// Private synchronous path: 直接跑 JSCore 单请求 + 更新 cache。
    /// 给 `highlightBatch` 的 fallback 用（当 tokenizeBatchFn 缺失时）和
    /// `flushCoalesced` 的内部 batch 调用。
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

    /// Coalescing flush——actor 内部执行。`await Task.yield()` 是关键：它让出
    /// actor，给同 tick 排在后面等入 actor 的 `highlight(...)` 机会入队，
    /// yield 返回后拿到完整 batch 一次性批量处理。
    private func flushCoalesced() async {
        await Task.yield()

        let batch = pendingCoalesce
        pendingCoalesce = []
        flushScheduled = false
        guard !batch.isEmpty else { return }

        // 同 tick 里可能多 caller 请求相同 (code, lang)——batch 内去重，只
        // 发一个 JS 请求给它们共用结果。
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

    /// 批量高亮。对一条 assistant 消息里的多段代码块来说，一次 JSCore call
    /// + 一次 JSON 往返即可完成，比 N 次 `highlight(_:language:)` 省掉 (N-1)
    /// 次入口开销。每个请求也会先查 LRU cache；miss 的才被打包进 JS。
    func highlightBatch(_ requests: [(code: String, language: String?)]) -> [[SyntaxToken]] {
        guard !requests.isEmpty else { return [] }

        // 先查缓存；miss 的记下原位下标，批量发给 JS，回来按原顺序补齐。
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

        // 优先用 batch JS 入口；老 bundle 没有则 fall back 到逐条调。
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
            // JS 批量调失败 → 退化为逐条。
            appLog(.warning, "SyntaxHighlightEngine", "tokenizeBatch failed; falling back per-call")
        }

        for origIndex in missIndices {
            let req = requests[origIndex]
            let tokens = highlightDirect(code: req.code, language: req.language)
            results[origIndex] = tokens
        }
        return results.map { $0 ?? [] }
    }

    var isLoaded: Bool { tokenizeFn != nil }

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
