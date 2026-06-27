import AgentSDK
import AppKit
import Foundation

/// Translates entry-level instructions from `Session.onMessagesChange`
/// into block-level commands for `Transcript2Controller`. **Purely imperative**
/// — does not maintain a full `[Block]` mirror to diff against; just the
/// timeline order plus, per entry, the exact blocks it last rendered:
///
/// - `entryOrder: [UUID]`: timeline order of entries.
/// - `entryBlocks: [UUID: [Block]]`: entry.id → the blocks it currently
///   renders as (id view exposed as `entryBlockIds` for tests / anchoring).
///
/// On entry update (`applyUpdate`), the builder recomputes the entry's blocks
/// and the bridge emits the **minimal** change set against the stored ones:
/// - identical id sequence (tool_result merge / confirm / the grow-the-last-
///   block streaming tick) → `.update(id, kind)` for *only the blocks whose
///   kind moved*, preserving row-level animation / selection / fold.
/// - append-only growth (old ids are a prefix of new — paragraphs accruing as
///   an assistant message streams) → update any changed prefix block in place
///   and insert *only* the new trailing blocks; the settled blocks above are
///   never removed, so there is no whole-message `.effectFade` flicker.
/// - genuine structural change (rare) → explicit `.replace` segment swap.
///
/// **Invariant**: after every dispatch, `entryOrder` / `entryBlockIds` match
/// `handle.messages`'s entry order. Reset rebuilds wholesale; append / prepend
/// / remove each maintain consistency locally.
@MainActor
final class Transcript2EntryBridge {
    let controller: Transcript2Controller

    // Module-internal so `cctermTests` (compiled with `@testable import`)
    // can verify the reverse map after `.appended` / `.updated` / `.removed`
    // without having to mount an `NSTableView` (the bridge's contract is that
    // these tables match the entry order it received, regardless of
    // whether the controller's table is real).
    private(set) var entryOrder: [UUID] = []

    /// entry.id → the exact `[Block]` that entry currently renders as. Storing
    /// full blocks (not just ids) lets `applyUpdate` diff by *kind* and emit a
    /// minimal change set — only blocks that actually moved are touched, and
    /// settled blocks above a streaming tail are never removed/reinserted (no
    /// `.effectFade` churn). The id-only view below is derived for tests and
    /// for the structural-change anchor math.
    private var entryBlocks: [UUID: [Block]] = [:]

    /// Derived id view of `entryBlocks`, kept for the test-facing contract
    /// (`entryOrder` / `entryBlockIds` match the entry order received).
    var entryBlockIds: [UUID: [UUID]] { entryBlocks.mapValues { $0.map(\.id) } }

    /// Entry id of the **first user-typed message that arrives live**
    /// (via `.appended`) during this bridge's lifetime. UI-suppresses the
    /// queued visual on that one bubble — the two scenarios this covers
    /// are new-session start and session resume, both of which boot the
    /// CLI from cold; the first send is always queued for a few seconds
    /// while bootstrap runs and a "you just hit send" indicator there
    /// reads as noise.
    ///
    /// History never reaches the bridge — the backfill pipeline applies
    /// loaded blocks directly to the controller — so the pin only ever sees
    /// live `.appended` turns. That is exactly what we want: the *next live
    /// send after a resume* receives the pin, never some long-confirmed
    /// historical turn (which would be a no-op anyway, since replayed
    /// messages already carry `delivery == .confirmed`).
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
        case .appended(let entry):
            applyAppend(entry)
            pushStatuses(for: entry, mode: .live)
        case .updated(let entry):
            applyUpdate(entry)
            pushStatuses(for: entry, mode: .live)
        case .removed(let entry):
            // Block is gone — nothing to push. `Coordinator.applyStructuralChange`
            // already evicted the entry's `statusStates` slots.
            applyRemove(entry)
        }
    }

    /// Push historical tool statuses for entries the backfill pipeline loaded.
    /// The pipeline renders history blocks directly (it doesn't flow through
    /// the bridge's live `apply`), but routes its entries here so failed /
    /// completed history tools keep their color. The bridge owns status
    /// derivation; `.historical` mode never marks a tool `.running`.
    func pushHistoricalStatuses(for entries: [MessageEntry]) {
        for entry in entries { pushStatuses(for: entry, mode: .historical) }
    }

    /// Runtime saw `.result` — turn ended. Clear any tool surface still
    /// stuck in `.running`. Called from `Session.wireRuntimeMessagesSink`
    /// after the runtime fires its turn-finished sink.
    func handleTurnFinished() {
        controller.clearAllRunningStatuses()
    }

    /// Build the blocks for a live entry (`.appended` / `.updated`) via the
    /// inline `MessageEntryBlockBuilder.entryBlocks`. History is built off-main
    /// by `TranscriptBackfillPipeline`, never here.
    ///
    /// Post-processes the result through `applyFirstUserSuppression` so a
    /// single, central place owns the queued-visual override for the
    /// session's first user message.
    private func blocks(for entry: MessageEntry) -> [Block] {
        applyFirstUserSuppression(MessageEntryBlockBuilder.entryBlocks(entry), for: entry.id)
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
    // `.historical` is used by `pushHistoricalStatuses(for:)`, which the
    // backfill pipeline calls for the entries it loads from JSONL. An
    // incomplete tool_use in history is an abandoned run from a long-finished
    // session — the spinner affordance only makes sense for live in-flight
    // calls. `.failed` survives the mode flip because the past failure is
    // still meaningful color.
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
            let childId = StableBlockID.derive(StableBlockID.toolChildPrefix, toolUseId)
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
                let childId = StableBlockID.derive(StableBlockID.toolChildPrefix, toolUseId)
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

    // MARK: - Append (live message)

    private func applyAppend(_ entry: MessageEntry) {
        // First user-typed entry to arrive after init wins the pin. Set
        // **before** calling `self.blocks(for:)` so the suppression sees
        // it on this same build.
        if firstUserEntryId == nil, Self.isUserTyped(entry) {
            firstUserEntryId = entry.id
        }
        let blocks = self.blocks(for: entry)
        if blocks.isEmpty {
            // Entry produced no block (empty user message / all-thinking
            // assistant) — still take an entryOrder slot so a future mutate
            // can resolve the previous-entry anchor correctly.
            entryOrder.append(entry.id)
            entryBlocks[entry.id] = []
            return
        }
        entryOrder.append(entry.id)
        entryBlocks[entry.id] = blocks
        // Position is intrinsic to `.append` — tail. No anchor threading; the
        // tail is wherever `coordinator.blocks` currently ends (after any
        // history the backfill pipeline already prepended).
        controller.apply(.append(blocks))
    }

    // MARK: - Update (tool_result merge / confirm / group grew / live stream)

    /// Reconcile an entry's blocks against what it rendered last time, emitting
    /// the **minimal** change set:
    ///
    /// - **Identical id sequence** (tool_result merge / confirm / the
    ///   grow-the-last-block streaming tick): `.update` only the blocks whose
    ///   `kind` actually moved — settled rows aren't re-typeset every tick.
    /// - **Append-only growth** (old ids are a prefix of new — the dominant
    ///   streaming shape as paragraphs accrue): update any changed prefix block
    ///   in place, then insert *only* the new trailing blocks. The settled
    ///   blocks above are never removed, so there is no whole-message
    ///   `.effectFade` flicker. The insert is anchored inside the entry's own
    ///   range (by re-stating the last existing block through `.replace`), so
    ///   the new blocks never land at the table tail past the loading pill.
    /// - **Structural change** (a shared index changed kind, or blocks were
    ///   dropped — rare): fall back to the explicit full segment swap.
    private func applyUpdate(_ entry: MessageEntry) {
        let old = entryBlocks[entry.id] ?? []
        let new = self.blocks(for: entry)
        let oldIds = old.map(\.id)
        let newIds = new.map(\.id)

        if entryOrder.firstIndex(of: entry.id) == nil {
            // Entry was never registered before this update (out-of-order
            // sink). Defensively append so the block doesn't hang loose.
            entryOrder.append(entry.id)
        }

        // 1) Identical id sequence — per-block update, but only where the kind
        //    moved (a same-content re-send is a true no-op, not a re-typeset).
        if oldIds == newIds {
            let changes = Self.changedUpdates(old: old, new: new)
            if !changes.isEmpty { controller.coordinator.apply(changes, scroll: .none) }
            entryBlocks[entry.id] = new
            return
        }

        // 2) Append-only growth — old ids are a strict prefix of new ids.
        if !oldIds.isEmpty, newIds.count > oldIds.count,
            Array(newIds.prefix(oldIds.count)) == oldIds
        {
            let boundary = oldIds.count - 1
            // Update changed blocks strictly *before* the boundary (settled
            // prose rarely changes once a later block exists, so usually none).
            let prefixUpdates = Self.changedUpdates(
                old: Array(old[0..<boundary]), new: Array(new[0..<boundary]))
            if !prefixUpdates.isEmpty {
                controller.coordinator.apply(prefixUpdates, scroll: .none)
            }
            // Re-state the boundary block + new tail in one anchored replace.
            // The boundary id is unchanged, so if its content didn't move this
            // is a same-content crossfade (invisible); only the genuinely-new
            // tail blocks fade in. Settled blocks above are untouched.
            let replacement = Array(new[boundary...])
            controller.apply(.replace(oldIds: [oldIds[boundary]], with: replacement))
            entryBlocks[entry.id] = new
            return
        }

        // 3) Genuine structural change — explicit full segment swap. A
        //    degenerate `oldIds == []` (out-of-order sink) routes to `.append`
        //    inside the coordinator.
        controller.apply(.replace(oldIds: oldIds, with: new))
        entryBlocks[entry.id] = new
    }

    /// `.update` changes for blocks whose `kind` differs at the same position.
    /// Precondition: `old` and `new` share an id at each index. Identical
    /// blocks are skipped so a re-render only touches what moved.
    private static func changedUpdates(old: [Block], new: [Block]) -> [Transcript2Controller.Change] {
        zip(old, new).compactMap { o, n in
            o.kind == n.kind ? nil : .update(id: n.id, kind: n.kind)
        }
    }

    // MARK: - Remove (cancelMessage)

    private func applyRemove(_ entry: MessageEntry) {
        let ids = entryBlocks[entry.id]?.map(\.id) ?? []
        entryBlocks.removeValue(forKey: entry.id)
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
