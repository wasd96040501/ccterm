import AgentSDK
import AppKit
import Foundation

/// Translates entry-level instructions from `Session.onMessagesChange`
/// into block-level commands for `Transcript2Controller`. **Purely imperative**
/// — does not maintain a full `[Block]` mirror to diff against; just two
/// reverse tables:
///
/// - `entryOrder: [UUID]`: timeline order of entries.
/// - `entryBlockIds: [UUID: [UUID]]`: entry.id → ordered list of Block.ids
///   produced by that entry.
///
/// On entry update: run the builder to compute new blocks, then compare to old
/// ids:
/// - identical id sequences (typical: tool_result merge / confirm / group items
///   grew) → per-block `.update(id, kind)`, preserving row-level animation /
///   selection / fold.
/// - mismatched (rare: assistant entry structure changed) → `.remove(old)` +
///   `.insert(new)`, anchored to the previous entry's last block id.
///
/// **Invariant**: after every dispatch, `entryOrder` / `entryBlockIds` match
/// `handle.messages`'s entry order. Reset rebuilds wholesale; append / prepend
/// / remove each maintain consistency locally.
@MainActor
final class Transcript2EntryBridge {
    let controller: Transcript2Controller

    // Module-internal so `cctermTests` (compiled with `@testable import`)
    // can verify the reverse map after `.reset` / `.prepended` without
    // having to mount an `NSTableView` (the bridge's contract is that
    // these tables match the entry order it received, regardless of
    // whether the controller's table is real).
    private(set) var entryOrder: [UUID] = []
    private(set) var entryBlockIds: [UUID: [UUID]] = [:]
    /// Tracks whether `setHistory` has fired. Any append / update arriving
    /// before it is the abnormal path (handle hasn't reset yet) — fall back
    /// by treating the entry as a reset seed so content isn't lost.
    private var didLoadInitial = false

    /// Entry id of the **first user-typed message that arrives live**
    /// (via `.appended`) during this bridge's lifetime. UI-suppresses the
    /// queued visual on that one bubble — the two scenarios this covers
    /// are new-session start and session resume, both of which boot the
    /// CLI from cold; the first send is always queued for a few seconds
    /// while bootstrap runs and a "you just hit send" indicator there
    /// reads as noise.
    ///
    /// History-load events (`.reset` / `.prepended`) intentionally do
    /// **not** pin this — replayed messages already have
    /// `delivery == .confirmed` so the suppression would be a no-op
    /// anyway, but more importantly we want the *next live send after
    /// a resume* to receive the pin, not some long-confirmed historical
    /// turn.
    ///
    /// Same-session, already-bootstrapped sends (`.appended` after the
    /// pin is taken) keep their truthful queued visual — that's the
    /// "CLI is busy on the prior turn, you're really in queue" case
    /// the indicator is useful for.
    ///
    /// The underlying `SingleEntry.delivery` stays truthful; only the
    /// `Block.userBubble(isQueued:)` flag is rewritten when we emit
    /// blocks for this entry.
    private var firstUserEntryId: UUID?

    init(controller: Transcript2Controller) {
        self.controller = controller
    }

    /// macOS 26 SDK workaround: a default `@MainActor` deinit routes
    /// through `swift_task_deinitOnExecutorImpl`, which hits a libmalloc
    /// abort while tearing down `TaskLocal`. `nonisolated deinit` skips
    /// that executor hop. See `Session.deinit` for the original
    /// note — same fix, applied to every `@MainActor` class in this
    /// dealloc chain.
    nonisolated deinit {}

    // MARK: - Dispatch

    func apply(_ change: MessagesChange) {
        switch change {
        case .reset(let entries, let precomputed):
            applyReset(entries, precomputed: precomputed)
            for entry in entries { pushStatuses(for: entry, mode: .historical) }
        case .appended(let entry):
            applyAppend(entry)
            pushStatuses(for: entry, mode: .live)
        case .prepended(let entries, let precomputed):
            applyPrepend(entries, precomputed: precomputed)
            for entry in entries { pushStatuses(for: entry, mode: .historical) }
        case .updated(let entry):
            applyUpdate(entry)
            pushStatuses(for: entry, mode: .live)
        case .removed(let entry):
            // Block is gone — nothing to push. `Coordinator.applyStructuralChange`
            // already evicted the entry's `statusStates` slots.
            applyRemove(entry)
        }
    }

    /// Runtime saw `.result` — turn ended. Clear any tool surface still
    /// stuck in `.running`. Called from `Session.wireRuntimeMessagesSink`
    /// after the runtime fires its turn-finished sink.
    func handleTurnFinished() {
        controller.clearAllRunningStatuses()
    }

    /// Pull the blocks for an entry from the precomputed map (off-main
    /// build) when available, otherwise fall back to the inline
    /// `MessageEntryBlockBuilder.entryBlocks` (on-main Markdown parse).
    /// The fallback keeps every code path well-defined when a caller
    /// doesn't ship a precomputed payload — incremental writes
    /// (`.appended` / `.updated`) intentionally don't.
    ///
    /// Post-processes the result through `applyFirstUserSuppression` so a
    /// single, central place owns the queued-visual override for the
    /// session's first user message.
    private func blocks(for entry: MessageEntry, precomputed: [UUID: [Block]]?) -> [Block] {
        let raw: [Block]
        if let cached = precomputed?[entry.id] {
            raw = cached
        } else {
            raw = MessageEntryBlockBuilder.entryBlocks(entry)
        }
        return applyFirstUserSuppression(raw, for: entry.id)
    }

    /// If `entryId` matches `firstUserEntryId`, rewrite every
    /// `.userBubble(text:isQueued: true)` block in `blocks` to
    /// `.userBubble(text:isQueued: false)`. Other block kinds and other
    /// entries pass through untouched. No-op when the entry isn't the
    /// first user message or none of its blocks are queued bubbles.
    private func applyFirstUserSuppression(_ blocks: [Block], for entryId: UUID) -> [Block] {
        guard entryId == firstUserEntryId else { return blocks }
        return blocks.map { block in
            if case .userBubble(let text, true) = block.kind {
                return Block(id: block.id, kind: .userBubble(text: text, isQueued: false))
            }
            return block
        }
    }

    // MARK: - First-user tracking

    /// True when an entry represents a user-typed turn — either a local
    /// `.localUser` input or a CLI-echoed `.remote(.user(_))` envelope.
    /// Tool-result `.remote(.user(_))` envelopes (which carry a
    /// `tool_use_id`) are intentionally still considered "user-typed"
    /// here because the bridge collapses them into the matching assistant
    /// entry — they never produce a userBubble block on their own, so
    /// they're effectively invisible for the suppression purpose.
    private static func isUserTyped(_ entry: MessageEntry) -> Bool {
        guard case .single(let s) = entry else { return false }
        switch s.payload {
        case .localUser: return true
        case .remote(let m):
            if case .user = m { return true }
            return false
        }
    }

    // MARK: - Status push
    //
    // Pure command-style status routing: walk the entry's tool surfaces,
    // resolve each one's `ToolStatus`, and forward to
    // `Transcript2Controller.setToolStatus`. `setToolStatus` is
    // idempotent and caches statuses for ids the coordinator hasn't seen
    // yet, so call order vs. the structural change above doesn't matter.
    //
    // **No mirror state.** We don't diff against a previous status map;
    // we re-derive the current status from the entry every time the
    // entry changes.
    //
    // Mode-sensitive status derivation:
    //
    // | mode         | nil result          | isError == true       | result OK    |
    // |--------------|---------------------|-----------------------|--------------|
    // | `.live`      | `.running`          | `.failed(message:)`   | `.completed` |
    // | `.historical`| `.completed`        | `.failed(message:)`   | `.completed` |
    //
    // `.historical` is used for `.reset` and `.prepended` (JSONL replay
    // paths). An incomplete tool_use in history is an abandoned run from
    // a long-finished session — the spinner affordance only makes sense
    // for live in-flight calls. `.failed` survives the mode flip because
    // the past failure is still meaningful color.
    //
    // Group status follows the "running == any child running" rule:
    //
    // - single-tool host (`entry|<id>|tg|<idx>`) — one child, so group
    //   status == child status.
    // - `.group` host (`group|<id>`) — `.running` if any nested child is
    //   `.running`, otherwise `.completed`. In `.historical` mode no
    //   child is ever `.running`, so the group always settles
    //   `.completed`.

    /// Status-derivation mode. `.live` treats missing `tool_result` as
    /// `.running`; `.historical` treats it as `.completed`.
    enum StatusMode {
        case live
        case historical
    }

    private func pushStatuses(for entry: MessageEntry, mode: StatusMode) {
        switch entry {
        case .single(let single):
            pushSingleEntryStatuses(single, mode: mode)
        case .group(let group):
            pushGroupEntryStatuses(group, mode: mode)
        }
    }

    private func pushSingleEntryStatuses(_ single: SingleEntry, mode: StatusMode) {
        guard case .remote(let m) = single.payload,
            case .assistant(let a) = m,
            let blocks = a.message?.content
        else { return }
        for (idx, block) in blocks.enumerated() {
            guard case .toolUse(let tu) = block else { continue }
            let toolUseId = tu.id ?? "tu|\(single.id.uuidString)|\(idx)"
            let childId = StableBlockID.derive("tool", toolUseId)
            let result = tu.id.flatMap { single.toolResults[$0] }
            let status = Self.status(for: result, mode: mode)
            controller.setToolStatus(id: childId, status: status)
            // Single-tool host group: group has exactly one child, so
            // group status mirrors that child's status.
            let groupBlockId = StableBlockID.derive(
                "entry", single.id.uuidString, "tg", String(idx))
            controller.setToolStatus(id: groupBlockId, status: status)
        }
    }

    private func pushGroupEntryStatuses(_ group: GroupEntry, mode: StatusMode) {
        var anyRunning = false
        for (itemIdx, item) in group.items.enumerated() {
            guard case .remote(let m) = item.payload,
                case .assistant(let a) = m,
                let blocks = a.message?.content
            else { continue }
            for (blockIdx, block) in blocks.enumerated() {
                guard case .toolUse(let tu) = block else { continue }
                let toolUseId =
                    tu.id
                    ?? "tu|\(group.id.uuidString)|\(itemIdx)|\(blockIdx)"
                let childId = StableBlockID.derive("tool", toolUseId)
                let result = tu.id.flatMap { item.toolResults[$0] }
                let status = Self.status(for: result, mode: mode)
                if case .running = status { anyRunning = true }
                controller.setToolStatus(id: childId, status: status)
            }
        }
        let groupId = StableBlockID.derive("group", group.id.uuidString)
        controller.setToolStatus(
            id: groupId, status: anyRunning ? .running : .completed)
    }

    private static func status(
        for result: ToolResultPayload?, mode: StatusMode
    )
        -> ToolStatus
    {
        guard let result else {
            switch mode {
            case .live: return .running
            case .historical: return .completed
            }
        }
        if result.isError == true { return .failed(message: nil) }
        return .completed
    }

    // MARK: - Reset (setHistory / re-entry)

    private func applyReset(_ entries: [MessageEntry], precomputed: [UUID: [Block]]?) {
        // History reset does NOT pin `firstUserEntryId`. We want the
        // pin to land on the next *live* `.appended` (the first send
        // into the freshly-booted CLI), not on some long-confirmed
        // historical turn. See the field docs for why.

        // Rebuild reverse tables and collect blocks.
        var newOrder: [UUID] = []
        newOrder.reserveCapacity(entries.count)
        var newMap: [UUID: [UUID]] = [:]
        newMap.reserveCapacity(entries.count)
        var allBlocks: [Block] = []
        for entry in entries {
            let blocks = self.blocks(for: entry, precomputed: precomputed)
            newOrder.append(entry.id)
            newMap[entry.id] = blocks.map(\.id)
            allBlocks.append(contentsOf: blocks)
        }

        // Second reset (user navigated away then back / Phase A re-fires) goes
        // through the controller's incremental API rather than another
        // `setHistory`: the Coordinator has already viewport-rendered, and a
        // blunt blocks-array swap would lose animation. Use remove-all +
        // insert in one batch — visually a reload, but on the apply channel.
        if didLoadInitial {
            var changes: [Transcript2Controller.Change] = []
            let oldAllIds = entryOrder.flatMap { entryBlockIds[$0] ?? [] }
            if !oldAllIds.isEmpty {
                changes.append(.remove(ids: oldAllIds))
            }
            if !allBlocks.isEmpty {
                changes.append(.insert(after: nil, allBlocks))
            }
            entryOrder = newOrder
            entryBlockIds = newMap
            controller.coordinator.apply(changes, scroll: .none)
            return
        }

        // First reset: take setHistory's two-phase fast first-screen path.
        entryOrder = newOrder
        entryBlockIds = newMap
        didLoadInitial = true
        guard !allBlocks.isEmpty else { return }
        controller.setHistory(allBlocks, anchor: .bottom)
    }

    // MARK: - Append (live message)

    private func applyAppend(_ entry: MessageEntry) {
        // First user-typed entry to arrive after init wins the pin. Set
        // **before** calling `self.blocks(for:)` so the suppression sees
        // it on this same build.
        if firstUserEntryId == nil, Self.isUserTyped(entry) {
            firstUserEntryId = entry.id
        }
        let blocks = self.blocks(for: entry, precomputed: nil)
        if blocks.isEmpty {
            // Entry produced no block (empty user message / all-thinking
            // assistant) — still take an entryOrder slot so a future mutate
            // can resolve the previous-entry anchor correctly.
            entryOrder.append(entry.id)
            entryBlockIds[entry.id] = []
            return
        }
        let anchor = previousEntryLastBlockId(beforeAppending: entry.id)
        entryOrder.append(entry.id)
        entryBlockIds[entry.id] = blocks.map(\.id)

        if !didLoadInitial {
            // Sink fired before reset: use the first message as cold-load seed.
            didLoadInitial = true
            controller.setHistory(blocks, anchor: .bottom)
            return
        }
        controller.coordinator.apply(
            [.insert(after: anchor, blocks)], scroll: .none)
    }

    /// Last block id of the entry preceding the insertion point. Returns nil
    /// (= insert at index 0) when there is no predecessor (first entry / prior
    /// entry produced no blocks).
    private func previousEntryLastBlockId(beforeAppending entryId: UUID) -> UUID? {
        // Callers guarantee entryId is not yet in entryOrder, so entryOrder.last
        // is the anchor source.
        guard let prev = entryOrder.last else { return nil }
        return entryBlockIds[prev]?.last
    }

    // MARK: - Prepend (loadHistory Phase B)

    private func applyPrepend(_ entries: [MessageEntry], precomputed: [UUID: [Block]]?) {
        // Same reasoning as `applyReset`: older history doesn't take the
        // pin. The live `.appended` path is the sole pin source.

        var prefixBlocks: [Block] = []
        var newOrder: [UUID] = []
        var newMap: [UUID: [UUID]] = [:]
        for entry in entries {
            let blocks = self.blocks(for: entry, precomputed: precomputed)
            newOrder.append(entry.id)
            newMap[entry.id] = blocks.map(\.id)
            prefixBlocks.append(contentsOf: blocks)
        }

        entryOrder = newOrder + entryOrder
        for (k, v) in newMap { entryBlockIds[k] = v }

        guard !prefixBlocks.isEmpty else { return }
        // Prepend → `.saveVisible(.visualTop)` keeps the user's currently
        // visible first line at the same visual position. Route through
        // `applyInBackground` so the per-row layout precompute (paragraph
        // wrap, code-block typeset, tool-group geometry) runs on a
        // detached `userInitiated` task and not on the main thread —
        // mirroring what `setHistory`'s Phase 2 already does for the
        // first-screen path. The bridge stays synchronous from the
        // handle's perspective: the structural change still lands in a
        // single main hop.
        controller.coordinator.applyInBackground(
            [.insert(after: nil, prefixBlocks)],
            scroll: .saveVisible(.visualTop))
    }

    // MARK: - Update (tool_result merge / confirm / group grew)

    private func applyUpdate(_ entry: MessageEntry) {
        let oldIds = entryBlockIds[entry.id] ?? []
        let newBlocks = self.blocks(for: entry, precomputed: nil)
        let newIds = newBlocks.map(\.id)

        // Identical id sequence: the typical 95% case — per-block update.
        if oldIds == newIds {
            // All-empty (entry produces no block) → nothing to do.
            guard !newIds.isEmpty else { return }
            let changes: [Transcript2Controller.Change] = newBlocks.map {
                .update(id: $0.id, kind: $0.kind)
            }
            controller.coordinator.apply(changes, scroll: .none)
            return
        }

        // Structure changed: remove old + insert new, anchored to the previous
        // entry. Atomic replacement of the whole segment. A finer-grained diff
        // is possible but not worth the cost — this path almost never fires.
        let anchor = previousEntryLastBlockId(beforeRebuilding: entry.id)
        var changes: [Transcript2Controller.Change] = []
        if !oldIds.isEmpty { changes.append(.remove(ids: oldIds)) }
        if !newBlocks.isEmpty { changes.append(.insert(after: anchor, newBlocks)) }
        entryBlockIds[entry.id] = newIds
        if entryOrder.firstIndex(of: entry.id) == nil {
            // Entry was never registered before this update (out-of-order
            // sink). Defensively append so the block doesn't hang loose.
            entryOrder.append(entry.id)
        }
        guard !changes.isEmpty else { return }
        controller.coordinator.apply(changes, scroll: .none)
    }

    /// Update path: entry is still in entryOrder; return the predecessor's
    /// last block id.
    private func previousEntryLastBlockId(beforeRebuilding entryId: UUID) -> UUID? {
        guard let idx = entryOrder.firstIndex(of: entryId), idx > 0 else { return nil }
        return entryBlockIds[entryOrder[idx - 1]]?.last
    }

    // MARK: - Remove (cancelMessage)

    private func applyRemove(_ entry: MessageEntry) {
        let ids = entryBlockIds[entry.id] ?? []
        entryBlockIds.removeValue(forKey: entry.id)
        entryOrder.removeAll { $0 == entry.id }
        // Releasing the pin when the first user message is removed lets
        // the *next* still-queued user bubble keep its truthful queued
        // visual. Not trying to promote a successor — removal of the
        // first message is rare (cancelMessage on a queued send before
        // the CLI echoes), and a truthful indicator on whatever follows
        // is the right default.
        if entry.id == firstUserEntryId {
            firstUserEntryId = nil
        }
        guard !ids.isEmpty else { return }
        controller.coordinator.apply([.remove(ids: ids)], scroll: .none)
    }
}
