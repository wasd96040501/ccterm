import AgentSDK
import XCTest

@testable import ccterm

/// Covers `SessionHandle2.loadHistory`'s two-phase flow with the
/// precomputed-blocks payload added in this PR. Each test:
///
/// - Writes a unique tmp JSONL file (no shared FS paths under parallel
///   execution; see `cctermTests/CLAUDE.md`).
/// - Constructs a fresh `SessionHandle2` against an in-memory repository.
/// - Attaches a `MessagesChangeRecorder` and drives `loadHistory(overrideURL:)`.
@MainActor
final class SessionHandle2HistoryTests: XCTestCase {

    private var tempFile: TempJSONLFile?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        tempFile?.remove()
        tempFile = nil
    }

    // MARK: - Phase A

    /// Cold load of a small JSONL: `.reset` fires with precomputed blocks
    /// that cover every entry the handle just ingested. Verifies the
    /// off-main precompute → main-hop dispatch wiring.
    func testLoadHistoryFiresResetWithPrecomputedBlocks() async {
        let file = try! TempJSONLFile([
            Message2Fixtures.assistantTextJSONL("Hello"),
            Message2Fixtures.userTextJSONL("Hi back"),
        ])
        tempFile = file

        let handle = SessionHandle2(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository())
        let recorder = MessagesChangeRecorder()
        recorder.attach(to: handle)

        handle.loadHistory(overrideURL: file.url, tailTarget: 80)

        let arrived = await recorder.wait { events in
            events.contains(where: { $0.asReset != nil })
        }
        XCTAssertTrue(arrived, "reset event did not arrive within timeout")

        guard let reset = recorder.events.compactMap(\.asReset).first else {
            return XCTFail("expected at least one .reset event")
        }
        XCTAssertEqual(
            reset.entries.count, 2,
            "both JSONL lines should appear as entries")
        XCTAssertNotNil(
            reset.precomputed,
            "Phase A must ship a precomputed-blocks payload")
        // Every entry has a non-empty block list in the map.
        for entry in reset.entries {
            let blocks = reset.precomputed?[entry.id]
            XCTAssertNotNil(
                blocks,
                "precomputed map missing entry \(entry.id)")
            XCTAssertFalse(
                blocks?.isEmpty ?? true,
                "precomputed blocks for entry \(entry.id) should be non-empty")
        }
    }

    /// Edge: empty file. `.reset([], precomputed: [:])` still fires so the
    /// bridge can flip `didLoadInitial = true` and subsequent live appends
    /// take the incremental path.
    func testLoadHistoryEmptyFileFiresEmptyReset() async {
        let file = try! TempJSONLFile([])
        tempFile = file

        let handle = SessionHandle2(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository())
        let recorder = MessagesChangeRecorder()
        recorder.attach(to: handle)

        handle.loadHistory(overrideURL: file.url, tailTarget: 80)

        let arrived = await recorder.wait { events in
            events.contains(where: { $0.asReset != nil })
        }
        XCTAssertTrue(arrived, "reset event did not arrive within timeout")

        guard let reset = recorder.events.compactMap(\.asReset).first else {
            return XCTFail("expected one .reset event")
        }
        XCTAssertTrue(reset.entries.isEmpty)
        XCTAssertEqual(reset.precomputed?.isEmpty, true)
    }

    // MARK: - Phase B

    /// JSONL larger than `tailTarget`: Phase A picks up the tail, Phase B
    /// streams the prefix in afterwards. The `.prepended` event must
    /// carry precomputed blocks for every prefix entry — proving the
    /// off-main precompute kicked in for the larger-load path too.
    func testLoadHistoryPhaseBFiresPrependedWithPrecomputedBlocks() async {
        // 6 JSONL lines, tailTarget=2 → Phase B picks up ~4 prefix lines.
        let lines = (0..<6).map { i in
            Message2Fixtures.assistantTextJSONL("Segment \(i)")
        }
        let file = try! TempJSONLFile(lines)
        tempFile = file

        let handle = SessionHandle2(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository())
        let recorder = MessagesChangeRecorder()
        recorder.attach(to: handle)

        handle.loadHistory(overrideURL: file.url, tailTarget: 2)

        let arrived = await recorder.wait { events in
            events.contains(where: { $0.asPrepended != nil })
        }
        XCTAssertTrue(arrived, "prepended event did not arrive within timeout")

        guard let prepended = recorder.events.compactMap(\.asPrepended).first
        else {
            return XCTFail("expected at least one .prepended event")
        }
        XCTAssertFalse(
            prepended.entries.isEmpty,
            "Phase B prefix should not be empty for a multi-line file")
        XCTAssertNotNil(
            prepended.precomputed,
            "Phase B must ship a precomputed-blocks payload")
        for entry in prepended.entries {
            let blocks = prepended.precomputed?[entry.id]
            XCTAssertNotNil(
                blocks,
                "precomputed map missing prefix entry \(entry.id)")
        }
    }

    /// Edge: precomputed payload must match what `MessageEntryBlockBuilder`
    /// would produce on the synchronous fallback path. If they diverge, the
    /// bridge's reverse map would point at the wrong block ids.
    func testPrecomputedBlocksMatchSynchronousBuild() async {
        let file = try! TempJSONLFile([
            Message2Fixtures.assistantTextJSONL("# Heading\n\nA paragraph.")
        ])
        tempFile = file

        let handle = SessionHandle2(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository())
        let recorder = MessagesChangeRecorder()
        recorder.attach(to: handle)

        handle.loadHistory(overrideURL: file.url, tailTarget: 80)

        _ = await recorder.wait { events in
            events.contains(where: { $0.asReset != nil })
        }
        guard let reset = recorder.events.compactMap(\.asReset).first,
            let entry = reset.entries.first
        else {
            return XCTFail("expected an entry on reset")
        }
        let precomputed = reset.precomputed?[entry.id] ?? []
        let synchronous = MessageEntryBlockBuilder.entryBlocks(entry)
        XCTAssertEqual(
            precomputed.map(\.id), synchronous.map(\.id),
            "off-main precompute must yield the same block ids as the sync builder")
    }
}
