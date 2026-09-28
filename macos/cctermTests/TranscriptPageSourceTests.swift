import AgentSDK
import XCTest

@testable import ccterm

/// `TranscriptPageSource`: newest-first paging over the resolved transcript,
/// with a merge-aware first page.
@MainActor
final class TranscriptPageSourceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func source(
        _ lines: [String], firstPageEntryTarget: Int, pageSize: Int = 80
    ) throws -> TranscriptPageSource {
        let file = try TempJSONLFile(lines)
        addTeardownBlock { file.remove() }
        return TranscriptPageSource(
            url: file.url, firstPageEntryTarget: firstPageEntryTarget, pageSize: pageSize)
    }

    /// All-standalone history: the first page is exactly `firstPageEntryTarget`
    /// messages (each text message is one entry); the rest spill to later pages.
    func testFirstPageStandaloneCountMatchesTarget() async throws {
        let source = try source(
            (0..<10).map { MessageFixtures.assistantTextJSONL("seg \($0)") }, firstPageEntryTarget: 3)

        let first = await source.nextPage()
        XCTAssertEqual(first?.count, 3, "first page = 3 standalone entries = 3 messages")
        let second = await source.nextPage()
        XCTAssertEqual(second?.count, 7, "remaining 7 land on the next page")
        let third = await source.nextPage()
        XCTAssertNil(third, "transcript start reached")
    }

    /// Later pages hold `pageSize` messages.
    func testLaterPagesHoldPageSize() async throws {
        let source = try source(
            (0..<10).map { MessageFixtures.assistantTextJSONL("seg \($0)") }, firstPageEntryTarget: 2,
            pageSize: 3)

        var sizes: [Int] = []
        while let page = await source.nextPage() { sizes.append(page.count) }
        XCTAssertEqual(sizes, [2, 3, 3, 2])
    }

    /// Merge-aware: a run of consecutive tool children (tool_use + tool_result)
    /// counts as ONE entry, so the first page pulls the WHOLE run rather than
    /// splitting it. Layout: [oldest filler…, S_old, 6-message tool run,
    /// S_new]. With target 3, reading backward stops after S_new (1) + run (2)
    /// + S_old (3) — all 8 messages, run intact.
    func testFirstPageCountsConsecutiveToolChildrenAsOne() async throws {
        var doc: [String] = []
        // Older filler that must NOT make it onto the first page.
        doc += (0..<5).map { MessageFixtures.assistantTextJSONL("filler \($0)") }
        doc.append(MessageFixtures.userTextJSONL("S_old"))
        // A 6-message tool run = 3 paired tool calls = one tool group = 1 entry.
        for t in 0..<3 {
            doc.append(MessageFixtures.assistantReadJSONL(toolUseId: "t\(t)", filePath: "f\(t)"))
            doc.append(MessageFixtures.userToolResultJSONL(toolUseId: "t\(t)"))
        }
        doc.append(MessageFixtures.assistantTextJSONL("S_new"))

        let first = await (try source(doc, firstPageEntryTarget: 3)).nextPage()
        XCTAssertEqual(
            first?.count, 8,
            "merge-aware count keeps the tool run whole; a naive 3-message cut would split it")
        let toolUses = first?.filter(\.isGroupableAssistant).count ?? 0
        let toolResults =
            first?.filter {
                if case .user(let u) = $0 { return u.toolResult != nil }
                return false
            }.count ?? 0
        XCTAssertEqual(toolUses, 3, "all 3 tool_use messages on the first page")
        XCTAssertEqual(toolResults, 3, "all 3 tool_result messages on the first page")
    }

    /// Each page is in document order, and pages stack so the whole
    /// transcript reads top-to-bottom in order.
    func testPagesReturnDocumentOrder() async throws {
        let source = try source(
            (0..<5).map { MessageFixtures.assistantTextJSONL("seg \($0)") }, firstPageEntryTarget: 2)

        var collected: [Message] = []
        // Newest page first; each older page prepends above (mirrors the
        // pipeline draining `.prepend`).
        while let page = await source.nextPage() { collected = page + collected }

        let texts = collected.compactMap { message -> String? in
            guard case .assistant(let a) = message else { return nil }
            return a.joinedText
        }
        XCTAssertEqual(texts, (0..<5).map { "seg \($0)" }, "oldest → newest preserved")
    }

    /// A missing file reads as an empty history, not an error.
    func testMissingFileIsEmpty() async {
        let source = TranscriptPageSource(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl"))
        let page = await source.nextPage()
        XCTAssertNil(page)
    }
}
