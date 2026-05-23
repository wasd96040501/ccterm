import XCTest

@testable import ccterm

/// Pure-logic coverage for `String.collapsedSingleLineForDisplay`,
/// the sidebar's title sanitizer. Each test pins a specific category
/// of "garbage" upstream titles can carry — newlines, tabs, control
/// chars, zero-width formatting, leading/trailing whitespace, or
/// combinations — to the single-line clean form the cell expects.
@MainActor
final class SidebarTitleSanitizerTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPassThroughAlreadyClean() {
        XCTAssertEqual("Refactor login".collapsedSingleLineForDisplay(), "Refactor login")
        XCTAssertEqual("重构登录".collapsedSingleLineForDisplay(), "重构登录")
        XCTAssertEqual("".collapsedSingleLineForDisplay(), "")
    }

    func testCollapsesEveryUnicodeNewlineVariant() {
        XCTAssertEqual("a\nb".collapsedSingleLineForDisplay(), "a b")
        XCTAssertEqual("a\rb".collapsedSingleLineForDisplay(), "a b")
        XCTAssertEqual("a\r\nb".collapsedSingleLineForDisplay(), "a b")
        XCTAssertEqual("a\u{0085}b".collapsedSingleLineForDisplay(), "a b")  // NEL
        XCTAssertEqual("a\u{2028}b".collapsedSingleLineForDisplay(), "a b")  // LS
        XCTAssertEqual("a\u{2029}b".collapsedSingleLineForDisplay(), "a b")  // PS
        XCTAssertEqual("a\u{000B}b".collapsedSingleLineForDisplay(), "a b")  // VT
        XCTAssertEqual("a\u{000C}b".collapsedSingleLineForDisplay(), "a b")  // FF
    }

    func testCollapsesTabsAndConsecutiveWhitespace() {
        XCTAssertEqual("a\tb".collapsedSingleLineForDisplay(), "a b")
        XCTAssertEqual("a  b".collapsedSingleLineForDisplay(), "a b")
        XCTAssertEqual("a \t \n b".collapsedSingleLineForDisplay(), "a b")
        XCTAssertEqual("a\n\n\nb".collapsedSingleLineForDisplay(), "a b")
    }

    func testTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual("   leading".collapsedSingleLineForDisplay(), "leading")
        XCTAssertEqual("trailing   ".collapsedSingleLineForDisplay(), "trailing")
        XCTAssertEqual("\n\tboth\n\t".collapsedSingleLineForDisplay(), "both")
        XCTAssertEqual("   ".collapsedSingleLineForDisplay(), "")
        XCTAssertEqual("\n\n".collapsedSingleLineForDisplay(), "")
    }

    func testDropsAsciiControlCharactersOtherThanWhitespace() {
        // \u{01} STX, \u{1F} US, \u{7F} DEL — invisible / would render
        // as `.notdef` boxes inside a single-line label.
        XCTAssertEqual("hi\u{0001}there".collapsedSingleLineForDisplay(), "hithere")
        XCTAssertEqual("hi\u{001F}there".collapsedSingleLineForDisplay(), "hithere")
        XCTAssertEqual("hi\u{007F}there".collapsedSingleLineForDisplay(), "hithere")
    }

    func testDropsZeroWidthAndBidiFormattingControls() {
        XCTAssertEqual("zero\u{200B}width".collapsedSingleLineForDisplay(), "zerowidth")
        XCTAssertEqual("nj\u{200C}joiner".collapsedSingleLineForDisplay(), "njjoiner")
        XCTAssertEqual("z\u{200D}wj".collapsedSingleLineForDisplay(), "zwj")
        XCTAssertEqual("word\u{2060}joiner".collapsedSingleLineForDisplay(), "wordjoiner")
        XCTAssertEqual("bom\u{FEFF}prefix".collapsedSingleLineForDisplay(), "bomprefix")
        XCTAssertEqual("obj\u{FFFC}repl".collapsedSingleLineForDisplay(), "objrepl")
        // Bidi isolates — LRI / RLI / FSI / PDI.
        XCTAssertEqual("a\u{2066}b\u{2069}c".collapsedSingleLineForDisplay(), "abc")
    }

    func testCombinedRealWorldTitle() {
        // Mimics the kind of title `Session.title` may derive from a
        // multi-paragraph user message that also pasted some code.
        let raw =
            "  Investigate the failing deploy\n\trerun the canary across\u{200B} all regions  "
        XCTAssertEqual(
            raw.collapsedSingleLineForDisplay(),
            "Investigate the failing deploy rerun the canary across all regions")
    }

    func testIdempotent() {
        let raw = "  a\n\tb\u{200B}c  "
        let once = raw.collapsedSingleLineForDisplay()
        XCTAssertEqual(once.collapsedSingleLineForDisplay(), once)
    }
}
