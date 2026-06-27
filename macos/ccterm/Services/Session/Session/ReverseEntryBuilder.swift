import AgentSDK
import Foundation

/// Pure, stateful **reverse-streaming** timeline builder.
///
/// Feed it `Message2` values in **reverse document order** (newest first);
/// receive grouped + tool-paired `MessageEntry` values back in **document
/// order** as runs finalize. This is the proper death of `buildEntries`'
/// throwaway in-memory `SessionRuntime`: the grouping +
/// tool-pairing rules that the live path runs in `SessionRuntime`'s
/// `appendToTimeline` (the method `receive` dispatches to, which actually walks
/// the group boundary by inspecting `messages.last`) are reproduced here as a
/// pure function — no CLI, no CoreData, no actor, no lifecycle side effects.
/// `TranscriptReverseBuilderTests.A6` pins the 1:1 parity with that live
/// grouping. Both engines share the same `isGroupableAssistant` predicate (the
/// single grouping rule); the forward (`appendToTimeline`) and reverse
/// (this builder) implementations stay intentionally separate because their
/// traversal directions differ, with A6 locking their equivalence.
///
/// ### Why reverse makes tool pairing free (§4.2)
///
/// In document order a `tool_use` is always *earlier* (higher) than its
/// `tool_result` — you cannot have a result before its call. Reading
/// **bottom-up** therefore always hits the `tool_result` first and reaches the
/// originating `tool_use` later (above). So an orphan `tool_result` is
/// **withheld** in ``withheld`` keyed by `tool_use_id` and attached to the
/// `SingleEntry` once that tool_use is reached. The withhold buffer survives
/// across `ingest` calls, so it spans page boundaries for free.
///
/// ### Grouping under reverse reading
///
/// A group is a maximal run of consecutive `isGroupableAssistant` messages
/// (interleaved tool_result / invisible messages do **not** break the run, just
/// as they don't in `appendToTimeline`, which only inspects `messages.last`).
/// The run accumulates in ``openGroupItems`` and is finalized — emitted as one
/// `.group` entry — only when an **older** non-groupable visible message closes
/// it (or `finish()` reaches the file top). A still-open run is never emitted
/// speculatively: emitting a partial group and growing it later would force a
/// `.replace` on the load path, which §4.2's "no `.update` on load" forbids.
struct ReverseEntryBuilder {

    /// Accumulating run of groupable assistant singles, held in **document
    /// order** (oldest first). Newly ingested (older) singles insert at index 0.
    private var openGroupItems: [SingleEntry] = []

    /// A tool_result seen before its originating `tool_use` was reached. Keeps
    /// the original `Message2` alongside the typed payload so a true orphan can
    /// be re-emitted as its own entry at `finish()`.
    private struct Withheld {
        let payload: ToolResultPayload
        let message: Message2
    }

    /// `tool_use_id` → result seen before its `tool_use` was reached.
    private var withheld: [String: Withheld] = [:]

    /// Insertion-ordered list of `tool_use_id`s still in ``withheld`` — used so
    /// the `finish()` true-orphan flush is deterministic.
    private var withheldOrder: [String] = []

    init() {}

    /// True while a group run or unmatched tool_result is still buffered. The
    /// pipeline may publish finalized entries regardless of this; it only
    /// matters for `finish()`.
    var hasBufferedContent: Bool { !openGroupItems.isEmpty || !withheld.isEmpty }

    /// Feed one message in **reverse document order**. Returns the entries that
    /// became **final** as a result — already in document order. The caller
    /// prepends this batch above whatever it has accumulated so far.
    mutating func ingest(_ message: Message2) -> [MessageEntry] {
        // tool_result → withhold for later pairing. Classified first, exactly
        // as `receive`'s `action(for:)` checks `toolResultBlock` before
        // visibility, so a malformed message carrying both a result and text
        // still routes to merge.
        if case .user(let u) = message,
            let result = u.toolResultBlock,
            let id = result.toolUseId
        {
            if withheld[id] == nil { withheldOrder.append(id) }
            withheld[id] = Withheld(
                payload: ToolResultPayload(item: result, typed: u.toolUseResult),
                message: message)
            return []
        }

        switch message {
        case .assistant(let a) where a.isVisible:
            if message.isGroupableAssistant {
                openGroupItems.insert(makeSingle(message), at: 0)
                return []
            }
            // Mixed text + tool_use assistant: non-groupable, closes the run.
            return closeRun(with: message)
        case .user(let u) where u.isVisible:
            return closeRun(with: message)
        default:
            // Invisible / skipped message: does NOT break a group run, matching
            // `receive`'s `.skip` action (never appended, so `messages.last`
            // stays the open group).
            return []
        }
    }

    /// File top reached. Flush the still-open group run and any true-orphan
    /// withheld results (`tool_use` absent from the whole file — truncation /
    /// compaction, §4.2). Returns in document order; the caller prepends at the
    /// very top. After this the builder is drained.
    mutating func finish() -> [MessageEntry] {
        var out: [MessageEntry] = []
        // True orphans sit above the oldest real content (their tool_use was
        // truncated off the top), so they lead.
        out.append(contentsOf: flushOrphans())
        if !openGroupItems.isEmpty {
            out.append(.group(GroupEntry(id: UUID(), items: openGroupItems)))
            openGroupItems = []
        }
        return out
    }

    // MARK: - Private

    /// Close the open group run (if any) and emit the closing non-groupable
    /// single. The closing message is **older** than the run, so document order
    /// is `[single, group]`.
    private mutating func closeRun(with message: Message2) -> [MessageEntry] {
        var out: [MessageEntry] = [.single(makeSingle(message))]
        if !openGroupItems.isEmpty {
            out.append(.group(GroupEntry(id: UUID(), items: openGroupItems)))
            openGroupItems = []
        }
        return out
    }

    /// Build a `SingleEntry` for a remote message, attaching any withheld
    /// tool_results for the tool_uses this message owns (removing them from the
    /// buffer so each result pairs exactly once).
    private mutating func makeSingle(_ message: Message2) -> SingleEntry {
        var toolResults: [String: ToolResultPayload] = [:]
        if case .assistant(let a) = message, let blocks = a.message?.content {
            for block in blocks {
                guard case .toolUse(let tu) = block, let id = tu.id else { continue }
                if let entry = withheld.removeValue(forKey: id) {
                    toolResults[id] = entry.payload
                    withheldOrder.removeAll { $0 == id }
                }
            }
        }
        return SingleEntry(
            id: UUID(), payload: .remote(message), delivery: nil, toolResults: toolResults)
    }

    /// Emit any unmatched tool_result as its own `.single` entry wrapping the
    /// original user message, best-effort and exactly once each, in document
    /// order. The standard user-message rendering path drops a lone
    /// tool_result block (no `userBubble`), so a true orphan currently surfaces
    /// no visible block — matching the prior silent-drop behavior — but it is
    /// explicitly accounted for rather than stranded in the buffer, and never
    /// misattached to an unrelated tool_use.
    private mutating func flushOrphans() -> [MessageEntry] {
        guard !withheld.isEmpty else { return [] }
        var out: [MessageEntry] = []
        for id in withheldOrder {
            guard let entry = withheld[id] else { continue }
            out.append(
                .single(
                    SingleEntry(
                        id: UUID(),
                        payload: .remote(entry.message),
                        delivery: nil,
                        toolResults: [:])))
        }
        withheld.removeAll()
        withheldOrder.removeAll()
        return out
    }
}
