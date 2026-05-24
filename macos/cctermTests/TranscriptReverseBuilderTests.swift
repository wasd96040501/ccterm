import AgentSDK
import XCTest

@testable import ccterm

/// Tier-1 Group A (REFACTOR-PLAN §12.1): the pure reverse builder + tool
/// pairing. Fully synchronous — no async, no actor hop, no UI — so this is the
/// cheapest, most deterministic place to pin the grouping + tool-pairing rules.
@MainActor
final class TranscriptReverseBuilderTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Drivers

    /// Feed `messages` (document order) through the reverse builder exactly as
    /// the backfill pipeline does: reverse the stream, prepend each finalized
    /// batch, then prepend the `finish()` flush at the top. Returns document
    /// order.
    private func build(_ messages: [Message2]) -> [MessageEntry] {
        var builder = ReverseEntryBuilder()
        var acc: [MessageEntry] = []
        for m in messages.reversed() {
            acc = builder.ingest(m) + acc
        }
        acc = builder.finish() + acc
        return acc
    }

    /// Forward reference: run the same messages through a throwaway
    /// `SessionRuntime.receive(_:mode:.replay)` — the exact path `buildEntries`
    /// used — and read the resulting timeline. Used by A6 to prove 1:1 parity.
    private func forwardReference(_ messages: [Message2]) -> [MessageEntry] {
        let runtime = SessionRuntime(sessionId: UUID().uuidString, repository: InMemorySessionRepository())
        for m in messages { runtime.receive(m, mode: .replay) }
        return runtime.messages
    }

    /// Structural fingerprint that ignores the builder's random entry UUIDs —
    /// compares grouping, message class, tool_use ids, and attached
    /// tool_result keys.
    private func summarize(_ entries: [MessageEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .single(let s):
                return "single(\(singleFingerprint(s)))"
            case .group(let g):
                return "group[" + g.items.map(singleFingerprint).joined(separator: ",") + "]"
            }
        }
    }

    private func singleFingerprint(_ s: SingleEntry) -> String {
        let kind: String
        switch s.payload {
        case .localUser: kind = "localUser"
        case .remote(let m):
            switch m {
            case .user: kind = "user"
            case .assistant: kind = "assistant"
            default: kind = "other"
            }
        }
        let tools = s.toolUses.compactMap(\.id).sorted().joined(separator: ",")
        let results = s.toolResults.keys.sorted().joined(separator: ",")
        return "\(kind) tools=[\(tools)] results=[\(results)]"
    }

    private func isOrphanResult(_ entry: MessageEntry) -> Bool {
        guard case .single(let s) = entry,
            case .remote(.user(let u)) = s.payload
        else { return false }
        return u.toolResultBlock != nil
    }

    // MARK: - A1: clean bottom-up read, interleaved text

    func testA1_cleanFileEmitsDocumentOrder() throws {
        let t1 = "tool-1"
        let messages: [Message2] = [
            Message2Fixtures.userText("hi", uuid: UUID().uuidString),
            Message2Fixtures.assistantRead(toolUseId: t1, filePath: "/a.swift"),
            Message2Fixtures.userToolResult(toolUseId: t1, text: "contents"),
            Message2Fixtures.assistantText("done"),
        ]

        let entries = build(messages)

        XCTAssertEqual(
            summarize(entries),
            [
                "single(user tools=[] results=[])",
                "group[assistant tools=[\(t1)] results=[\(t1)]]",
                "single(assistant tools=[] results=[])",
            ],
            "reverse build must reconstruct exact document order with the pair resolved")
    }

    // MARK: - A2: tool_result read before tool_use is withheld then paired

    func testA2_orphanResultWithheldThenPairedAtToolUse() throws {
        let t1 = "tool-2"
        // Reverse feed hits the result first; pairing must complete when the
        // tool_use is reached above it.
        let messages: [Message2] = [
            Message2Fixtures.assistantRead(toolUseId: t1, filePath: "/b.swift"),
            Message2Fixtures.userToolResult(toolUseId: t1, text: "body"),
        ]

        let entries = build(messages)

        XCTAssertEqual(entries.count, 1, "the lone read folds into one group entry")
        guard case .group(let g) = entries[0], let item = g.items.first else {
            return XCTFail("expected a group with one item, got \(summarize(entries))")
        }
        XCTAssertEqual(item.toolResults.keys.sorted(), [t1], "result must be attached to its tool_use")
        XCTAssertFalse(entries.contains(where: isOrphanResult), "no orphan should survive — it paired")
    }

    // MARK: - A3: true orphan (tool_use absent from the whole file)

    func testA3_trueOrphanFlushedBestEffortExactlyOnce() throws {
        let missing = "tool-missing"
        let messages: [Message2] = [
            Message2Fixtures.userText("hi"),
            Message2Fixtures.userToolResult(toolUseId: missing, text: "stranded"),
            Message2Fixtures.assistantText("done"),
        ]

        let entries = build(messages)

        let orphans = entries.filter(isOrphanResult)
        XCTAssertEqual(orphans.count, 1, "the orphan result is surfaced exactly once at file top")
        // It is never misattached to an unrelated entry.
        for entry in entries {
            if case .single(let s) = entry {
                XCTAssertFalse(
                    s.toolResults.keys.contains(missing),
                    "orphan must not attach to an unrelated single")
            }
            if case .group(let g) = entry {
                for item in g.items {
                    XCTAssertFalse(
                        item.toolResults.keys.contains(missing),
                        "orphan must not attach to an unrelated group item")
                }
            }
        }
    }

    // MARK: - A4: pair split across a page boundary (withhold buffer spans gaps)

    func testA4_pairResolvesAcrossInterveningMessages() throws {
        let t1 = "tool-4"
        // Several non-groupable messages sit between the tool_use and its
        // result, mimicking a page split. The withhold buffer must carry the
        // result across them.
        let messages: [Message2] = [
            Message2Fixtures.assistantRead(toolUseId: t1, filePath: "/c.swift"),
            Message2Fixtures.assistantText("thinking out loud"),
            Message2Fixtures.userText("a follow up"),
            Message2Fixtures.userToolResult(toolUseId: t1, text: "late result"),
        ]

        let entries = build(messages)

        // The read group sits at the top; its result is resolved despite the
        // intervening messages read first in reverse.
        guard case .group(let g) = entries.first, let item = g.items.first else {
            return XCTFail("expected the read group first, got \(summarize(entries))")
        }
        XCTAssertEqual(item.toolResults.keys.sorted(), [t1], "pairing spans intervening messages")
    }

    // MARK: - A5: load blocks are born complete (no post-emission mutation)

    func testA5_everyEmittedToolUseIsBornWithItsResult() throws {
        let t1 = "tool-5a"
        let t2 = "tool-5b"
        let messages: [Message2] = [
            Message2Fixtures.userText("go"),
            Message2Fixtures.assistantRead(toolUseId: t1, filePath: "/x.swift"),
            Message2Fixtures.userToolResult(toolUseId: t1),
            Message2Fixtures.assistantRead(toolUseId: t2, filePath: "/y.swift"),
            Message2Fixtures.userToolResult(toolUseId: t2),
            Message2Fixtures.assistantText("summary"),
        ]

        let entries = build(messages)

        // Two adjacent reads with results between them group into ONE group of
        // two items, each carrying its result already — nothing left to update.
        for entry in entries {
            guard case .group(let g) = entry else { continue }
            for item in g.items where !item.toolUses.isEmpty {
                XCTAssertFalse(
                    item.toolResults.isEmpty,
                    "every grouped tool_use must be emitted already paired (born complete)")
            }
        }
    }

    // MARK: - A6: 1:1 parity with the live receive grouping

    func testA6_matchesForwardReceiveGrouping() throws {
        let t1 = "tool-6a"
        let t2 = "tool-6b"
        let t3 = "tool-6c"
        let messages: [Message2] = [
            Message2Fixtures.userText("first"),
            Message2Fixtures.assistantText("intro text"),
            // a run of three groupable tool_uses with interleaved results
            Message2Fixtures.assistantRead(toolUseId: t1, filePath: "/1.swift"),
            Message2Fixtures.userToolResult(toolUseId: t1),
            Message2Fixtures.assistantRead(toolUseId: t2, filePath: "/2.swift"),
            Message2Fixtures.userToolResult(toolUseId: t2),
            Message2Fixtures.assistantRead(toolUseId: t3, filePath: "/3.swift"),
            Message2Fixtures.userToolResult(toolUseId: t3),
            // closing assistant text breaks the group
            Message2Fixtures.assistantText("wrap up"),
            Message2Fixtures.userText("second"),
        ]

        XCTAssertEqual(
            summarize(build(messages)),
            summarize(forwardReference(messages)),
            "reverse builder must reproduce the forward receive grouping 1:1")
    }
}
