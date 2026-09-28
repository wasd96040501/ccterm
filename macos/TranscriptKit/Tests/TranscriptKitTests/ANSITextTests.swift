import XCTest

@testable import TranscriptSource

/// Command output read into lines: colours kept, every other escape dropped.
final class ANSITextTests: XCTestCase {

    func testColoursBecomeRunsOverThePlainText() {
        let lines = ANSIText.lines(of: "ok \u{1B}[1;31mfailed\u{1B}[0m done\n\u{1B}[32mgreen")
        XCTAssertEqual(lines.map(\.text), ["ok failed done", "green"])
        XCTAssertEqual(lines.map(\.number), [1, 2])
        XCTAssertEqual(lines[0].styles, [SourceStyleRun(range: 3..<9, foreground: .red, isBold: true)])
        XCTAssertEqual(lines[1].styles, [SourceStyleRun(range: 0..<5, foreground: .green)])
    }

    func testExtendedColours() {
        let lines = ANSIText.lines(of: "\u{1B}[38;5;196mx\u{1B}[38;2;1;2;3my")
        XCTAssertEqual(lines[0].styles.map(\.foreground), [.rgb(255, 0, 0), .rgb(1, 2, 3)])
    }

    func testOtherSequencesAreDroppedAndCarriageReturnsRewriteTheLine() {
        let output = "\u{1B}]0;title\u{07}\u{1B}[2Kprogress 10%\rprogress 100%\r\nnext\n"
        XCTAssertEqual(ANSIText.lines(of: output).map(\.text), ["progress 100%", "next"])
    }

    func testPlainTextStripsEverything() {
        XCTAssertEqual(ANSIText.plainText(of: "\u{1B}[33mwarn\u{1B}[0m"), "warn")
        XCTAssertEqual(ANSIText.plainText(of: "untouched"), "untouched")
    }

    func testEmptyOutputIsOneEmptyLine() {
        XCTAssertEqual(ANSIText.lines(of: "").map(\.text), [""])
    }
}
