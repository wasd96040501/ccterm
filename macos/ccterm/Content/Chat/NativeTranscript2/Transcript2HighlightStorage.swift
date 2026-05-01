import AppKit

// MARK: - Key types (file-scope so conformance stays nonisolated)

/// Where inside a block highlight tokens belong. One block kind may emit
/// multiple scopes (a future diff block emits one per hunk × side);
/// adding a scope is two lines (enum case + switch arm in
/// `Transcript2HighlightStorage.requests(for:)`).
///
/// Declared at file scope so the `Hashable` / `Sendable` conformance is
/// nonisolated — the storage class is `@MainActor`, but the off-main
/// `makeLayout` path looks up `[Key: ...]` snapshots without crossing the
/// actor boundary, so the key/value types must work outside MainActor.
enum Transcript2HighlightScope: Hashable, Sendable {
    case codeBlock
    // case diffOld(hunk: Int)
    // case diffNew(hunk: Int)
}

struct Transcript2HighlightKey: Hashable, Sendable {
    let blockId: UUID
    let scope: Transcript2HighlightScope
}

// MARK: - Storage

/// Per-block, async-filled side data backing syntax highlighting (and any
/// future highlight-shaped derivative — diff hunks, inline annotations,
/// etc.). Storage is keyed by `(blockId, Scope)` so a single block can
/// carry multiple highlight regions (e.g. diff old/new sides) without
/// extra dicts.
///
/// ### Lifecycle
///
/// - `schedule(_:)` — called from `Coordinator.applyStructuralChange` for
///   `.insert` and `.update`. Looks at `block.kind`, emits the highlight
///   requests for that kind, fires a single `engine.highlightBatch` over
///   them, writes the results back, and notifies via `onDidFill(blockId)`
///   so the coordinator can reload the row.
/// - `drop(blockId:)` — called for `.remove` and at the head of `.update`.
///   Wipes every entry whose id matches and bumps the generation counter
///   so an in-flight schedule for the same id no longer commits.
/// - `snapshot()` — read-only copy of the tokens map. Used by the
///   coordinator's off-main precompute paths (`applyInBackground`,
///   `refillLayoutCache`) so the detached task can call `makeLayout`
///   without crossing the actor boundary mid-loop.
///
/// ### Generation guard
///
/// `inflightGen[id]` is bumped on every `schedule` and on every `drop`.
/// A task captures the generation at start; if it drifted by completion,
/// the writeback is skipped. This prevents an older highlight (kicked
/// before an `.update` replaced the code) from clobbering a newer one
/// that finished sooner.
@MainActor
final class Transcript2HighlightStorage {
    typealias Scope = Transcript2HighlightScope
    typealias Key = Transcript2HighlightKey

    /// Settable so SwiftUI hosts can inject `\.syntaxEngine` from the
    /// environment after the controller is constructed. `nil` puts the
    /// storage in pass-through mode: `schedule` is a no-op, code blocks
    /// render plain. Reattach via `setEngine(_:)`.
    private var engine: SyntaxHighlightEngine?
    private var tokens: [Key: [SyntaxToken]] = [:]
    /// Per-block generation counter — see class doc. Sparse: an id with
    /// no in-flight task simply has no entry.
    private var inflightGen: [UUID: Int] = [:]

    /// Notified after a `schedule` writeback lands. Coordinator wires this
    /// to a single-row reload (`removeCachedLayout` + `reloadData(forRowIndexes:)`).
    /// `nil` while the storage isn't attached to a coordinator yet.
    var onDidFill: ((UUID) -> Void)?

    var hasEngine: Bool { engine != nil }

    init(engine: SyntaxHighlightEngine?) {
        self.engine = engine
    }

    /// Late-binding entry point. Idempotent if `engine` is already set to
    /// the same instance (compared by identity); otherwise replaces. The
    /// caller (`Transcript2Coordinator.attachSyntaxEngine`) is responsible
    /// for scheduling already-installed blocks once the engine flips from
    /// `nil` to non-nil — storage can't see the block list.
    func setEngine(_ engine: SyntaxHighlightEngine?) {
        self.engine = engine
    }

    // MARK: - Read

    func tokens(blockId: UUID, scope: Scope) -> [SyntaxToken]? {
        tokens[Key(blockId: blockId, scope: scope)]
    }

    /// Cheap dict copy for off-main consumers. `Coordinator.makeLayout` is
    /// `nonisolated static`; the detached precompute paths capture this
    /// snapshot before hopping off main so the inner per-block lookup
    /// stays actor-free.
    func snapshot() -> [Key: [SyntaxToken]] { tokens }

    // MARK: - Lifecycle

    /// Kick a highlight pass for `block` if its kind has any highlight
    /// scopes. Multiple scopes from the same block batch into one
    /// `engine.highlightBatch` call (one JSCore round-trip).
    func schedule(_ block: Block) {
        let reqs = Self.requests(for: block)
        guard !reqs.isEmpty, let engine else { return }

        let gen = (inflightGen[block.id] ?? 0) &+ 1
        inflightGen[block.id] = gen
        let blockId = block.id

        Task { [weak self] in
            let payload = reqs.map { ($0.code, $0.lang) }
            let results = await engine.highlightBatch(payload)
            await MainActor.run {
                guard let self else { return }
                // Generation drift → a newer `schedule` or a `drop` ran
                // between this task's launch and its completion. Discard
                // the writeback so the newer pipeline owns the data.
                guard self.inflightGen[blockId] == gen else { return }
                for (req, tks) in zip(reqs, results) {
                    self.tokens[Key(blockId: blockId, scope: req.scope)] = tks
                }
                self.onDidFill?(blockId)
            }
        }
    }

    /// Wipe every entry for `blockId` and bump the generation so an
    /// in-flight task for the same id can't commit afterward.
    func drop(blockId: UUID) {
        inflightGen[blockId] = (inflightGen[blockId] ?? 0) &+ 1
        tokens = tokens.filter { $0.key.blockId != blockId }
    }

    // MARK: - Per-kind dispatch

    /// **The single switch a new highlight-bearing block kind has to
    /// touch.** Returns the list of `(scope, code, language)` triples
    /// the kind contributes to highlighting. Empty list = no highlight
    /// for this kind.
    private static func requests(
        for block: Block
    ) -> [(scope: Scope, code: String, lang: String?)] {
        switch block.kind {
        case .codeBlock(let language, let code):
            return [(.codeBlock, code, language)]
        case .heading, .paragraph, .image, .list, .table,
             .blockquote, .thematicBreak, .userBubble:
            return []
        }
    }
}
