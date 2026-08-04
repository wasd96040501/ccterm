import XCTest

@testable import TranscriptKit

/// The parser layer, as values.
///
/// Pure, unlike `MarkdownRowTests` — every question here is about the IR rather
/// than about pixels, and the IR is settled before a width exists. What it is
/// really guarding is the set of decisions `MarkdownParser` makes on cmark's
/// behalf: which parse options are on, what a node with no rendering degrades
/// to, and the two answers cmark computes and swift-markdown declines to hand
/// over.
final class MarkdownParserTests: XCTestCase {

    private enum Unexpected: Error { case shape }

    private func blocks(_ source: String) -> [MarkdownIR.BlockNode] {
        MarkdownParser.document(source).blocks
    }

    /// The inlines of the document's first paragraph.
    private func inlines(
        _ source: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [MarkdownIR.InlineNode] {
        guard case .paragraph(let inlines)? = blocks(source).first else {
            XCTFail("expected a paragraph", file: file, line: line)
            throw Unexpected.shape
        }
        return inlines
    }

    private func list(
        _ source: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> MarkdownIR.List {
        guard case .list(let list)? = blocks(source).first else {
            XCTFail("expected a list", file: file, line: line)
            throw Unexpected.shape
        }
        return list
    }

    // MARK: - Smart typography stays off

    /// The one that matters most in a transcript: `--amend` is a flag, not an
    /// en dash, and a straight quote is what the program printed. Smart
    /// typography is swift-markdown's default, so this is a live setting rather
    /// than an inherited one.
    func testStraightQuotesAndDoubleHyphensSurviveParsing() throws {
        let source = #"He said "hi" -- run git commit --amend ... ok"#
        XCTAssertEqual(try inlines(source), [.text(source)])
    }

    // MARK: - Code fences

    /// CommonMark's info string is "language, then whatever the consumer wants".
    /// Passing the whole run through puts `swift title="x"` in the language chip.
    func testFenceInfoStringContributesOnlyItsFirstWord() throws {
        guard case .codeBlock(let code)? = blocks("```swift title=\"x\"\nlet a = 1\n```").first
        else { throw Unexpected.shape }

        XCTAssertEqual(code.language, "swift")
        XCTAssertEqual(code.code, "let a = 1")
    }

    func testBareFenceHasNoLanguage() throws {
        guard case .codeBlock(let code)? = blocks("```\nplain\n```").first else {
            throw Unexpected.shape
        }
        XCTAssertNil(code.language)
    }

    // MARK: - Loose and tight lists
    //
    // cmark settles this while parsing and swift-markdown exposes no `isTight`,
    // so the parser recovers it from source positions. These four are the whole
    // of CommonMark's rule.

    func testConsecutiveItemsMakeATightList() throws {
        XCTAssertTrue(try list("- a\n- b").isTight)
    }

    func testBlankLineBetweenItemsMakesAListLoose() throws {
        XCTAssertFalse(try list("- a\n\n- b").isTight)
    }

    func testBlankLineInsideOneItemMakesAListLoose() throws {
        XCTAssertFalse(try list("- a\n\n  still a\n- b").isTight)
    }

    /// A sub-list is two blocks inside one item with no blank line between them,
    /// which is exactly the case the rule does *not* call loose.
    func testASubListDoesNotOnItsOwnMakeAListLoose() throws {
        XCTAssertTrue(try list("- a\n  - nested\n- b").isTight)
    }

    /// The blank line that *ends* a tight list is not inside it. cmark hands the
    /// last item a range covering that line, which is why the derivation reads
    /// item content rather than item ranges.
    func testBlankLineAfterATightListLeavesItTight() throws {
        XCTAssertTrue(try list("- a\n- b\n\nafter").isTight)
    }

    // MARK: - GFM extended autolinks

    func testWwwPrefixedHostLinksWithASchemeItNeverHad() throws {
        XCTAssertEqual(
            try inlines("see www.example.com now"),
            [
                .text("see "),
                .link(
                    destination: "http://www.example.com", title: nil,
                    children: [.text("www.example.com")]),
                .text(" now"),
            ])
    }

    func testEmailAddressLinksAsMailto() throws {
        XCTAssertEqual(
            try inlines("mail user@example.com"),
            [
                .text("mail "),
                .link(
                    destination: "mailto:user@example.com", title: nil,
                    children: [.text("user@example.com")]),
            ])
    }

    func testExplicitSchemeIsItsOwnDestination() throws {
        XCTAssertEqual(
            try inlines("at https://example.com/a"),
            [
                .text("at "),
                .link(
                    destination: "https://example.com/a", title: nil,
                    children: [.text("https://example.com/a")]),
            ])
    }

    /// GFM requires the `www.` prefix or a scheme, which is also the answer a
    /// transcript wants — `socket.io` is a package name. Paired with something
    /// that *does* link so the detector actually runs, rather than the paragraph
    /// leaving through the fast path.
    func testBareDomainStaysTextEvenBesideOneThatLinks() throws {
        XCTAssertEqual(
            try inlines("socket.io and www.example.com"),
            [
                .text("socket.io and "),
                .link(
                    destination: "http://www.example.com", title: nil,
                    children: [.text("www.example.com")]),
            ])
    }

    /// A URL in a link's *text* must not become a link of its own inside the
    /// one that already wraps it.
    func testUrlInsideLinkTextIsNotAutolinked() throws {
        XCTAssertEqual(
            try inlines("[https://example.com](https://other.com)"),
            [
                .link(
                    destination: "https://other.com", title: nil,
                    children: [.text("https://example.com")])
            ])
    }

    // MARK: - Footnotes
    //
    // swift-markdown has no footnote node, so all of this is `MarkdownFootnotes`
    // bracketing the parse: definitions lifted out of the source before it,
    // references split out of the text after.

    /// Numbered by the order a reader meets them, not by the order they were
    /// defined — `b` is referred to first, so `b` is 1.
    func testFootnotesAreNumberedByFirstReference() throws {
        let document = MarkdownParser.document("x[^b] y[^a]\n\n[^a]: A\n[^b]: B")

        XCTAssertEqual(document.footnotes.map(\.number), [1, 2])
        XCTAssertEqual(document.footnotes.map(\.label), ["b", "a"])
        XCTAssertEqual(
            try inlines("x[^b] y[^a]\n\n[^a]: A\n[^b]: B"),
            [
                .text("x"),
                .footnoteReference(label: "b", number: 1),
                .text(" y"),
                .footnoteReference(label: "a", number: 2),
            ])
    }

    /// The same label twice is one note, referred to twice.
    func testRepeatedReferenceReusesItsNumber() throws {
        let document = MarkdownParser.document("x[^a] y[^a]\n\n[^a]: A")
        XCTAssertEqual(document.footnotes.count, 1)
        XCTAssertEqual(
            try inlines("x[^a] y[^a]\n\n[^a]: A"),
            [
                .text("x"),
                .footnoteReference(label: "a", number: 1),
                .text(" y"),
                .footnoteReference(label: "a", number: 1),
            ])
    }

    /// Kept as written. Dropping it would lose a word the author typed, and
    /// numbering it would point at nothing.
    func testReferenceWithNoDefinitionStaysText() throws {
        let document = MarkdownParser.document("see[^gone] here")
        XCTAssertTrue(document.footnotes.isEmpty)
        XCTAssertEqual(try inlines("see[^gone] here"), [.text("see[^gone] here")])
    }

    /// The opposite case, and the opposite answer: scaffolding for a reference
    /// that was edited away renders as nothing.
    func testDefinitionWithNoReferenceIsDropped() throws {
        let document = MarkdownParser.document("prose\n\n[^a]: A note nobody cites.")
        XCTAssertTrue(document.footnotes.isEmpty)
        XCTAssertEqual(document.blocks.count, 1)
    }

    func testFootnoteBodyKeepsItsOwnBlocks() throws {
        let document = MarkdownParser.document(
            "x[^a]\n\n[^a]: First paragraph.\n\n    Second paragraph.")
        let note = try XCTUnwrap(document.footnotes.first)
        XCTAssertEqual(note.blocks.count, 2)
    }

    /// A reference inside a container has to survive the walk that rebuilds it.
    func testReferenceInsideAListItemResolves() throws {
        let list = try list("- item[^a]\n\n[^a]: A")
        guard case .paragraph(let inlines)? = list.items.first?.content.first else {
            throw Unexpected.shape
        }
        XCTAssertEqual(inlines, [.text("item"), .footnoteReference(label: "a", number: 1)])
    }

    /// A definition starts a block; a line inside a paragraph that happens to
    /// look like one is prose. Lifting it would tear the paragraph in half.
    func testDefinitionShapedLineInsideAParagraphIsLeftAlone() throws {
        let document = MarkdownParser.document("prose x[^a]\n[^a]: not a definition")
        XCTAssertTrue(document.footnotes.isEmpty)
        XCTAssertEqual(document.blocks.count, 1)
    }

    /// Definitions are blanked rather than removed, so the lines below one stay
    /// where they were — which is what `isTight` reads.
    func testLiftingADefinitionDoesNotDisturbListTightness() throws {
        XCTAssertTrue(try list("- a\n- b\n\n[^x]: note\n\nsee[^x]").isTight)
        XCTAssertFalse(try list("- a\n\n- b\n\n[^x]: note\n\nsee[^x]").isTight)
    }

    // MARK: - Titles

    func testLinkCarriesItsTitle() throws {
        XCTAssertEqual(
            try inlines(#"[a](https://x.com "T")"#),
            [.link(destination: "https://x.com", title: "T", children: [.text("a")])])
    }

    func testImageCarriesBothAltAndTitle() throws {
        XCTAssertEqual(
            try inlines(#"![alt](pic.png "T")"#),
            [.image(source: "pic.png", title: "T", alt: "alt")])
    }

    func testImageWithoutATitleReportsNil() throws {
        XCTAssertEqual(
            try inlines("![alt](pic.png)"), [.image(source: "pic.png", title: nil, alt: "alt")])
    }
}
