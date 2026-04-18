import JavaScriptCore
import SwiftUI

actor SyntaxHighlightEngine {
    private var context: JSContext?
    private var tokenizeFn: JSValue?

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
    }

    func highlight(code: String, language: String?) -> [SyntaxToken] {
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
