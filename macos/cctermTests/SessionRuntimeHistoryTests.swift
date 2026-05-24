import AgentSDK
import XCTest

@testable import ccterm

/// Covers the reverse-streaming history load now driven by
/// `Session.loadHistory()` → `TranscriptBackfillPipeline` →
/// `JSONLReversePageSource`. The old two-phase
/// `.reset`/`.prepended` mechanism, its precomputed-blocks payload, and the
/// `ToolResultReresolver` backfill are gone — the grouping/pairing correctness
/// they used to guard now lives in `TranscriptReverseBuilderTests` (Group A),
/// and the deposit/drain timing in `TranscriptBackfillPipelineTests` (Group B).
/// These tests are the end-to-end integration: bytes on disk → blocks in the
/// controller.
@MainActor
final class SessionRuntimeHistoryTests: XCTestCase {

    private var tempFile: TempJSONLFile?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        tempFile?.remove()
        tempFile = nil
    }

    /// Build an `.active` Session over an in-memory repo so `loadHistory`'s
    /// controller + bridge + historyLoadState are all wired.
    private func makeSession() -> ccterm.Session {
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository())
        return ccterm.Session(runtime: runtime, cliClientFactory: { _ in FakeCLIClient() })
    }

    /// Drive `loadHistory(overrideURL:)` to completion, awaiting
    /// `historyLoadState == .loaded`.
    private func loadToCompletion(
        _ session: ccterm.Session, url: URL, firstPageEntryTarget: Int = 20
    ) async {
        session.loadHistory(overrideURL: url, firstPageEntryTarget: firstPageEntryTarget)
        let predicate = NSPredicate { _, _ in
            session.historyLoadState == .loaded
        }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        await fulfillment(of: [exp], timeout: 5)
    }

    /// Cold load of a small JSONL lands every entry's blocks in the controller.
    func testLoadHistoryRendersAllBlocks() async {
        let file = try! TempJSONLFile([
            Message2Fixtures.assistantTextJSONL("Hello"),
            Message2Fixtures.userTextJSONL("Hi back"),
        ])
        tempFile = file

        let session = makeSession()
        await loadToCompletion(session, url: file.url)

        // assistant text → 1 paragraph block; user text → 1 bubble block.
        XCTAssertEqual(session.controller.blockCount, 2)
        XCTAssertEqual(session.historyLoadState, .loaded)
    }

    /// Empty file loads to `.loaded` with no content and no crash.
    func testLoadHistoryEmptyFile() async {
        let file = try! TempJSONLFile([])
        tempFile = file

        let session = makeSession()
        await loadToCompletion(session, url: file.url)

        XCTAssertEqual(session.controller.blockCount, 0)
        XCTAssertEqual(session.historyLoadState, .loaded)
    }

    /// A JSONL larger than the first page exercises multi-page backfill:
    /// every line still lands, in document order.
    func testLoadHistoryMultiPageRendersInDocumentOrder() async {
        let lines = (0..<6).map { Message2Fixtures.assistantTextJSONL("Segment \($0)") }
        let file = try! TempJSONLFile(lines)
        tempFile = file

        let session = makeSession()
        await loadToCompletion(session, url: file.url, firstPageEntryTarget: 2)

        XCTAssertEqual(session.controller.blockCount, 6, "first page + later pages all land")
        // Document order: first paragraph reads "Segment 0".
        let firstId = session.controller.coordinator.blockIds.first
        let firstBlock = firstId.flatMap { session.controller.coordinator.block(forId: $0) }
        if case .paragraph(let inlines) = firstBlock?.kind,
            case .text(let s) = inlines.first
        {
            XCTAssertEqual(s, "Segment 0", "oldest entry sits at the top after backfill")
        } else {
            XCTFail("expected a paragraph block at the top, got \(String(describing: firstBlock?.kind))")
        }
    }

    /// Re-entry is idempotent: a second `loadHistory` on a `.loaded` session is
    /// a no-op (no duplicate content).
    func testLoadHistoryIdempotentOnReentry() async {
        let file = try! TempJSONLFile([Message2Fixtures.assistantTextJSONL("Once")])
        tempFile = file

        let session = makeSession()
        await loadToCompletion(session, url: file.url)
        let countAfterFirst = session.controller.blockCount

        session.loadHistory(overrideURL: file.url)
        // No state change to await — assert it stayed put.
        XCTAssertEqual(session.controller.blockCount, countAfterFirst)
        XCTAssertEqual(session.historyLoadState, .loaded)
    }
}
