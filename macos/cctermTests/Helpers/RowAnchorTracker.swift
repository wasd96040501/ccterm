import AppKit
import XCTest

@testable import ccterm

/// Per-tick row-geometry probe for the transcript table. Used by the
/// flicker-investigation tests to replace eyeballed PNGs with numeric
/// drift readings: how far did the user's perceived anchor block shift
/// between consecutive ticks, and did Phase A's content actually cover
/// the viewport before `markAnchorSettled()` flipped the gate.
///
/// Reads the live `NSTableView` through the controller's coordinator —
/// no test-only seams in production code. `snapshot()` must run on the
/// main actor because every getter it touches (`visibleRect`,
/// `rect(ofRow:)`, `enclosingScrollView.contentView.bounds.origin`)
/// is `@MainActor`-isolated through AppKit.
@MainActor
struct RowAnchorTracker {

    /// One frame's view onto the table. All `CGFloat` fields live in
    /// `NSTableView` document coordinates (flipped: y=0 at top); pair
    /// them with `scrollY` to translate into clip-view (viewport) space.
    /// `firstVisible*` / `lastVisible*` are nil when no rows are
    /// currently visible (e.g. table not yet tiled).
    struct Snapshot: Equatable {
        let tick: Int
        let viewportHeight: CGFloat
        let contentHeight: CGFloat
        let scrollY: CGFloat
        let firstVisibleBlockId: UUID?
        /// Document-space minY of the topmost visible row.
        let firstVisibleMinY: CGFloat?
        let lastVisibleBlockId: UUID?
        /// Document-space maxY of the bottommost visible row.
        let lastVisibleMaxY: CGFloat?
        /// Total document-space height covered by all currently-visible
        /// rows. When equal to `viewportHeight` the viewport is fully
        /// covered; smaller means rows fall short of the viewport edge.
        let visibleRowsExtent: CGFloat
        /// Number of rows currently in `tableView.visibleRect`.
        let visibleRowCount: Int

        /// Viewport-space (clip-view-relative) y position of the
        /// topmost / bottommost visible row's leading / trailing edge.
        /// Use these for "did the row visually move between two
        /// frames?" — document-space y won't, because Phase B's
        /// prepend grows the document.
        var firstVisibleViewportMinY: CGFloat? {
            firstVisibleMinY.map { $0 - scrollY }
        }
        var lastVisibleViewportMaxY: CGFloat? {
            lastVisibleMaxY.map { $0 - scrollY }
        }

        /// `contentHeight / viewportHeight` — > 1 means content
        /// overflows (chat scrollable), ≤ 1 means content is short
        /// of the viewport so Phase A leaves an empty band.
        var fillRatio: CGFloat {
            guard viewportHeight > 0 else { return 0 }
            return contentHeight / viewportHeight
        }
    }

    /// Empty when the table is unmounted or not yet tiled. Use a
    /// fresh tracker per test; snapshots accumulate.
    private(set) var snapshots: [Snapshot] = []

    mutating func record(
        from controller: Transcript2Controller, tick: Int
    ) {
        guard let table = controller.coordinator.tableView,
            let scrollView = table.enclosingScrollView
        else { return }
        let viewportHeight = scrollView.contentView.bounds.height
        let scrollY = scrollView.contentView.bounds.origin.y
        let contentHeight = table.frame.height
        let visible = table.rows(in: table.visibleRect)

        let firstBlockId: UUID?
        let firstMinY: CGFloat?
        let lastBlockId: UUID?
        let lastMaxY: CGFloat?
        let extent: CGFloat
        let blockIds = controller.coordinator.blockIds

        if visible.location != NSNotFound, visible.length > 0,
            blockIds.indices.contains(visible.location),
            blockIds.indices.contains(visible.location + visible.length - 1)
        {
            let firstRow = visible.location
            let lastRow = visible.location + visible.length - 1
            let firstRect = table.rect(ofRow: firstRow)
            let lastRect = table.rect(ofRow: lastRow)
            firstBlockId = blockIds[firstRow]
            firstMinY = firstRect.origin.y
            lastBlockId = blockIds[lastRow]
            lastMaxY = lastRect.maxY
            extent = lastRect.maxY - firstRect.origin.y
        } else {
            firstBlockId = nil
            firstMinY = nil
            lastBlockId = nil
            lastMaxY = nil
            extent = 0
        }

        snapshots.append(
            Snapshot(
                tick: tick,
                viewportHeight: viewportHeight,
                contentHeight: contentHeight,
                scrollY: scrollY,
                firstVisibleBlockId: firstBlockId,
                firstVisibleMinY: firstMinY,
                lastVisibleBlockId: lastBlockId,
                lastVisibleMaxY: lastMaxY,
                visibleRowsExtent: extent,
                visibleRowCount: (visible.location != NSNotFound) ? visible.length : 0))
    }

    // MARK: - Drift queries

    /// Pairwise drift report for one block id between any two recorded
    /// snapshots. `nil` when the id wasn't in `lastVisible*` on either
    /// side (the row was off-screen for that tick).
    struct LastVisibleDrift {
        let from: Snapshot
        let to: Snapshot
        let blockId: UUID
        /// `to.lastVisibleViewportMaxY - from.lastVisibleViewportMaxY`.
        /// Positive = row moved DOWN in the viewport. Anchor stability
        /// claim "this row stays at the same visual y" implies this is
        /// ~0 across the change of interest.
        let viewportShift: CGFloat
    }

    /// Same blockId tracked across two snapshots in the
    /// `lastVisibleBlockId` slot. Returns nil if either snapshot
    /// doesn't carry the id there.
    func lastVisibleDrift(
        of blockId: UUID, from a: Snapshot, to b: Snapshot
    ) -> LastVisibleDrift? {
        guard a.lastVisibleBlockId == blockId,
            b.lastVisibleBlockId == blockId,
            let aY = a.lastVisibleViewportMaxY,
            let bY = b.lastVisibleViewportMaxY
        else { return nil }
        return LastVisibleDrift(
            from: a, to: b, blockId: blockId, viewportShift: bY - aY)
    }

    /// Snapshot at the first tick where `predicate(snapshot)` returns
    /// true. Convenience for "the tick Phase A settled" or "the tick
    /// Phase B's blockCount jumped past N".
    func firstSnapshot(
        where predicate: (Snapshot) -> Bool
    ) -> Snapshot? {
        snapshots.first(where: predicate)
    }

    func lastSnapshot() -> Snapshot? { snapshots.last }

    // MARK: - Human-readable trace

    /// Formats a one-line digest per snapshot for printing in test logs
    /// (so investigations don't have to round-trip through PNGs to read
    /// quantitative state). Each line:
    ///
    ///   tick=001 vp=600.0 doc=330.0 scroll=0.0 rows=11 (extent=330.0)
    ///   top=<id>@docY=0.0 vpY=0.0  bot=<id>@docY=330.0 vpY=330.0  fill=0.55
    func trace() -> String {
        snapshots.map { s -> String in
            let topPart: String
            if let id = s.firstVisibleBlockId, let y = s.firstVisibleMinY {
                topPart = String(
                    format: "top=%@@docY=%.1f vpY=%.1f",
                    String(id.uuidString.prefix(8)), y, y - s.scrollY)
            } else {
                topPart = "top=nil"
            }
            let botPart: String
            if let id = s.lastVisibleBlockId, let y = s.lastVisibleMaxY {
                botPart = String(
                    format: "bot=%@@docY=%.1f vpY=%.1f",
                    String(id.uuidString.prefix(8)), y, y - s.scrollY)
            } else {
                botPart = "bot=nil"
            }
            return String(
                format:
                    "tick=%03d vp=%.1f doc=%.1f scroll=%.1f rows=%d (extent=%.1f)  %@  %@  fill=%.2f",
                s.tick, s.viewportHeight, s.contentHeight, s.scrollY,
                s.visibleRowCount, s.visibleRowsExtent, topPart, botPart,
                s.fillRatio)
        }.joined(separator: "\n")
    }
}
