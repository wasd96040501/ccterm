import XCTest

@testable import ccterm

/// Pure-string tests for `StreamingMarkdownCommit` — the policy that holds
/// incomplete fenced code blocks and tables back from the live stream.
final class StreamingMarkdownCommitTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Plain text commits live

    func testPlainTextCommitsEntirely() {
        let text = "Let me explain.\n\nHere is the reason."
        XCTAssertEqual(StreamingMarkdownCommit.committedPrefix(of: text), text)
        XCTAssertFalse(StreamingMarkdownCommit.hasHeldTail(in: text))
    }

    func testGrowingParagraphCommitsLive() {
        // A partial trailing paragraph is fine to show — it just grows.
        let text = "The sky is blue because of Rayleigh scat"
        XCTAssertEqual(StreamingMarkdownCommit.committedPrefix(of: text), text)
    }

    func testEmptyStringIsEmpty() {
        XCTAssertEqual(StreamingMarkdownCommit.committedPrefix(of: ""), "")
    }

    // MARK: - Fenced code blocks

    func testOpenCodeFenceIsHeld() {
        let text = "Here is code:\n\n```swift\nlet x = 1"
        XCTAssertEqual(
            StreamingMarkdownCommit.committedPrefix(of: text),
            "Here is code:",
            "everything from the opening fence on is held until it closes")
        XCTAssertTrue(StreamingMarkdownCommit.hasHeldTail(in: text))
    }

    func testClosedCodeFenceCommits() {
        let text = "Here is code:\n\n```swift\nlet x = 1\n```\n\nDone."
        XCTAssertEqual(StreamingMarkdownCommit.committedPrefix(of: text), text)
        XCTAssertFalse(StreamingMarkdownCommit.hasHeldTail(in: text))
    }

    func testClosedFenceAtEndCommits() {
        let text = "```\ncode\n```"
        XCTAssertEqual(StreamingMarkdownCommit.committedPrefix(of: text), text)
    }

    func testFenceJustOpenedHoldsAllPriorPrefix() {
        let text = "intro\n\n```"
        XCTAssertEqual(StreamingMarkdownCommit.committedPrefix(of: text), "intro")
    }

    func testTildeFenceIsRecognised() {
        let text = "x\n\n~~~\ncode"
        XCTAssertEqual(StreamingMarkdownCommit.committedPrefix(of: text), "x")
    }

    // MARK: - Tables

    func testGrowingTableIsHeld() {
        let text = "Results:\n\n| Col A | Col B |\n| --- | --- |\n| 1 | 2 |"
        XCTAssertEqual(
            StreamingMarkdownCommit.committedPrefix(of: text),
            "Results:",
            "an unsealed trailing table is held in full")
        XCTAssertTrue(StreamingMarkdownCommit.hasHeldTail(in: text))
    }

    func testTableHeaderOnlyIsHeld() {
        let text = "| Col A | Col B |"
        XCTAssertEqual(StreamingMarkdownCommit.committedPrefix(of: text), "")
    }

    func testTableSealedByBlankLineCommits() {
        let text = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter table."
        XCTAssertEqual(StreamingMarkdownCommit.committedPrefix(of: text), text)
        XCTAssertFalse(StreamingMarkdownCommit.hasHeldTail(in: text))
    }

    func testTableRowWithTrailingNewlineStillHeld() {
        // A single trailing newline does not seal a table (CommonMark needs a
        // blank line); the row run is still "active" and held.
        let text = "intro\n\n| A | B |\n| --- | --- |\n"
        XCTAssertEqual(StreamingMarkdownCommit.committedPrefix(of: text), "intro")
    }

    // MARK: - Precedence + content before structure

    func testTextBeforeHeldTableIsPreserved() {
        let text = "# Title\n\nSome prose here.\n\n| A | B |"
        XCTAssertEqual(
            StreamingMarkdownCommit.committedPrefix(of: text),
            "# Title\n\nSome prose here.")
    }

    func testTextAndClosedCodeBeforeOpenFence() {
        let text = "intro\n\n```\nclosed\n```\n\nmid\n\n```\nopen"
        XCTAssertEqual(
            StreamingMarkdownCommit.committedPrefix(of: text),
            "intro\n\n```\nclosed\n```\n\nmid",
            "only the last, unbalanced fence is held")
    }
}
