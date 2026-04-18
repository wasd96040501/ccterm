import JavaScriptCore
import SwiftUI

actor SyntaxHighlightEngine {
    private var context: JSContext?
    private var tokenizeFn: JSValue?

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

        return parsed.compactMap { pair -> SyntaxToken? in
            guard pair.count >= 2, let text = pair[0] as? String else { return nil }
            let scope = pair[1] as? String
            return SyntaxToken(text: text, scope: scope)
        }
    }

    var isLoaded: Bool { tokenizeFn != nil }
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
