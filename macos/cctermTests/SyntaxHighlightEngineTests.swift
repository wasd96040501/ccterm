import XCTest

@testable import ccterm

/// Smoke tests for `SyntaxHighlightEngine`. The engine loads
/// `hljs-jscore.js` from the host app bundle — these tests fail loudly if
/// the JS asset goes missing (e.g. someone re-introduces a `Resources/*.js`
/// gitignore rule, or the `make js-bundles` step gets unhooked from
/// `make build`). They are the regression gate that pairs with the
/// `assertionFailure` in `load()`.
final class SyntaxHighlightEngineTests: XCTestCase {
    func testLoadProducesMultipleTokensForMultiLineSwift() async {
        let engine = SyntaxHighlightEngine()
        await engine.load()

        let code = """
            struct Foo {
                let bar: Int
                func baz() -> String { "hi" }
            }
            """
        let tokens = await engine.highlight(code: code, language: "swift")

        XCTAssertGreaterThan(
            tokens.count, 1,
            "Engine returned a single fallback token — hljs-jscore.js likely missing from bundle"
        )
        XCTAssertTrue(
            tokens.contains(where: { $0.scope != nil }),
            "No scoped tokens — highlight.js classification not reaching Swift"
        )
        // Reassemble the source from token text — the engine must not lose
        // characters, only annotate them.
        let reassembled = tokens.map(\.text).joined()
        XCTAssertEqual(reassembled, code)
    }

    func testHighlightBatchReturnsPerRequestTokens() async {
        let engine = SyntaxHighlightEngine()
        await engine.load()

        let results = await engine.highlightBatch([
            (code: "let x = 1", language: "swift"),
            (code: "echo hello", language: "bash"),
        ])

        XCTAssertEqual(results.count, 2)
        XCTAssertGreaterThan(results[0].count, 1)
        XCTAssertGreaterThan(results[1].count, 1)
    }
}
