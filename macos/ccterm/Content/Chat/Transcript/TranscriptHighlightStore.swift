import AppKit
import Foundation

/// Per-transcript syntax-highlight store — thin wrapper over
/// `Transcript2HighlightStorage` (which owns the per-scope dedup +
/// generation guard invariants documented at
/// `NativeTranscript2/CLAUDE.md § 2.15`). The wrapper adds:
///
/// - **Internalized engine-attach reschedule.** Unlike the old
///   `setEngine`, which puts the reschedule burden on the caller,
///   `attachEngine(_:)` here re-schedules every previously-scheduled scope
///   automatically. VC doesn't need to remember what it asked for.
/// - **Full-dict snapshot.** `snapshot()` returns the underlying
///   `[Transcript2HighlightKey: HighlightValue]` verbatim. Because Swift
///   dicts are COW, this is O(1) at call time — the callee reads by key
///   (`Transcript2HighlightKey(blockId:, scope:)`) so passing the whole
///   dict is no more expensive than a per-block-filtered one, and a
///   per-block filter would be O(N) per call, quadratic across a tile.
///
/// Kept as a Store (state/cache holder with a change signal) per the
/// project's role vocabulary — not `Storage`, not `Manager`.
@MainActor
final class TranscriptHighlightStore {

    private let storage: Transcript2HighlightStorage
    /// Blocks previously handed to `schedule(block:)`. Kept so
    /// `attachEngine` can retry them all when the engine goes from
    /// nil → non-nil.
    private var seen: [UUID: Block] = [:]
    /// Attached engine, if any. `attachEngine` compares by identity so a
    /// second call with the same instance is a cheap no-op.
    private weak var engine: SyntaxHighlightEngine?

    /// Notified after tokens land for at least one scope on `blockId`.
    /// VC uses this to `invalidateLayout` + `reloadData(forRowIndexes:)`.
    var onDidFill: ((UUID) -> Void)? {
        get { storage.onDidFill }
        set { storage.onDidFill = newValue }
    }

    init() {
        self.storage = Transcript2HighlightStorage(engine: nil)
    }

    /// Idempotent late-bind. If `newEngine === engine`, no-op. Otherwise
    /// swap the engine on the underlying storage and re-schedule every
    /// block we've ever been asked to schedule — flushing any pending
    /// scopes that were queued while engine was nil.
    func attachEngine(_ newEngine: SyntaxHighlightEngine?) {
        if newEngine === engine { return }
        engine = newEngine
        storage.setEngine(newEngine)
        guard newEngine != nil else { return }
        for block in seen.values {
            storage.schedule(block)
        }
    }

    /// Record the block and hand it to the underlying storage. The
    /// storage dedupes internally against its `sourceKeys` fingerprint,
    /// so calling this on scroll-hot paths is cheap.
    func schedule(block: Block) {
        seen[block.id] = block
        storage.schedule(block)
    }

    /// Drop everything the storage knows about `blockId` (fold state
    /// eviction, block removal, …). Also forgets `seen` so a subsequent
    /// `attachEngine` re-schedule doesn't ressurect it.
    func drop(blockId: UUID) {
        seen.removeValue(forKey: blockId)
        storage.drop(blockId: blockId)
    }

    /// Full dict snapshot. Called on MainActor. `[Key: Value]` is a COW
    /// value type — this is O(1) (no copy unless a mutation follows the
    /// read). `RowLayout.make(highlights:)` looks entries up by key
    /// (`Transcript2HighlightKey(blockId:, scope:)`), so passing the
    /// whole dict costs no more than a per-block-filtered one — and the
    /// per-block filter itself was O(N) per call, which turned scroll
    /// tile queries into O(N × visible-rows).
    func snapshot() -> [Transcript2HighlightKey: HighlightValue] {
        storage.snapshot()
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// under macOS 26 — matches every other `@MainActor` class in the
    /// codebase and the `Transcript2HighlightStorage` we wrap.
    nonisolated deinit {}
}
