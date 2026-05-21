import Foundation

/// Decides how much of `Transcript2Coordinator.blocks` AppKit currently
/// sees. Mediates between the data layer (`blocks`, always the full
/// transcript) and the AppKit-visible layer (`numberOfRows` / row
/// indices, which can be smaller during the phased materialize
/// rollout).
///
/// **Why a gate type at all:** PR #179 introduced a single `Bool`
/// (`pendingFirstAppear`) to suppress AppKit visibility during the
/// SwiftUI mount-time placeholder→real frame cascade. The phased
/// materialize optimization adds a third state — a viewport-only
/// intermediate where AppKit sees just the slice that Phase 1
/// installed, until Phase 2's off-main precompute lands the rest. The
/// gate type unifies all three states behind one lookup so every data
/// source method (`numberOfRows`, `block(atRow:)`, `heightOfRow`,
/// `viewFor`) goes through one mapping function — no scattered
/// per-state guards.
///
/// **Three states:**
///
/// - `.full` — steady state. AppKit sees the full `blocks` array.
///   `numberOfRows == blocks.count`; row N maps to `blocks[N]`.
///   This is the default for every coordinator born with an empty
///   transcript or after the phased rollout completes.
///
/// - `.suppressed` — placeholder window. AppKit sees nothing.
///   `numberOfRows == 0`. Entered at `tableView.didSet` when the
///   blocks array is already populated (re-entry / bridge-accumulated
///   state); cleared by the deferred `materializeFirstAppear` one
///   runloop tick after the placeholder→real frame cascade settles.
///
/// - `.visible(Range<Int>)` — phased rollout intermediate. AppKit
///   sees only a contiguous slice of `blocks` (typically the viewport-
///   covering range computed by `Transcript2ViewportSlicer`).
///   `numberOfRows == slice.count`; AppKit's row N maps to
///   `blocks[slice.lowerBound + N]`. The "above" and "below"
///   remainder install asynchronously in Phase 2.
///
/// **Coordinator-side discipline:** while `gate != .full`, the
/// mutation entry points (`apply` / `applyInBackground` / `toggleFold`
/// / `setStatus`) route through their existing "no-AppKit" branches —
/// they mutate the data layer only. AppKit hears about the changes
/// when the rollout's next phase transition (or the post-materialize
/// `reloadData()`) catches them up. This is what made
/// `pendingFirstAppear` safe to entry through; the gate generalizes
/// the same discipline.
enum Transcript2MaterializationGate: Equatable {
    case full
    case suppressed
    case visible(slice: Range<Int>)

    /// Whether the gate is currently `.full`. The mutation entry
    /// points consult this to decide between AppKit and no-AppKit
    /// branches.
    var isFull: Bool {
        if case .full = self { return true }
        return false
    }

    /// Whether the gate is currently `.suppressed`. The deferred
    /// `materializeFirstAppear` arming logic consults this to know
    /// whether it still needs to fire (or whether a sibling path
    /// already moved the gate past suppressed).
    var isSuppressed: Bool {
        if case .suppressed = self { return true }
        return false
    }

    /// Number of rows AppKit sees, given the total `blocks.count`.
    /// Single source of truth for the
    /// `tableView(_:numberOfRowsInSection:)` answer.
    func numberOfRows(blocksCount: Int) -> Int {
        switch self {
        case .full:
            return blocksCount
        case .suppressed:
            return 0
        case .visible(let slice):
            // Defensive clamp: if `blocks` shrank since the slice was
            // computed (a bridge `.remove` raced into the rollout
            // window), report the intersection. The phase-2 hop will
            // run a fresh diff against current blocks and reconcile.
            let upper = min(slice.upperBound, blocksCount)
            let lower = min(slice.lowerBound, upper)
            return upper - lower
        }
    }

    /// Maps an AppKit row index to an index into the coordinator's
    /// `blocks` array. Returns `nil` if the AppKit row falls outside
    /// the gate's visible window — the data source's guards then
    /// return a safe default (height = 1 / nil cell).
    ///
    /// All AppKit-facing reads (`heightOfRow`, `viewFor`, selection
    /// adapter resolution) go through this map so the offset
    /// translation lives in exactly one place.
    func dataIndex(forRow row: Int, blocksCount: Int) -> Int? {
        switch self {
        case .full:
            return (0..<blocksCount).contains(row) ? row : nil
        case .suppressed:
            return nil
        case .visible(let slice):
            let dataIdx = slice.lowerBound + row
            // `row` must be in `0..<slice.count` (AppKit row space);
            // `dataIdx` must be in `0..<blocksCount` (defensive against
            // a `blocks` mutation that shrank below the slice).
            guard row >= 0, row < slice.count else { return nil }
            guard dataIdx >= 0, dataIdx < blocksCount else { return nil }
            return dataIdx
        }
    }
}
