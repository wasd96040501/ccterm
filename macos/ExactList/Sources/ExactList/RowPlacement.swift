import AppKit
import ExactListCore

/// The mounted set: which rows have containers, and where the containers are
/// (SPEC P1–P3, P6).
///
/// It places rows at G1's frames, except rows in flight: their frames belong
/// to `MotionAnimator` until their motion ends, and it hands back the
/// containers whose motion has ended.
@MainActor
final class RowPlacement {

    /// Weak: the list owns this.
    weak var delegate: RowPlacementDelegate?

    private let documentView: ListDocumentView

    /// Mounted containers by row, current numbering. Containers animating out
    /// after a removal are not here; `MotionAnimator` holds them.
    private var containers: [Int: ListRowView] = [:]

    /// Containers in no row, hidden in the document with the view they last
    /// held (P3), for the next rows that arrive.
    private var spare: [ListRowView] = []

    /// Containers retired since the last `place`: out of their rows but still
    /// in the document, for the rows that arrive next to take first.
    private var retired: [ListRowView] = []

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
    /// plan's `.removed` motions name them, to be retired now or once they
    /// have moved out (M10).
    func apply(_ map: RowIndexMap) -> [Int: ListRowView] {
        var renumbered: [Int: ListRowView] = [:]
        var removed: [Int: ListRowView] = [:]
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
    /// unless `keeping` holds them: the rows still in flight, whose frames
    /// `MotionAnimator` sets, so they are not touched here.
    ///
    /// No container or view leaves the document here: a view going out of the
    /// window and back makes AppKit rebuild the window's layer tree (P3). An
    /// arriving row takes the container that holds the view the pool gives
    /// back, else one that left in this call, else a hidden spare, as
    /// `NSTableView` hands a leaving row view to an arriving row. The host
    /// still hears `didRemove` before `viewForRow` (P2, P3). Containers left
    /// over are hidden.
    func place(rows: IndexSet, keeping: IndexSet, heights: RowHeights, width: CGFloat) {
        let wanted = rows.union(keeping).filteredIndexSet { $0 < heights.count }
        var departed = retired
        retired.removeAll()
        for (row, container) in containers where !wanted.contains(row) {
            depart(container, reporting: row)
            containers[row] = nil
            departed.append(container)
        }
        for row in wanted {
            let frame = NSRect(x: 0, y: heights.top(ofRow: row), width: width, height: heights[row])
            if let container = containers[row] {
                // Most rows stay where they were; AppKit's frame setters do
                // work even for the frame a view already has.
                if !keeping.contains(row), container.frame != frame { container.frame = frame }
                continue
            }
            let view = delegate?.placement(self, viewForRow: row)
            let container = take(holding: view, from: &departed)
            container.row = row
            container.frame = frame
            if let view { _ = container.host(view) }
            containers[row] = container
        }
        for container in departed { stow(container) }
    }

    /// U6: asks these mounted rows for their views again.
    func reload(rows: IndexSet) {
        guard let delegate else { return }
        for row in rows {
            guard let container = containers[row], let current = container.hostedView else { continue }
            _ = container.host(delegate.placement(self, reloadingRow: row, showing: current))
        }
    }

    /// The container for a mounted row, if there is one.
    func container(forRow row: Int) -> ListRowView? {
        containers[row]
    }

    /// P6: the row of `view` or of the container it is inside, else −1.
    func row(for view: NSView) -> Int {
        var candidate: NSView? = view
        while let current = candidate, current !== documentView {
            if let container = current as? ListRowView {
                return containers[container.row] === container ? container.row : -1
            }
            candidate = current.superview
        }
        return -1
    }

    /// Takes back a container whose animation has ended, reporting
    /// `didRemove` (P3). The next `place` gives it to an arriving row or
    /// hides it among the spares.
    func retire(_ container: ListRowView) {
        depart(container, reporting: -1)
        retired.append(container)
    }

    /// U7: unmounts everything, reporting `didRemove` for each.
    func removeAll() {
        for (row, container) in containers {
            depart(container, reporting: row)
            stow(container)
        }
        containers.removeAll()
        for container in retired { stow(container) }
        retired.removeAll()
    }

    /// A container for an arriving row: the one holding `view`, which then
    /// moves nothing; else any that left in this call; else a spare; else a
    /// new one.
    private func take(holding view: NSView?, from departed: inout [ListRowView]) -> ListRowView {
        if let holder = view?.superview as? ListRowView {
            if let index = departed.firstIndex(where: { $0 === holder }) {
                return departed.remove(at: index)
            }
            if let index = spare.firstIndex(where: { $0 === holder }) {
                spare[index].isHidden = false
                return spare.remove(at: index)
            }
        }
        if let recycled = departed.popLast() { return recycled }
        if let hidden = spare.popLast() {
            hidden.isHidden = false
            return hidden
        }
        let container = ListRowView(row: -1)
        documentView.addSubview(container)
        return container
    }

    /// Puts a departed container among the spares: hidden, in no row, still
    /// holding its view (P3).
    private func stow(_ container: ListRowView) {
        container.row = -1
        container.isHidden = true
        spare.append(container)
    }

    /// Takes a container out of its row: its opacity and content offset go
    /// back to rest, and the host hears `didRemove` for its view, which goes
    /// back to the pool (P3). The view stays in the container until another
    /// row takes one or the other.
    private func depart(_ container: ListRowView, reporting row: Int) {
        container.alphaValue = 1
        container.contentOffset = .zero
        if let view = container.hostedView {
            delegate?.placement(self, didRemove: view, forRow: row)
        }
    }
}
