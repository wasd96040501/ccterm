import AgentSDK
import Combine
import CoreGraphics
import Foundation

/// Per-transcript state holder — Foundation-only, session-agnostic.
///
/// Owns two derived stacks: the message-shaped `[T3Block]` (produced by
/// `BlockBuilder` from an internal `[Message2]`) and the width-keyed
/// `[T3Block.ID: T3RowLayout]` typeset cache. Publishes `BlockDelta` on
/// every ingest so the VC can `insertRows` incrementally instead of
/// reloading.
///
/// Layout cache lives here (not in the VC) because the *readers* are
/// every VC ever mounted for this transcriptId — putting it in the VC
/// throws it away on sidebar switch. `layout(for:width:)` is the single
/// get-or-compute entry point: cache miss → sync typeset + write back.
/// `writeLayouts(_:width:)` is the bulk-write path Phase-2 (older) uses
/// after off-main typeset.
///
/// `loadHistoryIfNeeded()` is idempotent — non-empty `blocks` (either
/// already loaded, or being loaded by an in-flight task) is a no-op.
@MainActor
public final class TranscriptStore {

    public enum BlockDelta {
        /// First (newest) batch. VC appends and scrolls to tail.
        case tail([T3Block])
        /// Subsequent older batches. VC prepends (index 0..<n).
        case older([T3Block])
    }

    public let transcriptId: String
    public private(set) var blocks: [T3Block] = []
    public private(set) var layouts: [T3Block.ID: T3RowLayout] = [:]
    public private(set) var layoutsWidth: CGFloat = 0
    public let events = PassthroughSubject<BlockDelta, Never>()

    // Private working set: raw messages, in document order oldest→newest.
    // Kept for BlockBuilder's `prior` argument when the future live path
    // needs cross-batch grouping context. Not exposed publicly.
    private var messages: [Message2] = []
    private var loader: Task<Void, Never>?
    private var isFirstBatchEmitted = false

    public init(transcriptId: String) {
        self.transcriptId = transcriptId
    }

    /// Kick off the reverse history stream if we haven't already. Idempotent —
    /// a re-mount of the VC re-enters this with `blocks` already populated
    /// and returns immediately.
    public func loadHistoryIfNeeded() {
        guard blocks.isEmpty, loader == nil else { return }
        let id = transcriptId
        loader = Task { [weak self] in
            let stream = SessionHistory.load(id: id, order: .reverse)
            do {
                for try await batch in stream {
                    guard let self else { return }
                    self.ingest(reverseBatch: batch)
                }
            } catch {
                appLog(.error, "TranscriptStore", "history load: \(error)")
            }
        }
    }

    // MARK: - Ingest

    /// Consume one batch from the SDK's reverse stream. The batch is in
    /// newest→oldest order (SDK contract for `.reverse`); we reverse
    /// locally to document order for `BlockBuilder`, then splice into
    /// the head of `blocks`.
    private func ingest(reverseBatch: [Message2]) {
        guard !reverseBatch.isEmpty else { return }
        let ordered = Array(reverseBatch.reversed())
        let newBlocks = BlockBuilder.build(from: ordered, prior: messages)
        messages.insert(contentsOf: ordered, at: 0)
        blocks.insert(contentsOf: newBlocks, at: 0)
        if !isFirstBatchEmitted {
            isFirstBatchEmitted = true
            events.send(.tail(newBlocks))
        } else {
            events.send(.older(newBlocks))
        }
    }

    // MARK: - Layout cache

    /// Sync get-or-compute. VC's `heightOfRow` / `viewFor` calls this
    /// per row; miss on the current width typesets once and writes back.
    /// Width change wipes the whole cache — resize rebuilds visible rows
    /// via this same path on the next tile.
    public func layout(for block: T3Block, width: CGFloat) -> T3RowLayout {
        invalidateIfWidthChanged(width)
        if let l = layouts[block.id] { return l }
        let fresh = T3RowLayout.make(for: block, width: width)
        layouts[block.id] = fresh
        return fresh
    }

    /// Bulk write from Phase-2 (older) off-main typeset. Called on the
    /// main actor after `Task.detached` produces the layouts.
    public func writeLayouts(_ pairs: [(T3Block.ID, T3RowLayout)], width: CGFloat) {
        invalidateIfWidthChanged(width)
        for (id, l) in pairs { layouts[id] = l }
    }

    private func invalidateIfWidthChanged(_ w: CGFloat) {
        if w != layoutsWidth {
            layouts.removeAll(keepingCapacity: true)
            layoutsWidth = w
        }
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// under macOS 26 (matches every other `@MainActor` class here).
    /// The loader task retains `self weakly`, so no explicit cancel here.
    nonisolated deinit {}
}
