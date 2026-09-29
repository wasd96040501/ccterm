import AppKit
import ExactListCore

/// Turns a `CommitPlan` into CoreAnimation, and nothing else (SPEC §8).
///
/// For each motion that isn't still, it adds additive `position.y` and
/// `bounds.size.height` animations from `start − end` to 0 on the row's
/// container, plus the transition's opacity or content offset (M9). All of
/// them share one duration and one timing function. It never removes an
/// animation it didn't finish: a later commit adds on top (M8). It never reads
/// a presentation layer.
///
/// Every animation goes on the container's layer, never on the host view's
/// (P5). A slide (M9) offsets the content with an additive animation of the
/// container layer's `sublayerTransform.translation.y` (or `.x`), not by
/// moving the hosted view.
@MainActor
final class MotionAnimator {

    /// Weak: the list owns this.
    weak var owner: MotionAnimatorOwner?

    init() {
        fatalError("unimplemented: SPEC M3")
    }

    /// Adds the plan's animations to `containers`, keyed by new row, and to
    /// `retiring`, keyed by old row: the removed rows' containers, which the
    /// plan's `.removed` motions name by their old index. Nothing animates when
    /// `duration` is 0; the completion still runs on a later turn (U8). The
    /// retiring containers are handed back once this commit's animations end.
    func animate(
        _ plan: CommitPlan, containers: [Int: RowContainerView], retiring: [Int: RowContainerView],
        duration: TimeInterval, timing: CAMediaTimingFunction, completion: @escaping (Bool) -> Void
    ) {
        fatalError("unimplemented: SPEC M2, M3, M9, U8")
    }

    /// The rows whose containers are still in flight, in the current numbering:
    /// what `RowPlacement.place(rows:keeping:…)` keeps mounted (P1).
    var rowsInFlight: IndexSet {
        fatalError("unimplemented: SPEC P1")
    }

    /// Renumbers the rows in flight through a batch.
    func apply(_ map: RowIndexMap) {
        fatalError("unimplemented: SPEC M8")
    }

    /// U7: removes every animation. Outstanding completions get `false`.
    func cancelAll() {
        fatalError("unimplemented: SPEC U7")
    }
}
