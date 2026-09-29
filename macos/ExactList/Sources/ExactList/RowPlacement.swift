import AppKit
import ExactListCore

/// The mounted set: which rows have containers, and where the containers are
/// (SPEC P1–P3, P6).
///
/// It places at model frames. `MotionAnimator` adds the motion on top, and
/// hands back the containers whose animations have ended.
@MainActor
final class RowPlacement {

    /// Weak: the list owns this.
    weak var owner: RowPlacementOwner?

    init(documentView: ListDocumentView) {
        fatalError("unimplemented: SPEC P1")
    }

    /// The rows with a container that is not animating out, in the current
    /// numbering.
    var mountedRows: IndexSet {
        fatalError("unimplemented: SPEC P1")
    }

    /// Renumbers every container through a batch. Removed rows' containers
    /// become −1 and are returned keyed by their old row, which is how the
    /// plan's `.removed` motions name them, for `MotionAnimator` to retire
    /// (M10).
    func apply(_ map: RowIndexMap) -> [Int: RowContainerView] {
        fatalError("unimplemented: SPEC A4, M10")
    }

    /// P1: mounts exactly `rows` plus `keeping`, at G1's frames for `width`.
    /// Rows that are new are asked for views. Rows that leave are unmounted
    /// unless `keeping` holds them, which is what `MotionAnimator` uses for rows
    /// still in flight.
    func place(rows: IndexSet, keeping: IndexSet, heights: RowHeights, width: CGFloat) {
        fatalError("unimplemented: SPEC P1, P2, P3")
    }

    /// U6: asks these mounted rows for their views again.
    func reload(rows: IndexSet) {
        fatalError("unimplemented: SPEC U6")
    }

    /// The container for a mounted row, if there is one.
    func container(forRow row: Int) -> RowContainerView? {
        fatalError("unimplemented: SPEC P7")
    }

    /// P6: the row of `view` or of the container it is inside, else −1.
    func row(for view: NSView) -> Int {
        fatalError("unimplemented: SPEC P6")
    }

    /// Unmounts a container whose animation has ended, reporting `didRemove`
    /// (P3).
    func retire(_ container: RowContainerView) {
        fatalError("unimplemented: SPEC P3")
    }

    /// U7: unmounts everything, reporting `didRemove` for each.
    func removeAll() {
        fatalError("unimplemented: SPEC U7")
    }
}
