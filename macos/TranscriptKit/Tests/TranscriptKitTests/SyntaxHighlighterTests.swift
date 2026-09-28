import XCTest

@testable import TranscriptSource

/// The lexer's classes, read back as `(text, kind)` pairs.
final class SyntaxHighlighterTests: XCTestCase {

    private func tokens(_ source: String, _ language: SourceLanguage) -> [(String, SourceToken.Kind)] {
        let units = Array(source.utf16)
        return SyntaxHighlighter.tokens(in: source, language: language).map {
            (String(decoding: units[$0.range], as: UTF16.self), $0.kind)
        }
    }

    private func kind(of word: String, in source: String, _ language: SourceLanguage = .swift) -> SourceToken.Kind? {
        tokens(source, language).first { $0.0 == word }?.1
    }

    func testSwiftDeclarationsKeywordsAndSystemTypes() {
        let source = "@MainActor\nfinal class Loader: NSViewController {\n    let fileURL: URL\n    func load() {}\n}"
        XCTAssertEqual(kind(of: "@MainActor", in: source), .attribute)
        XCTAssertEqual(kind(of: "final", in: source), .keyword)
        XCTAssertEqual(kind(of: "Loader", in: source), .declarationType)
        XCTAssertEqual(kind(of: "NSViewController", in: source), .systemType)
        XCTAssertEqual(kind(of: "fileURL", in: source), .declarationOther)
        XCTAssertEqual(kind(of: "URL", in: source), .systemType)
        XCTAssertEqual(kind(of: "load", in: source), .declarationOther)
    }

    func testCommentsDocumentationAndMarks() {
        let source = "/// Docs.\n// MARK: - Loading\n// plain\n/* block\n spans */ let x = 1"
        let kinds = tokens(source, .swift)
        XCTAssertEqual(kinds[0].0, "///")
        XCTAssertEqual(kinds[0].1, .comment)
        XCTAssertEqual(kinds[1].0, " Docs.")
        XCTAssertEqual(kinds[1].1, .documentationComment)
        XCTAssertEqual(kinds[2].1, .mark)
        XCTAssertEqual(kinds[3].1, .comment)
        XCTAssertEqual(kinds[4].0, "/* block\n spans */")
        XCTAssertEqual(kinds[4].1, .comment)
        XCTAssertEqual(kind(of: "1", in: source), .number)
    }

    func testInterpolationIsCodeNotString() {
        let found = tokens(#"let s = "a \(count) b""#, .swift).filter { $0.1 == .string }.map(\.0)
        XCTAssertEqual(found, [#""a "#, #" b""#])
    }

    func testMultilineStringsAndEscapedQuotes() {
        let source = "let a = \"\"\"\nline \"quoted\"\n\"\"\"\nlet b = \"x\\\"y\""
        let strings = tokens(source, .swift).filter { $0.1 == .string }.map(\.0)
        XCTAssertEqual(strings, ["\"\"\"\nline \"quoted\"\n\"\"\"", "\"x\\\"y\""])
    }

    func testShellCommentsAndPythonDecorators() {
        XCTAssertEqual(kind(of: "# note", in: "ls -la # note", .shell), .comment)
        XCTAssertEqual(kind(of: "if", in: "if [ -f x ]; then echo; fi", .shell), .keyword)
        XCTAssertEqual(kind(of: "@cache", in: "@cache\ndef f(): pass", .python), .attribute)
        XCTAssertEqual(kind(of: "f", in: "@cache\ndef f(): pass", .python), .declarationOther)
    }

    func testCDirectivesRunToTheEndOfTheLine() {
        XCTAssertEqual(kind(of: "#include <stdio.h>", in: "#include <stdio.h>\nint x;", .cFamily), .preprocessor)
    }

    func testPlainTextHasNoTokens() {
        XCTAssertTrue(tokens("if let x = 1", .plainText).isEmpty)
    }

    func testTheLanguageComesFromTheFileName() {
        XCTAssertEqual(SourceLanguage.forPath("/a/b/View.swift"), .swift)
        XCTAssertEqual(SourceLanguage.forPath("main.tsx"), .javaScript)
        XCTAssertEqual(SourceLanguage.forPath("/repo/Makefile"), .shell)
        XCTAssertEqual(SourceLanguage.forPath("notes.txt"), .plainText)
    }
}
