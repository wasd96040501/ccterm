import AppKit

// MARK: - Key types (file-scope so conformance stays nonisolated)

/// Where inside a block highlight tokens belong. One block kind may emit
/// multiple scopes (a future diff block emits one per hunk × side);
/// adding a scope is two lines (enum case + switch arm in
/// `Transcript2HighlightStorage.subPlans(for:)`).
///
/// Declared at file scope so the `Hashable` / `Sendable` conformance is
/// nonisolated — the storage class is `@MainActor`, but the off-main
/// `makeLayout` path looks up `[Key: ...]` snapshots without crossing the
/// actor boundary, so the key/value types must work outside MainActor.
enum Transcript2HighlightScope: Hashable, Sendable {
    case codeBlock
    /// Per-item highlight scope for a `toolGroup` row. The associated
    /// `itemId` is `ToolGroupBlock.Child.id` so a single host block can
    /// carry independent highlight payloads for each of its children
    /// without colliding. `fileEdit` and `read` consume this scope as
    /// per-unique-line `.lineMap`; `bash` consumes it as `.tokens` for
    /// the command line. Future child kinds that want highlight can
    /// pick whichever `HighlightValue` shape fits their draw model.
    case toolGroupChild(itemId: UUID)
}

struct Transcript2HighlightKey: Hashable, Sendable {
    let blockId: UUID
    let scope: Transcript2HighlightScope
}

/// Per-key payload. Two shapes today:
/// - `.tokens` — one flat token stream for the whole region (codeBlock).
/// - `.lineMap` — `[lineContent: tokens]` for layouts that highlight at
///   line granularity (diff). Keyed by raw line content so a diff's draw
///   pass can look tokens up by `line.content` without carrying indices.
///
/// New highlight-bearing layouts pick whichever shape matches their draw
/// model — single contiguous text → `.tokens`; per-line independently-
/// stylable text → `.lineMap`. Adding a third shape = one more case here +
/// one more switch arm in `Storage.subPlans`.
enum HighlightValue: Sendable {
    case tokens([SyntaxToken])
    case lineMap([String: [SyntaxToken]])
}

// MARK: - Storage

/// Per-block, async-filled side data backing syntax highlighting (and any
/// future highlight-shaped derivative — diff hunks, inline annotations,
/// etc.). Storage is keyed by `(blockId, Scope)` so a single block can
/// carry multiple highlight regions (e.g. a tool group's per-child
/// payloads) without extra dicts.
///
/// ### Lifecycle
///
/// - `schedule(_:)` — called from `Coordinator.applyStructuralChange` for
///   `.insert` and `.update`. Looks at `block.kind`, computes the per-scope
///   sub-plans, **diffs each scope's source fingerprint** against what's
///   already cached, and only kicks JS tokenisation for scopes whose
///   payload actually changed. Stale scopes (children that disappeared
///   from this block) are wiped. One `engine.highlightBatch` call covers
///   the entire surviving set; `onDidFill(blockId)` fires once after the
///   writeback if any scope landed.
/// - `drop(blockId:)` — called for `.remove`. Wipes every scope this
///   block carries, bumping each scope's generation so in-flight tasks
///   targeting those scopes can no longer commit. `.update` does **not**
///   route through here — `schedule(_:)` handles per-scope invalidation
///   internally, which lets sibling children survive a partial update
///   without their tokens flickering off.
/// - `snapshot()` — read-only copy of the tokens map. Used by the
///   coordinator's off-main precompute paths (`applyInBackground`,
///   `refillLayoutCache`) so the detached task can call `makeLayout`
///   without crossing the actor boundary mid-loop.
///
/// ### Generation guard
///
/// `inflightGen[key]` is bumped per-scope on every schedule that
/// targets the scope, and on every drop. A task captures the
/// generation per scope at start; if a given scope's generation
/// drifted by completion, that scope's writeback is skipped. This
/// prevents an older highlight (kicked before an `.update` replaced
/// the source) from clobbering a newer one that finished sooner.
///
/// ### Source-key dedup (why sibling tool_results don't flicker the
/// other children)
///
/// `sourceKeys[key]` records the fingerprint of the payload that
/// produced `values[key]` (or that's in flight to produce it). On
/// `schedule`, sub-plans whose fingerprint matches the cached value
/// are skipped entirely — no drop, no JS call, no `onDidFill`. The
/// effect at the row level: a tool-group block whose `kind` changes
/// because a *sibling* child got its `tool_result` no longer drops
/// the unchanged children's tokens, so the rendered cell does not
/// flash from coloured → plain → coloured during streaming.
@MainActor
final class Transcript2HighlightStorage {
    typealias Scope = Transcript2HighlightScope
    typealias Key = Transcript2HighlightKey

    /// Settable so SwiftUI hosts can inject `\.syntaxEngine` from the
    /// environment after the controller is constructed. `nil` puts the
    /// storage in pass-through mode: `schedule` is a no-op, code blocks
    /// render plain. Reattach via `setEngine(_:)`.
    private var engine: SyntaxHighlightEngine?
    private var values: [Key: HighlightValue] = [:]
    /// Per-scope content fingerprint of the payload that produced
    /// `values[key]` (or that's in flight to produce it). Compared
    /// against the new sub-plan's `sourceKey` inside `schedule(_:)`
    /// to skip tokenisation for scopes whose payload didn't change.
    /// Cleared together with `values` in `drop`.
    private var sourceKeys: [Key: String] = [:]
    /// Per-scope generation counter — see class doc. Sparse: a key
    /// with no in-flight task simply has no entry.
    private var inflightGen: [Key: Int] = [:]

    /// Notified after a `schedule` writeback lands tokens for at least
    /// one scope. Coordinator wires this to a single-row reload
    /// (`removeCachedLayout` + `reloadData(forRowIndexes:)`). `nil`
    /// while the storage isn't attached to a coordinator yet.
    var onDidFill: ((UUID) -> Void)?

    var hasEngine: Bool { engine != nil }

    init(engine: SyntaxHighlightEngine?) {
        self.engine = engine
    }

    /// macOS 26 SDK workaround — the default `@MainActor` deinit routes
    /// through `swift_task_deinitOnExecutorImpl`, which aborts inside
    /// `swift::TaskLocal::StopLookupScope::~StopLookupScope()` (this
    /// class is the dealloc-chain leaf that owns the offending
    /// TaskLocal state in `cctermTests`' deinit chain). `nonisolated`
    /// skips the executor hop. See `Session.deinit`.
    nonisolated deinit {}

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
        guard case .tokens(let t) = values[Key(blockId: blockId, scope: scope)]
        else { return nil }
        return t
    }

    func lineMap(blockId: UUID, scope: Scope) -> [String: [SyntaxToken]]? {
        guard case .lineMap(let m) = values[Key(blockId: blockId, scope: scope)]
        else { return nil }
        return m
    }

    /// Cheap dict copy for off-main consumers. `Coordinator.makeLayout` is
    /// `nonisolated static`; the detached precompute paths capture this
    /// snapshot before hopping off main so the inner per-block lookup
    /// stays actor-free.
    func snapshot() -> [Key: HighlightValue] { values }

    // MARK: - Lifecycle

    /// Diff a block's per-scope highlight payload against what's already
    /// cached and only kick JS tokenisation for the scopes whose source
    /// fingerprint changed. Scopes that no longer appear on the block
    /// (e.g. a tool-group child was removed) are wiped. One
    /// `engine.highlightBatch` call covers the surviving set;
    /// `onDidFill(blockId)` fires after the writeback if at least one
    /// scope landed.
    func schedule(_ block: Block) {
        let newSubs = Self.subPlans(for: block)
        let blockId = block.id

        // Wipe scopes that no longer exist for this block. Bumps gen so
        // any in-flight task targeting that scope drops its writeback.
        let newKeys = Set(newSubs.map { Key(blockId: blockId, scope: $0.scope) })
        let currentKeys = sourceKeys.keys.filter { $0.blockId == blockId }
        for stale in currentKeys where !newKeys.contains(stale) {
            inflightGen[stale, default: 0] &+= 1
            values.removeValue(forKey: stale)
            sourceKeys.removeValue(forKey: stale)
        }

        guard let engine, !newSubs.isEmpty else { return }

        // Filter sub-plans to scopes whose source actually changed. For
        // each changed scope: drop the stale value, bump its gen, record
        // the new fingerprint, and queue it for the shared JS batch.
        struct ScheduledScope {
            let key: Key
            let range: Range<Int>
            let finalize: ([[SyntaxToken]]) -> HighlightValue?
            let gen: Int
        }
        var flatPayload: [(code: String, lang: String?)] = []
        var scheduled: [ScheduledScope] = []
        for sub in newSubs {
            let key = Key(blockId: blockId, scope: sub.scope)
            if sourceKeys[key] == sub.sourceKey { continue }
            inflightGen[key, default: 0] &+= 1
            sourceKeys[key] = sub.sourceKey
            values.removeValue(forKey: key)
            let start = flatPayload.count
            flatPayload.append(contentsOf: sub.payload)
            let end = flatPayload.count
            guard end > start else { continue }
            scheduled.append(
                ScheduledScope(
                    key: key, range: start..<end,
                    finalize: sub.finalize,
                    gen: inflightGen[key]!))
        }
        guard !scheduled.isEmpty else { return }

        // Strip our `lang` tuple label so the call matches the engine's
        // `language`-labelled signature (purely syntactic — same values).
        let enginePayload = flatPayload.map { ($0.code, $0.lang) }
        Task { [weak self] in
            let results = await engine.highlightBatch(enginePayload)
            await MainActor.run {
                guard let self else { return }
                var anyLanded = false
                for entry in scheduled {
                    // Per-scope generation drift → a newer `schedule` or a
                    // `drop` ran between launch and completion for *this*
                    // scope. Sibling scopes can still land independently.
                    guard self.inflightGen[entry.key] == entry.gen,
                        let value = entry.finalize(Array(results[entry.range]))
                    else { continue }
                    self.values[entry.key] = value
                    anyLanded = true
                }
                if anyLanded { self.onDidFill?(blockId) }
            }
        }
    }

    /// Wipe every entry for `blockId` and bump each scope's generation
    /// so in-flight tasks for those scopes can't commit afterward.
    /// Called for `.remove`. `.update` no longer routes here —
    /// `schedule(_:)` handles per-scope invalidation internally.
    func drop(blockId: UUID) {
        let keys = sourceKeys.keys.filter { $0.blockId == blockId }
        for key in keys {
            inflightGen[key, default: 0] &+= 1
            values.removeValue(forKey: key)
            sourceKeys.removeValue(forKey: key)
        }
        // Defensive: also drop any value rows whose sourceKeys was
        // already missing (would only happen if a future code path
        // wrote `values` without touching `sourceKeys`).
        values = values.filter { $0.key.blockId != blockId }
    }

    // MARK: - Per-scope plans

    /// One scope's highlight job: the JS payload, the writeback closure
    /// that folds results into a `HighlightValue`, and the **source
    /// fingerprint** used to skip rescheduling when the payload hasn't
    /// changed since the last `schedule` call for this scope.
    private struct SubPlan {
        let scope: Scope
        let sourceKey: String
        let payload: [(code: String, lang: String?)]
        let finalize: ([[SyntaxToken]]) -> HighlightValue?
    }

    /// **The single switch a new highlight-bearing block kind has to
    /// touch.** Returns an empty array for kinds without highlight
    /// contribution.
    private static func subPlans(for block: Block) -> [SubPlan] {
        switch block.kind {
        case .codeBlock(let language, let code):
            return [
                SubPlan(
                    scope: .codeBlock,
                    sourceKey: fingerprint(payload: [(code, language)]),
                    payload: [(code, language)],
                    finalize: { results in .tokens(results.first ?? []) }
                )
            ]

        case .toolGroup(let group):
            // Fan every child's highlight payload into one shared JS
            // round-trip. Each child decides its own request slice via
            // `ToolGroupChildHighlight.requests(for:)`; the source
            // fingerprint covers the full slice so changing one
            // child's payload doesn't invalidate the others.
            return group.children.compactMap { child -> SubPlan? in
                guard let plan = ToolGroupChildHighlight.requests(for: child)
                else { return nil }
                return SubPlan(
                    scope: .toolGroupChild(itemId: child.id),
                    sourceKey: fingerprint(payload: plan.payload),
                    payload: plan.payload,
                    finalize: plan.finalize)
            }

        case .heading, .paragraph, .image, .userAttachments, .list, .table,
            .blockquote, .thematicBreak, .userBubble, .loadingPill:
            return []
        }
    }

    /// Per-process content fingerprint for a sub-plan payload. Used as
    /// the dedup key in `sourceKeys` — equality means "same content was
    /// already scheduled, skip the work." `Hasher` is seeded per
    /// process, which is fine: `sourceKeys` lives in memory only and
    /// never crosses a launch boundary.
    private static func fingerprint(payload: [(code: String, lang: String?)]) -> String {
        var hasher = Hasher()
        hasher.combine(payload.count)
        for entry in payload {
            hasher.combine(entry.code)
            hasher.combine(entry.lang)
        }
        return String(hasher.finalize())
    }
}
