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

    private let documentView: ListDocumentView

    /// Mounted containers by row, current numbering. Containers animating out
    /// after a removal are not here; `MotionAnimator` holds them.
    private var containers: [Int: RowContainerView] = [:]

    /// Containers not in any row, kept for the next row that arrives.
    private var spare: [RowContainerView] = []

    init(documentView: ListDocumentView) {
        self.documentView = documentView
    }

    /// The rows with a container that is not animating out, in the current
    /// numbering.
    var mountedRows: IndexSet {
        IndexSet(containers.keys)
    }

    /// Renumbers every container through a batch. Removed rows' containers
    /// become −1 and are returned keyed by their old row, which is how the
    /// plan's `.removed` motions name them, for `MotionAnimator` to retire
    /// (M10).
    func apply(_ map: RowIndexMap) -> [Int: RowContainerView] {
        var renumbered: [Int: RowContainerView] = [:]
        var removed: [Int: RowContainerView] = [:]
        for (row, container) in containers {
            if let now = map.newIndex(forOld: row) {
                container.row = now
                renumbered[now] = container
            } else {
                container.row = -1
                removed[row] = container
            }
        }
        containers = renumbered
        return removed
    }

    /// P1: mounts exactly `rows` plus `keeping`, at G1's frames for `width`.
    /// Rows that are new are asked for views. Rows that leave are unmounted
    /// unless `keeping` holds them, which is what `MotionAnimator` uses for rows
    /// still in flight.
    ///
    /// A container that leaves is handed straight to a row that arrives in the
    /// same call, still in the document and usually still holding the view
    /// the pool gives back, so a scroll step moves no view in or out of the
    /// hierarchy; that is how `NSTableView` recycles its row views (measured:
    /// it keeps only the rows it shows). The host still hears `didRemove`
    /// before `viewForRow` (P2, P3). Containers left over leave the document.
    func place(rows: IndexSet, keeping: IndexSet, heights: RowHeights, width: CGFloat) {
        let wanted = rows.union(keeping).filteredIndexSet { $0 < heights.count }
        var departed: [RowContainerView] = []
        for (row, container) in containers where !wanted.contains(row) {
            depart(container, reporting: row)
            containers[row] = nil
            departed.append(container)
        }
        for row in wanted {
            let frame = NSRect(x: 0, y: heights.top(ofRow: row), width: width, height: heights[row])
            if let container = containers[row] {
                container.frame = frame
                if let view = container.hostedView { _ = container.host(view, height: frame.height) }
                continue
            }
            let view = owner?.placement(self, viewForRow: row)
            let container: RowContainerView
            if let holder = view?.superview as? RowContainerView,
                let index = departed.firstIndex(where: { $0 === holder })
            {
                container = departed.remove(at: index)
            } else if let recycled = departed.popLast() {
                container = recycled
            } else {
                container = spare.popLast() ?? RowContainerView(row: row)
                documentView.addSubview(container)
            }
            container.row = row
            container.frame = frame
            if let view { _ = container.host(view, height: frame.height) }
            containers[row] = container
        }
        for container in departed {
            container.removeFromSuperview()
            _ = container.unhost()
            spare.append(container)
        }
    }

    /// U6: asks these mounted rows for their views again.
    func reload(rows: IndexSet) {
        guard let owner else { return }
        for row in rows {
            guard let container = containers[row] else { continue }
            let view = owner.placement(self, viewForRow: row)
            if let replaced = container.host(view, height: container.frame.height) {
                owner.placement(self, didRemove: replaced, forRow: row)
            }
        }
    }

    /// The container for a mounted row, if there is one.
    func container(forRow row: Int) -> RowContainerView? {
        containers[row]
    }

    /// P6: the row of `view` or of the container it is inside, else −1.
    func row(for view: NSView) -> Int {
        var candidate: NSView? = view
        while let current = candidate, current !== documentView {
            if let container = current as? RowContainerView {
                return containers[container.row] === container ? container.row : -1
            }
            candidate = current.superview
        }
        return -1
    }

    /// Unmounts a container whose animation has ended, reporting `didRemove`
    /// (P3).
    func retire(_ container: RowContainerView) {
        unmount(container, reporting: -1)
    }

    /// U7: unmounts everything, reporting `didRemove` for each.
    func removeAll() {
        for (row, container) in containers {
            unmount(container, reporting: row)
        }
        containers.removeAll()
    }

    private func unmount(_ container: RowContainerView, reporting row: Int) {
        depart(container, reporting: row)
        container.removeFromSuperview()
        _ = container.unhost()
        spare.append(container)
    }

    /// Takes a container out of its row: its motion ends, and the host hears
    /// `didRemove` for its view, which goes back to the pool (P3). The view
    /// stays in the container until another row takes one or the other.
    private func depart(_ container: RowContainerView, reporting row: Int) {
        container.layer?.removeAllAnimations()
        container.layer?.opacity = 1
        container.layer?.sublayerTransform = CATransform3DIdentity
        if let view = container.hostedView {
            owner?.placement(self, didRemove: view, forRow: row)
        }
    }
}
