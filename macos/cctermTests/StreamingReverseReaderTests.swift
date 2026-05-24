import AgentSDK
import XCTest

@testable import ccterm

/// Unit coverage for the unified streaming reverse reader that replaced the
/// tail/prefix split: `ReverseLineReader` (byte-level backward line reader) and
/// `JSONLReversePageSource`'s merge-aware first-page sizing.
@MainActor
final class StreamingReverseReaderTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func tempFile(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        try body.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - ReverseLineReader

    func testReaderYieldsLinesNewestFirst() throws {
        let url = try tempFile("a\nb\nc\nd\n")
        let reader = try ReverseLineReader(url: url)
        var got: [String] = []
        while let line = reader.popLine() { got.append(line) }
        XCTAssertEqual(got, ["d", "c", "b", "a"], "newest line first, backward")
    }

    func testReaderHandlesMissingTrailingNewline() throws {
        let url = try tempFile("a\nb\nc")  // no trailing \n
        let reader = try ReverseLineReader(url: url)
        var got: [String] = []
        while let line = reader.popLine() { got.append(line) }
        XCTAssertEqual(got, ["c", "b", "a"])
    }

    func testReaderSkipsBlankLinesAndEmptyFile() throws {
        let url = try tempFile("a\n\nb\n")  // a blank line in the middle + trailing
        let reader = try ReverseLineReader(url: url)
        var got: [String] = []
        while let line = reader.popLine() { got.append(line) }
        XCTAssertEqual(got, ["b", "a"], "blank lines skipped")

        let empty = try tempFile("")
        let emptyReader = try ReverseLineReader(url: empty)
        XCTAssertNil(emptyReader.popLine(), "empty file yields nothing")
    }

    func testReaderReassemblesLinesAcrossChunkBoundaries() throws {
        // Lines longer than the chunk size must reassemble across reads.
        let lines = (0..<50).map { "line-\($0)-" + String(repeating: "x", count: 200) }
        let url = try tempFile(lines.joined(separator: "\n") + "\n")
        let reader = try ReverseLineReader(url: url, chunkSize: 64)  // tiny chunk
        var got: [String] = []
        while let line = reader.popLine() { got.append(line) }
        XCTAssertEqual(got, lines.reversed(), "every line intact despite 64-byte chunks")
    }

    // MARK: - JSONLReversePageSource: first-page sizing

    /// All-standalone history: the first page is exactly `firstPageEntryTarget`
    /// lines (each text message is one entry), the rest spill to later pages.
    func testFirstPageStandaloneCountMatchesTarget() async throws {
        let lines = (0..<10).map { Message2Fixtures.assistantTextJSONL("seg \($0)") }
        let url = try tempFile(lines.joined(separator: "\n") + "\n")
        let source = JSONLReversePageSource(
            url: url, firstPageEntryTarget: 3, pageLineBudget: 80)

        let first = await source.nextPage()
        XCTAssertEqual(first?.count, 3, "first page = 3 standalone entries = 3 lines")
        let second = await source.nextPage()
        XCTAssertEqual(second?.count, 7, "remaining 7 land on the next budgeted page")
        let third = await source.nextPage()
        XCTAssertNil(third, "file top reached")
    }

    /// Merge-aware: a run of consecutive tool children (tool_use + tool_result)
    /// counts as ONE entry, so the first page pulls the WHOLE run rather than
    /// splitting it at a raw line boundary. Layout: [oldest filler…, S_old,
    /// 6-line tool run, S_new]. With target 3, reading backward stops after
    /// S_new (1) + run (2) + S_old (3) — all 8 lines, run intact.
    func testFirstPageCountsConsecutiveToolChildrenAsOne() async throws {
        var doc: [String] = []
        // Older filler that must NOT make it onto the first page.
        doc += (0..<5).map { Message2Fixtures.assistantTextJSONL("filler \($0)") }
        doc.append(Message2Fixtures.userTextJSONL("S_old"))
        // A 6-line tool run = 3 paired tool calls = one tool group = 1 entry.
        for t in 0..<3 {
            doc.append(Message2Fixtures.assistantReadJSONL(toolUseId: "t\(t)", filePath: "f\(t)"))
            doc.append(Message2Fixtures.userToolResultJSONL(toolUseId: "t\(t)"))
        }
        doc.append(Message2Fixtures.assistantTextJSONL("S_new"))

        let url = try tempFile(doc.joined(separator: "\n") + "\n")
        let source = JSONLReversePageSource(
            url: url, firstPageEntryTarget: 3, pageLineBudget: 80)

        let first = await source.nextPage()
        // S_new (1 entry) + 6 run lines (1 entry, not split) + S_old (1 entry) = 8 lines.
        XCTAssertEqual(
            first?.count, 8,
            "merge-aware count keeps the tool run whole; a naive 3-line cut would split it")
        // The run is fully present: 3 tool_use + 3 tool_result among the 8.
        let toolUses = first?.filter { $0.isGroupableAssistant }.count ?? 0
        let toolResults =
            first?.filter {
                if case .user(let u) = $0 { return u.toolResultBlock?.toolUseId != nil }
                return false
            }.count ?? 0
        XCTAssertEqual(toolUses, 3, "all 3 tool_use lines on the first page")
        XCTAssertEqual(toolResults, 3, "all 3 tool_result lines on the first page")
    }

    /// Document order is preserved: each page is returned oldest-first, and
    /// pages stack so the whole transcript reads top-to-bottom in order.
    func testPagesReturnDocumentOrder() async throws {
        let lines = (0..<5).map { Message2Fixtures.assistantTextJSONL("seg \($0)") }
        let url = try tempFile(lines.joined(separator: "\n") + "\n")
        let source = JSONLReversePageSource(
            url: url, firstPageEntryTarget: 2, pageLineBudget: 80)

        var collected: [Message2] = []
        // Reverse-page source yields newest page first; each older page
        // prepends above (mirrors the pipeline draining `.prepend`).
        while let page = await source.nextPage() { collected = page + collected }

        let texts = collected.compactMap { msg -> String? in
            guard case .assistant(let a) = msg, let blocks = a.message?.content
            else { return nil }
            for block in blocks {
                if case .text(let t) = block { return t.text }
            }
            return nil
        }
        XCTAssertEqual(texts, (0..<5).map { "seg \($0)" }, "oldest → newest preserved")
    }
}
