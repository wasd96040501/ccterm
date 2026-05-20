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
/// one more switch arm in `Storage.dispatchSchedule`.
enum HighlightValue: Sendable {
    case tokens([SyntaxToken])
    case lineMap([String: [SyntaxToken]])
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
    private var values: [Key: HighlightValue] = [:]
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

    /// Kick a highlight pass for `block` if its kind has any highlight
    /// scopes. Multiple scopes from the same block batch into one
    /// `engine.highlightBatch` call (one JSCore round-trip).
    func schedule(_ block: Block) {
        guard let plan = Self.plan(for: block), let engine else { return }

        let gen = (inflightGen[block.id] ?? 0) &+ 1
        inflightGen[block.id] = gen
        let blockId = block.id

        Task { [weak self] in
            let payload = plan.payload.map { ($0.code, $0.lang) }
            let results = await engine.highlightBatch(payload)
            await MainActor.run {
                guard let self else { return }
                // Generation drift → a newer `schedule` or a `drop` ran
                // between this task's launch and its completion. Discard
                // the writeback so the newer pipeline owns the data.
                guard self.inflightGen[blockId] == gen else { return }
                for (scope, value) in plan.writeback(results) {
                    self.values[Key(blockId: blockId, scope: scope)] = value
                }
                self.onDidFill?(blockId)
            }
        }
    }

    /// Wipe every entry for `blockId` and bump the generation so an
    /// in-flight task for the same id can't commit afterward.
    func drop(blockId: UUID) {
        inflightGen[blockId] = (inflightGen[blockId] ?? 0) &+ 1
        values = values.filter { $0.key.blockId != blockId }
    }

    // MARK: - Per-kind dispatch

    /// One block's highlight job: the JS payload to send and a writeback
    /// closure that turns the per-request results into `(scope, value)`
    /// pairs. Lets a kind decide whether each request becomes its own
    /// `.tokens` scope (codeBlock) or rolls up into a single `.lineMap`
    /// (diff) — both fit one round-trip.
    private struct Plan {
        let payload: [(code: String, lang: String?)]
        let writeback: ([[SyntaxToken]]) -> [(scope: Scope, value: HighlightValue)]
    }

    /// **The single switch a new highlight-bearing block kind has to
    /// touch.** `nil` = no highlight contribution.
    private static func plan(for block: Block) -> Plan? {
        switch block.kind {
        case .codeBlock(let language, let code):
            return Plan(
                payload: [(code, language)],
                writeback: { results in
                    [(.codeBlock, .tokens(results.first ?? []))]
                })

        case .toolGroup(let group):
            // Fan every child's highlight payload into one shared JS
            // round-trip. Each child decides its own request slice via
            // `ToolGroupChildHighlight.requests(for:)`; the writeback
            // walks the per-child ranges, asks each child to fold its
            // tokens into a `HighlightValue`, and emits a `(scope,
            // value)` pair keyed by `child.id`. Adding a new
            // highlight-bearing child kind is one switch arm in
            // `ToolGroupChildHighlight` — no work here.
            var payload: [(code: String, lang: String?)] = []
            var ranges:
                [(
                    itemId: UUID, range: Range<Int>,
                    finalize: ([[SyntaxToken]]) -> HighlightValue?
                )] = []
            for child in group.children {
                guard let plan = ToolGroupChildHighlight.requests(for: child)
                else { continue }
                let start = payload.count
                payload.append(contentsOf: plan.payload)
                let end = payload.count
                guard end > start else { continue }
                ranges.append((child.id, start..<end, plan.finalize))
            }
            guard !payload.isEmpty else { return nil }
            return Plan(
                payload: payload,
                writeback: { results in
                    var out: [(scope: Scope, value: HighlightValue)] = []
                    for (itemId, range, finalize) in ranges {
                        let slice = Array(results[range])
                        guard let value = finalize(slice) else { continue }
                        out.append((.toolGroupChild(itemId: itemId), value))
                    }
                    return out
                })

        case .heading, .paragraph, .image, .userAttachments, .list, .table,
            .blockquote, .thematicBreak, .userBubble, .loadingPill:
            return nil
        }
    }
}
