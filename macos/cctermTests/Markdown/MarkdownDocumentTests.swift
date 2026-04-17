import XCTest
@testable import ccterm

final class MarkdownDocumentTests: XCTestCase {
    // MARK: - Helpers

    private func kinds(_ segments: [MarkdownSegment]) -> [String] {
        segments.map {
            switch $0 {
            case .markdown: return "markdown"
            case .codeBlock: return "codeBlock"
            case .table: return "table"
            case .mathBlock: return "mathBlock"
            case .thematicBreak: return "thematicBreak"
            }
        }
    }

    private func blocks(_ segment: MarkdownSegment) -> [MarkdownBlock] {
        guard case .markdown(let bs) = segment else {
            XCTFail("expected .markdown segment, got \(segment)")
            return []
        }
        return bs
    }

    private func firstPlainText(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s): return s
            case .emphasis(let c), .strong(let c), .strikethrough(let c): return firstPlainText(c)
            case .code(let s): return s
            case .link(_, let c): return firstPlainText(c)
            case .image(_, let alt): return alt
            case .inlineMath(let s): return s
            case .lineBreak, .softBreak: return " "
            }
        }.joined()
    }

    // MARK: - Tests

    func testKitchenSink() {
        let src = """
        # Heading 1

        A paragraph with **bold**, *italic*, ~~strike~~, `code`, a [link](https://x).

        ## Heading 2

        - unordered item
        - second item
          - nested item

        1. ordered
        2. second

        - [x] done
        - [ ] todo

        > quote line
        > second quote line

        ![alt text](https://img.png)

        Inline math $a+b$ here.

        ```swift
        let x = 1
        ```

        | a | b |
        |:--|--:|
        | 1 | 2 |

        ---

        $$
        x = y + z
        $$

        Final paragraph.
        """

        let segs = MarkdownDocument(parsing: src).segments
        XCTAssertEqual(
            kinds(segs),
            ["markdown", "codeBlock", "table", "thematicBreak", "mathBlock", "markdown"]
        )

        // First markdown group has headings, paragraphs, lists, blockquote, image paragraph, inline math.
        let first = blocks(segs[0])
        let blockKinds = first.map { block -> String in
            switch block {
            case .heading: return "heading"
            case .paragraph: return "paragraph"
            case .list(let l): return l.ordered ? "ol" : "ul"
            case .blockquote: return "blockquote"
            }
        }
        XCTAssertEqual(
            blockKinds,
            ["heading", "paragraph", "heading", "ul", "ol", "ul", "blockquote", "paragraph", "paragraph"]
        )

        // Code block content
        if case .codeBlock(let cb) = segs[1] {
            XCTAssertEqual(cb.language, "swift")
            XCTAssertEqual(cb.code, "let x = 1")
        } else { XCTFail("expected codeBlock") }

        // Table dimensions and alignments
        if case .table(let t) = segs[2] {
            XCTAssertEqual(t.header.count, 2)
            XCTAssertEqual(t.alignments, [.left, .right])
            XCTAssertEqual(t.rows.count, 1)
            XCTAssertEqual(t.rows[0].count, 2)
        } else { XCTFail("expected table") }

        // Math block strips delimiters
        if case .mathBlock(let m) = segs[4] {
            XCTAssertEqual(m, "x = y + z")
        } else { XCTFail("expected mathBlock") }
    }

    func testConsecutiveTextBlocksMerge() {
        let src = """
        First paragraph.

        Second paragraph.

        ## A heading

        Another paragraph.
        """
        let segs = MarkdownDocument(parsing: src).segments
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(blocks(segs[0]).count, 4)
    }

    func testCodeBlockSplitsText() {
        let src = """
        para1

        ```
        code
        ```

        para2
        """
        let segs = MarkdownDocument(parsing: src).segments
        XCTAssertEqual(kinds(segs), ["markdown", "codeBlock", "markdown"])
        if case .codeBlock(let cb) = segs[1] {
            XCTAssertNil(cb.language)
            XCTAssertEqual(cb.code, "code")
        } else { XCTFail() }
    }

    func testBlockMathOnlyWhenIsolated() {
        // Inline $$x$$ inside a paragraph must not be split as a block.
        let src1 = "para with $$x$$ inline"
        XCTAssertEqual(kinds(MarkdownDocument(parsing: src1).segments), ["markdown"])

        // Same-line $$...$$ surrounded by blank lines is a block.
        let src2 = """
        before

        $$x$$

        after
        """
        let segs2 = MarkdownDocument(parsing: src2).segments
        XCTAssertEqual(kinds(segs2), ["markdown", "mathBlock", "markdown"])
        if case .mathBlock(let m) = segs2[1] { XCTAssertEqual(m, "x") }

        // Multi-line block math.
        let src3 = """
        $$
        a = b
        c = d
        $$
        """
        let segs3 = MarkdownDocument(parsing: src3).segments
        XCTAssertEqual(kinds(segs3), ["mathBlock"])
        if case .mathBlock(let m) = segs3[0] { XCTAssertEqual(m, "a = b\nc = d") }
    }

    func testInlineMathEscapeAndBoundaries() {
        // Escape: \$ is not a delimiter.
        let src1 = "price is \\$5 and \\$10"
        let segs1 = MarkdownDocument(parsing: src1).segments
        let blocks1 = blocks(segs1[0])
        XCTAssertEqual(firstPlainText(blockInlines(blocks1[0])), "price is $5 and $10")

        // Numeric context: $5 $10 should not pair as math.
        let src2 = "costs $5 and $10 dollars"
        let segs2 = MarkdownDocument(parsing: src2).segments
        let inlines2 = blockInlines(blocks(segs2[0])[0])
        XCTAssertFalse(inlines2.contains { if case .inlineMath = $0 { return true }; return false })

        // Newline inside $...$ breaks the match.
        let src3 = "$a\nb$ tail"
        let segs3 = MarkdownDocument(parsing: src3).segments
        let inlines3 = blockInlines(blocks(segs3[0])[0])
        XCTAssertFalse(inlines3.contains { if case .inlineMath = $0 { return true }; return false })

        // Two valid inline math.
        let src4 = "$a$ and $b$"
        let segs4 = MarkdownDocument(parsing: src4).segments
        let inlines4 = blockInlines(blocks(segs4[0])[0])
        let mathCount = inlines4.reduce(0) { acc, n in
            if case .inlineMath = n { return acc + 1 }; return acc
        }
        XCTAssertEqual(mathCount, 2)
    }

    func testTaskListCheckbox() {
        let src = """
        - [x] done
        - [ ] todo
        - plain
        """
        let segs = MarkdownDocument(parsing: src).segments
        guard case .list(let list) = blocks(segs[0])[0] else {
            XCTFail("expected list"); return
        }
        XCTAssertFalse(list.ordered)
        XCTAssertEqual(list.items.count, 3)
        XCTAssertEqual(list.items[0].checkbox, .checked)
        XCTAssertEqual(list.items[1].checkbox, .unchecked)
        XCTAssertNil(list.items[2].checkbox)
    }

    func testTableAlignments() {
        let src = """
        | a | b | c | d |
        |:--|:-:|--:|---|
        | 1 | 2 | 3 | 4 |
        """
        let segs = MarkdownDocument(parsing: src).segments
        guard case .table(let t) = segs[0] else { XCTFail(); return }
        XCTAssertEqual(t.alignments, [.left, .center, .right, .none])
    }

    func testNestedListPreserved() {
        let src = """
        - outer 1
          - inner 1a
          - inner 1b
        - outer 2
        """
        let segs = MarkdownDocument(parsing: src).segments
        guard case .list(let outer) = blocks(segs[0])[0] else { XCTFail(); return }
        XCTAssertEqual(outer.items.count, 2)
        // First outer item should contain a paragraph + a nested list.
        let firstItemBlocks = outer.items[0].content
        let hasNestedList = firstItemBlocks.contains { block in
            if case .list = block { return true }; return false
        }
        XCTAssertTrue(hasNestedList, "first outer item should contain a nested list")
    }

    func testEmptyAndWhitespaceAndHR() {
        XCTAssertEqual(MarkdownDocument(parsing: "").segments, [])
        XCTAssertEqual(MarkdownDocument(parsing: "   \n\n   ").segments, [])
        XCTAssertEqual(MarkdownDocument(parsing: "---").segments, [.thematicBreak])
    }

    func testMalformedTableDoesNotCrash() {
        // Missing header separator line — cmark-gfm falls back to paragraph text.
        let src = """
        | a | b |
        | 1 | 2 |
        """
        // Just ensure no crash and we get something sensible.
        let segs = MarkdownDocument(parsing: src).segments
        XCTAssertFalse(segs.isEmpty)
    }

    // MARK: - Private helpers

    private func blockInlines(_ block: MarkdownBlock) -> [MarkdownInline] {
        switch block {
        case .paragraph(let ins), .heading(_, let ins):
            return ins
        default:
            return []
        }
    }
}
