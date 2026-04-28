import AppKit

/// Public, imperative API for `NativeTranscript2`. Three orthogonal channels:
///
/// 1. **Mutation** — `apply(_:)` accepts one or more `Change` values and
///    commits them atomically to the underlying NSTableView. There is no
///    snapshot diffing: each `Change` describes the structural mutation
///    directly (insert / append / remove / update / replaceAll).
/// 2. **Query** — read-only snapshot accessors (`blockCount`, `blockIds`,
///    `block(at:)`, `block(id:)`).
/// 3. **Events** — extension point. Empty today; add typed callbacks here
///    when a real consumer shows up (visible-range, row-click, etc.).
///
/// The controller is `@MainActor`-isolated. All mutations and table updates
/// run on the main thread, so a background producer must hop to MainActor
/// before calling `apply` (e.g. `await MainActor.run { controller.apply(...) }`).
/// Resize-driven relayout is internal to the coordinator and is also
/// MainActor-serialized, so a live resize and an `apply` from a background
/// task can never observe each other's intermediate state.
@MainActor
@Observable
final class Transcript2Controller {
    /// Atomic, granular mutation. Call `apply` with one or batch many.
    enum Change: Sendable {
        /// Insert `blocks` at `index`. Index is clamped to `[0, blockCount]`.
        case insert(at: Int, _ blocks: [Block])
        /// Append at the end. Equivalent to `.insert(at: blockCount, blocks)`.
        case append([Block])
        /// Remove every block whose id is in `ids`. Unknown ids are ignored.
        case remove(ids: [UUID])
        /// Replace the kind of an existing block, preserving its id. No-op
        /// if the id is unknown.
        case update(id: UUID, kind: Block.Kind)
        /// Escape hatch: replace the entire content. Triggers a single
        /// `reloadData` — no per-row animation, no diff. Use for cold loads
        /// and "I lost track of what changed" recovery paths.
        case replaceAll([Block])
    }

    /// Mirrored from the coordinator after every mutation so SwiftUI can
    /// observe count changes without reaching into AppKit state.
    private(set) var blockCount: Int = 0

    /// Module-internal: handed to `NativeTranscript2View.makeCoordinator`.
    /// Treat as opaque from outside this module.
    let coordinator: Transcript2Coordinator

    init() {
        coordinator = Transcript2Coordinator()
        coordinator.onSnapshotChange = { [weak self] count in
            self?.blockCount = count
        }
    }

    // MARK: - Mutation

    func apply(_ changes: Change...) { coordinator.apply(changes) }
    func apply(_ changes: [Change]) { coordinator.apply(changes) }

    // MARK: - Query

    func block(at index: Int) -> Block? { coordinator.block(at: index) }
    func block(id: UUID) -> Block? { coordinator.block(id: id) }
    var blockIds: [UUID] { coordinator.blockIds }
}
