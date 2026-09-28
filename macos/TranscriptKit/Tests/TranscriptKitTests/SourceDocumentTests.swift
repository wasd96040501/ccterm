import XCTest

@testable import TranscriptSource

/// How a file, a comparison and a diff's hunks become numbered, changed lines —
/// Xcode's inline comparison as data.
final class SourceDocumentTests: XCTestCase {

    func testAFileIsNumberedFromItsFirstLine() {
        let document = SourceDocument(text: "a\nb\nc\n", firstLine: 10, language: .plainText)
        XCTAssertEqual(document.lines.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(document.lines.map(\.number), [10, 11, 12])
        XCTAssertTrue(document.changes.isEmpty)
    }

    func testAComparisonPutsRemovedLinesAheadOfAddedOnesAndNumbersOnlyTheNewFile() {
        let document = SourceDocument(
            old: "let a = 1\nlet b = false\nlet c = 3", new: "let a = 1\nlet b = true\nlet d = 4\nlet c = 3",
            language: .swift)
        XCTAssertEqual(
            document.lines.map(\.change), [.unchanged, .removed, .added, .added, .unchanged])
        XCTAssertEqual(document.lines.map(\.number), [1, nil, 2, 3, 4])
        XCTAssertEqual(document.changes, [1..<4])
        XCTAssertEqual(document.insertions, 2)
        XCTAssertEqual(document.deletions, 1)
    }

    func testAPairedLineMarksOnlyTheWordsThatChangedAndAnUnpairedOneMarksItsWholeText() {
        let document = SourceDocument(
            old: "var hasLoaded = false", new: "var hasLoaded = true\nvar extra = 0", language: .swift)
        let paired = document.lines[1]
        XCTAssertEqual(paired.change, .added)
        let text = paired.text as NSString
        XCTAssertEqual(paired.changedRanges.map { text.substring(with: NSRange($0)) }, ["true"])
        XCTAssertEqual(document.lines[2].changedRanges, [0..<13])
    }

    func testOnlyAdditionsMarkNoWords() {
        let document = SourceDocument(old: "a", new: "a\nb", language: .plainText)
        XCTAssertEqual(document.lines.map(\.change), [.unchanged, .added])
        XCTAssertEqual(document.lines[1].changedRanges, [])
    }

    func testAdjacentChangedWordsMergeAcrossTheSpacesBetweenThem() {
        let ranges = SourceDocument.changedRanges(in: "one red big cat", comparedWith: "one cat")
        XCTAssertEqual(ranges, [4..<11])
    }

    func testHunksOverTheOriginalShowTheWholeFile() {
        let original = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let hunk = SourceDiffHunk(
            oldStart: 4, oldLines: 3, newStart: 4, newLines: 3, lines: [" line 4", "-line 5", "+line five", " line 6"])
        let document = SourceDocument(hunks: [hunk], original: original, language: .plainText)
        XCTAssertEqual(document.lines.count, 11)
        XCTAssertEqual(document.lines.filter { $0.change == .unchanged }.count, 9)
        XCTAssertEqual(document.lines.last?.number, 10)
        XCTAssertEqual(document.lines[4].change, .removed)
        XCTAssertEqual(document.lines[5].text, "line five")
        XCTAssertEqual(document.lines[5].number, 5)
        XCTAssertEqual(document.changes, [4..<6])
    }

    func testHunksWithoutTheOriginalAreSeparatedByElidedLines() {
        let first = SourceDiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-a", "+b"])
        let second = SourceDiffHunk(oldStart: 20, oldLines: 1, newStart: 20, newLines: 2, lines: [" x", "+y"])
        let document = SourceDocument(hunks: [first, second], language: .plainText)
        XCTAssertEqual(
            document.lines.map(\.change), [.removed, .added, .elided, .unchanged, .added, .elided])
        XCTAssertEqual(document.lines.map(\.number), [nil, 1, nil, 20, 21, nil])
        XCTAssertEqual(document.changes.count, 2)
    }
}
