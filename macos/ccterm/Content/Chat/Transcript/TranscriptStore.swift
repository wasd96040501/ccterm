import AgentSDK
import Combine
import CoreGraphics
import Foundation

/// Per-transcript state holder — session-agnostic, renderer-agnostic.
///
/// Owns the message-shaped `[Block]` (produced by the SDK stream →
/// `ReverseEntryBuilder` → `MessageEntryBlockBuilder` chain from a private
/// `[Message2]` working set) and the width-keyed `[UUID: RowLayout]`
/// typeset cache. Publishes `BlockDelta` on every ingest so the VC can
/// `insertRows` incrementally instead of reloading.
///
/// **Data flow:** SDK stream → ReverseEntryBuilder (MainActor) →
/// MessageEntryBlockBuilder.blocks(from:) (MainActor) → events.send(.tail
/// | .older) → VC picks up, drives typeset + insertRows.
///
/// **Renderer coupling: none.** Foundation-only — no `Transcript2Controller`,
/// no `Transcript2Coordinator`, no `NSView`. The VC pulls `blocks` and
/// `layouts` directly. `Block` and `RowLayout` are the only render-shaped
/// types the store touches, and they're pure values (`Sendable`).
///
/// **Layout cache lives here** (not in the VC) because the *readers* are
/// every VC ever mounted for this transcriptId — putting it in the VC
/// throws it away on sidebar switch. `layout(for:width:folds:statuses:highlights:)`
/// is the single get-or-compute entry point: cache miss → sync typeset
/// via `RowLayout.make` + write back. `writeLayouts(_:width:)` is the
/// bulk-write path Phase 1/2 use after off-main typeset;
/// `retargetWidth(_:)` is the explicit width-transition seam used by
/// live-resize (see `docs/refactor/transcript-refactor.md § 5.5`).
///
/// **Lifecycle.** The store never cancels its loader on VC removal — the
/// registry holds the store past the VC, and letting the load finish
/// means the next mount pays zero SDK cost. `nonisolated deinit` matches
/// the macOS 26 executor-hop workaround used elsewhere.
@MainActor
final class TranscriptStore {

    enum BlockDelta: Sendable {
        /// First (newest) batch. VC appends at the tail and scrolls into view.
        case tail([Block])
        /// Subsequent older batches. VC prepends at the head (index 0..<n).
        case older([Block])
    }

    let transcriptId: String
    private(set) var blocks: [Block] = []
    private(set) var layouts: [UUID: RowLayout] = [:]
    private(set) var layoutsWidth: CGFloat = 0

    /// Per-transcript fold state — keyed by `Block.id` for a group host
    /// or `Child.id` for a child header. Lives on the store (not the VC)
    /// so it survives sidebar switch-away: a user who expanded a tool
    /// group, switched to another session, and switched back expects it
    /// to still be expanded. Sparse — absent = default (folded).
    private(set) var folds: [UUID: Bool] = [:]
    /// Per-transcript tool status — same rationale as `folds`. Sparse —
    /// absent = `.completed`. History-only currently never writes here;
    /// exposed for symmetry with the live-path renderer.
    private(set) var statuses: [UUID: ToolStatus] = [:]

    let events = PassthroughSubject<BlockDelta, Never>()

    private var builder = ReverseEntryBuilder()
    private var loader: Task<Void, Never>?
    private var didStartLoad = false

    init(transcriptId: String) {
        self.transcriptId = transcriptId
    }

    /// Kick off the reverse history stream once. Idempotent — re-mounting
    /// the VC re-enters this on an already-loaded (or in-flight) store and
    /// returns immediately.
    func loadHistoryIfNeeded() {
        guard !didStartLoad else { return }
        didStartLoad = true
        let id = transcriptId
        loader = Task { [weak self] in
            let stream = SessionHistory.load(id: id, order: .reverse)
            do {
                for try await batch in stream {
                    guard let self else { return }
                    self.ingestReverseBatch(batch)
                }
                self?.finalizeLoad()
            } catch {
                appLog(.error, "TranscriptStore", "history load: \(error)")
            }
        }
    }

    // MARK: - Ingest

    /// Consume one SDK batch. Per `SessionHistory.Order.reverse`'s contract
    /// the batch is newest→oldest; we feed each message to the builder in
    /// that order and gather the entries it finalizes. Within one batch the
    /// builder may finalize entries out of doc order (a `closeRun` on an
    /// older message returns runs newer than what a later `ingest` returns),
    /// so we invert by inserting each result at index 0 — the batch's final
    /// entry list is oldest-first (document order).
    private func ingestReverseBatch(_ batch: [Message2]) {
        var entries: [MessageEntry] = []
        for m in batch {
            let out = builder.ingest(m)
            entries.insert(contentsOf: out, at: 0)
        }
        guard !entries.isEmpty else { return }
        applyEntries(entries)
    }

    /// File top reached. Flush the still-open group + any true-orphan
    /// tool_results — these belong at the very top of the document.
    private func finalizeLoad() {
        let tail = builder.finish()
        guard !tail.isEmpty else { return }
        applyEntries(tail)
    }

    private func applyEntries(_ entries: [MessageEntry]) {
        let newBlocks = MessageEntryBlockBuilder.blocks(from: entries)
        guard !newBlocks.isEmpty else { return }
        if blocks.isEmpty {
            blocks = newBlocks
            events.send(.tail(newBlocks))
        } else {
            blocks.insert(contentsOf: newBlocks, at: 0)
            events.send(.older(newBlocks))
        }
    }

    // MARK: - Layout cache

    /// Sync get-or-compute. VC's `heightOfRow` / `viewFor` calls this per
    /// row; miss on the current width typesets once and writes back. Width
    /// change wipes the whole cache — resize rebuilds visible rows via
    /// this same path on the next tile.
    func layout(
        for block: Block,
        width: CGFloat,
        folds: [UUID: Bool] = [:],
        statuses: [UUID: ToolStatus] = [:],
        highlights: [Transcript2HighlightKey: HighlightValue] = [:]
    ) -> RowLayout {
        invalidateIfWidthChanged(width)
        if let l = layouts[block.id] { return l }
        let fresh = RowLayout.make(
            for: block, width: width,
            folds: folds, statuses: statuses, highlights: highlights)
        layouts[block.id] = fresh
        return fresh
    }

    /// Explicit width-transition seam. Called by VC on live-resize or
    /// any observed table-width change before dispatching an off-main
    /// prefetch — the prefetch's `writeLayouts` call has a
    /// `width == layoutsWidth` guard, so `layoutsWidth` must already be
    /// updated before the prefetch's pairs come back on the main hop.
    /// See `docs/refactor/transcript-refactor.md § 5.5`.
    func retargetWidth(_ width: CGFloat) {
        invalidateIfWidthChanged(width)
    }

    /// Bulk write from off-main typeset. Called on main after
    /// `Task.detached` produces the layouts. Two guards from
    /// `NativeTranscript2/CLAUDE.md`:
    ///
    /// - **Stale-batch drop (§ 5.3):** if `width` doesn't match the
    ///   store's current `layoutsWidth`, the entire batch is discarded —
    ///   VC's next `heightOfRow` on affected blocks lazy-typesets at the
    ///   new width. Self-healing.
    /// - **§ 2.14 anti-poison:** never overwrite an already-fresh entry.
    ///   A background task finishing after a sync `apply` invalidated
    ///   + lazy-refilled the entry would otherwise clobber the
    ///   authoritative fresh layout with its older snapshot.
    ///
    /// Also skips entries for blocks that have since been removed from
    /// `blocks[]` (the review's stale-block guard).
    func writeLayouts(_ pairs: [(UUID, RowLayout)], width: CGFloat) {
        guard width == layoutsWidth else { return }
        let live = Set(blocks.map { $0.id })
        for (id, l) in pairs where live.contains(id) {
            if layouts[id] != nil { continue }
            layouts[id] = l
        }
    }

    /// Single-key evict. Fold toggle / highlight `onDidFill` /
    /// `.update`-style content mutation all call this before triggering
    /// `noteHeightOfRows` + `reloadData(forRowIndexes:)`.
    func invalidateLayout(id: UUID) {
        layouts.removeValue(forKey: id)
    }

    /// Flip the fold flag for `id` (block host or child) and evict the
    /// enclosing block's layout cache entry so the next `heightOfRow`
    /// re-typesets against the new fold state. Returns the enclosing
    /// block id so the VC knows which row to reload.
    func toggleFold(id: UUID) -> UUID? {
        let hostId = resolveHostBlockId(fromFoldId: id) ?? id
        folds[id, default: false].toggle()
        layouts.removeValue(forKey: hostId)
        return hostId
    }

    private func resolveHostBlockId(fromFoldId foldId: UUID) -> UUID? {
        if blocks.contains(where: { $0.id == foldId }) { return foldId }
        for block in blocks {
            if case .toolGroup(let group) = block.kind,
                group.children.contains(where: { $0.id == foldId })
            {
                return block.id
            }
        }
        return nil
    }

    private func invalidateIfWidthChanged(_ w: CGFloat) {
        if w != layoutsWidth {
            layouts.removeAll(keepingCapacity: true)
            layoutsWidth = w
        }
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// under macOS 26 (matches every other `@MainActor` class here).
    /// The loader task retains `self` weakly, so no explicit cancel here.
    nonisolated deinit {}
}
